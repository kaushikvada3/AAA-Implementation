/**
 * engine.js — AAA Secret-Key Generation Engine (JavaScript port)
 * Direct port of aaa_key_engine.c — same Xorshift32 PRNG, same XOR accumulation.
 */

class AAAEngine {
  constructor(keyBytes = 16) {
    this.KEY_BYTES = keyBytes;
    this.key = new Uint8Array(keyBytes);
    this.prngState = 0;
    this.packetsTotal = 0;
    this.packetsMissedByEve = 0;
    this.perfectSecrecyAchieved = false;
    this._selected = new Uint8Array(keyBytes);
  }

  /** Xorshift32 PRNG — identical to C implementation */
  _xorshift32() {
    let x = this.prngState >>> 0;
    x ^= (x << 13) >>> 0;
    x ^= (x >>> 17);
    x ^= (x << 5) >>> 0;
    this.prngState = x >>> 0;
    return x >>> 0;
  }

  /** Initialize engine with public seed (both sides use the same seed) */
  init(publicSeed) {
    this.key.fill(0);
    this.prngState = (publicSeed !== 0) ? (publicSeed >>> 0) : 0xDEADBEEF;
    this.packetsTotal = 0;
    this.packetsMissedByEve = 0;
    this.perfectSecrecyAchieved = false;
    this._selected.fill(0);
  }

  /** Select KEY_BYTES from payload using PRNG — mirrors select_bits_from_payload() */
  _selectBits(payload) {
    this._selected.fill(0);
    for (let l = 0; l < this.KEY_BYTES; l++) {
      const rnd1 = this._xorshift32();
      const idx1 = rnd1 % payload.length;
      this._selected[l] = payload[idx1];
      const rnd2 = this._xorshift32();
      const idx2 = rnd2 % payload.length;
      this._selected[l] ^= payload[idx2];
    }
  }

  /** Process a packet — the core AAA XOR accumulation */
  processPacket(payload, eveMissedThis) {
    if (payload.length < this.KEY_BYTES) return -2;
    const prevKey = new Uint8Array(this.key);
    this._selectBits(payload);
    const selectedCopy = new Uint8Array(this._selected);
    for (let l = 0; l < this.KEY_BYTES; l++) {
      this.key[l] ^= this._selected[l];
    }
    this.packetsTotal++;
    if (eveMissedThis) {
      this.packetsMissedByEve++;
      this.perfectSecrecyAchieved = true;
    }
    this._selected.fill(0);
    return { prevKey, selected: selectedCopy, newKey: new Uint8Array(this.key) };
  }

  getKey() { return new Uint8Array(this.key); }

  isSecure() { return this.perfectSecrecyAchieved; }

  getStats() {
    let equivocation = 0;
    if (this.packetsTotal > 0) {
      const muAvg = this.packetsMissedByEve / this.packetsTotal;
      let product = 1.0;
      for (let i = 0; i < this.packetsTotal && i < 500; i++) {
        product *= (1.0 - muAvg);
        if (product < 1e-15) { product = 0; break; }
      }
      equivocation = 1.0 - product;
      if (equivocation > 1.0) equivocation = 1.0;
    }
    return {
      packetsProcessed: this.packetsTotal,
      packetsMissedEve: this.packetsMissedByEve,
      equivocation
    };
  }

  /** Clone PRNG state — for forking Eve's engine */
  cloneState() {
    const c = new AAAEngine(this.KEY_BYTES);
    c.key = new Uint8Array(this.key);
    c.prngState = this.prngState;
    c.packetsTotal = this.packetsTotal;
    c.packetsMissedByEve = this.packetsMissedByEve;
    c.perfectSecrecyAchieved = this.perfectSecrecyAchieved;
    return c;
  }
}

/**
 * Simulation — manages Alice, Bob, and Eve contexts
 */
class AAASimulation {
  constructor() {
    this.keyBytes = 16;
    this.aliceEngine = new AAAEngine(this.keyBytes);
    this.bobEngine = new AAAEngine(this.keyBytes);
    this.eveEngine = new AAAEngine(this.keyBytes);
    this.packetCount = 0;
    this.mu = 0.30;      // Eve miss probability
    this.alpha = 0.30;   // Correlation factor
    this.payloadSize = 256;
    this.prevPayload = null;
    this.equivocationHistory = [];
    this._simRng = 42;
  }

  /** Simple seeded RNG for deterministic packet generation */
  _simRand() {
    this._simRng = ((this._simRng * 1103515245 + 12345) & 0x7fffffff) >>> 0;
    return this._simRng;
  }

  init(seed, keyBytes, mu, alpha, payloadSize) {
    this.keyBytes = keyBytes;
    this.mu = mu;
    this.alpha = alpha;
    this.payloadSize = payloadSize;
    this.packetCount = 0;
    this.prevPayload = null;
    this.equivocationHistory = [];
    this._simRng = 42;

    this.aliceEngine = new AAAEngine(keyBytes);
    this.bobEngine = new AAAEngine(keyBytes);
    this.eveEngine = new AAAEngine(keyBytes);

    this.aliceEngine.init(seed);
    this.bobEngine.init(seed);
    this.eveEngine.init(seed);
  }

  /** Generate a single payload with optional Markov correlation */
  _generatePayload() {
    const payload = new Uint8Array(this.payloadSize);
    for (let i = 0; i < this.payloadSize; i++) {
      payload[i] = this._simRand() & 0xFF;
    }
    // Apply Markov correlation with previous payload
    if (this.prevPayload && this.alpha > 0) {
      for (let i = 0; i < this.payloadSize; i++) {
        if (Math.random() < this.alpha) {
          payload[i] = this.prevPayload[i];
        }
      }
    }
    this.prevPayload = new Uint8Array(payload);
    return payload;
  }

  /** Step one packet. Returns info object for the UI. */
  step() {
    this.packetCount++;
    const payload = this._generatePayload();
    const eveMissed = Math.random() < this.mu;

    const aliceResult = this.aliceEngine.processPacket(payload, eveMissed);
    this.bobEngine.processPacket(payload, eveMissed);

    // Eve only processes if she didn't miss
    let eveResult = null;
    if (!eveMissed) {
      eveResult = this.eveEngine.processPacket(payload, false);
    }

    const stats = this.aliceEngine.getStats();
    this.equivocationHistory.push(stats.equivocation);

    return {
      packetNum: this.packetCount,
      eveMissed,
      aliceKey: this.aliceEngine.getKey(),
      bobKey: this.bobEngine.getKey(),
      eveKey: this.eveEngine.getKey(),
      prevKey: aliceResult.prevKey,
      selected: aliceResult.selected,
      newKey: aliceResult.newKey,
      stats,
      isSecure: this.aliceEngine.isSecure(),
      keysMatch: arraysEqual(this.aliceEngine.getKey(), this.bobEngine.getKey()),
      equivocationHistory: this.equivocationHistory,
    };
  }
}

function arraysEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) { if (a[i] !== b[i]) return false; }
  return true;
}

function hexStr(arr) {
  return Array.from(arr).map(b => b.toString(16).toUpperCase().padStart(2, '0')).join(' ');
}

function hexStrCompact(arr) {
  let s = '';
  for (let i = 0; i < arr.length; i++) {
    s += arr[i].toString(16).toUpperCase().padStart(2, '0');
    if ((i + 1) % 4 === 0 && i + 1 < arr.length) s += ' ';
  }
  return s;
}
