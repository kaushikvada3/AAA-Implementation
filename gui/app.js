/**
 * app.js — AAA Key Engine GUI (Professional Dashboard)
 */
(function () {
  'use strict';

  const sim = new AAASimulation();
  let autoInterval = null;
  let speed = 200;
  let keyBytes = 16;

  const $ = id => document.getElementById(id);

  /* ── Helpers ───────────────────────────────────────────────────────── */
  function hexBlock(arr) {
    let parts = [];
    for (let i = 0; i < arr.length; i += 4) {
      let s = '';
      for (let j = i; j < i + 4 && j < arr.length; j++)
        s += arr[j].toString(16).toUpperCase().padStart(2, '0');
      parts.push(s);
    }
    return parts;
  }

  /* SVG icon paths */
  const SVG_CHECK = '<svg class="w-4 h-4 text-green-500 mt-0.5 shrink-0" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/></svg>';
  const SVG_X = '<svg class="w-4 h-4 text-red-500 mt-0.5 shrink-0" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/></svg>';
  const SVG_CHECK_SM = '<svg class="w-3 h-3" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/></svg>';

  /* ── Init / Reset ──────────────────────────────────────────────────── */
  function resetSim() {
    stopAuto();
    const seedStr = $('input-seed').value.replace(/[^0-9A-Fa-f]/g, '') || 'ABCD1234';
    $('input-seed').value = seedStr.toUpperCase();
    const seed = parseInt(seedStr, 16) >>> 0;
    const mu = parseInt($('slider-mu').value) / 100;
    const alpha = parseInt($('slider-alpha').value) / 100;
    const payloadSize = parseInt($('slider-payload').value);
    sim.init(seed, keyBytes, mu, alpha, payloadSize);
    clearUI();
  }

  function clearUI() {
    $('key-alice').textContent = '—';
    $('key-bob').textContent = '—';
    $('key-eve').textContent = '—';
    $('match-indicator').innerHTML = '—';
    $('match-indicator').className = 'flex justify-center items-center gap-2 text-sm font-medium text-gray-500';
    for (let i = 0; i < 4; i++) {
      $('xor-s' + i).textContent = '—';
      $('xor-p' + i).textContent = '—';
      $('xor-n' + i).textContent = '—';
    }
    $('packet-num-text').textContent = 'Waiting…';
    $('eve-status-text').textContent = 'Listening…';
    $('eve-status-dot').setAttribute('fill', '#6b7280');
    $('eve-status-icon').setAttribute('d', '');
    $('flow-progress').setAttribute('x2', '180');
    $('stat-packets').textContent = '0';
    $('stat-missed').textContent = '0';
    $('stat-missrate').textContent = '0.0%';
    $('stat-equiv').textContent = '0.0000';
    $('stat-secrecy').textContent = 'Not Yet';
    $('stat-secrecy').className = 'text-gray-500 text-xs font-medium';
    $('stat-match').textContent = '—';
    $('stat-match').className = 'text-gray-500 text-xs font-medium';
    $('packet-log').innerHTML = '';
    $('key-panel').classList.remove('glow-box-green');
    drawChart([]);
  }

  /* ── Step ───────────────────────────────────────────────────────────── */
  function stepPacket() {
    sim.mu = parseInt($('slider-mu').value) / 100;
    sim.alpha = parseInt($('slider-alpha').value) / 100;
    const r = sim.step();
    updateUI(r);
    animateFlow(r.eveMissed);
  }

  function updateUI(r) {
    const ab = hexBlock(r.aliceKey);
    const bb = hexBlock(r.bobKey);
    const eb = hexBlock(r.eveKey);
    $('key-alice').textContent = ab.join(' ');
    $('key-bob').textContent = bb.join(' ');
    $('key-eve').textContent = eb.join(' ');

    // Match indicator
    if (r.keysMatch) {
      $('match-indicator').innerHTML = SVG_CHECK_SM + ' Alice &amp; Bob keys match';
      $('match-indicator').className = 'flex justify-center items-center gap-2 text-sm glow-text-green font-medium';
      $('key-panel').classList.add('glow-box-green');
    } else {
      $('match-indicator').innerHTML = '✗ Keys MISMATCH';
      $('match-indicator').className = 'flex justify-center items-center gap-2 text-sm font-medium text-red-400';
    }

    // XOR table
    const sb = hexBlock(r.selected);
    const pb = hexBlock(r.prevKey);
    const nb = hexBlock(r.newKey);
    for (let i = 0; i < 4; i++) {
      $('xor-s' + i).textContent = sb[i] || '';
      $('xor-p' + i).textContent = pb[i] || '';
      $('xor-n' + i).textContent = nb[i] || '';
    }

    // Packet flow
    $('packet-num-text').textContent = 'Packet #' + r.packetNum;
    if (r.eveMissed) {
      $('eve-status-text').textContent = 'Missed packet';
      $('eve-status-dot').setAttribute('fill', '#ef4444');
      $('eve-status-icon').setAttribute('d', 'M112 9 L118 15 M118 9 L112 15');
    } else {
      $('eve-status-text').textContent = 'Captured packet';
      $('eve-status-dot').setAttribute('fill', '#10b981');
      $('eve-status-icon').setAttribute('d', 'M112 12 L114 14 L118 10');
    }

    // Stats
    $('stat-packets').textContent = r.stats.packetsProcessed;
    $('stat-missed').textContent = r.stats.packetsMissedEve;
    const mr = r.stats.packetsProcessed > 0
      ? ((r.stats.packetsMissedEve / r.stats.packetsProcessed) * 100).toFixed(1) : '0.0';
    $('stat-missrate').textContent = mr + '%';
    $('stat-equiv').textContent = r.stats.equivocation.toFixed(4);

    if (r.isSecure) {
      $('stat-secrecy').innerHTML = SVG_CHECK_SM + ' Achieved';
      $('stat-secrecy').className = 'text-green-400 flex items-center gap-1 text-xs font-medium bg-green-900/20 px-2 py-0.5 rounded';
    }
    $('stat-match').innerHTML = r.keysMatch
      ? SVG_CHECK_SM + ' Match'
      : '✗ Mismatch';
    $('stat-match').className = r.keysMatch
      ? 'text-green-400 flex items-center gap-1 text-xs font-medium'
      : 'text-red-400 text-xs font-medium';

    addLogEntry(r);
    drawChart(r.equivocationHistory);
  }

  /* ── Flow animation ────────────────────────────────────────────────── */
  function animateFlow(eveMissed) {
    const line = $('flow-progress');
    const pktGroup = $('packet-group');
    let progress = 0;
    const startX = 180, endX = 620;
    const dur = 300;
    const start = performance.now();
    line.setAttribute('stroke', eveMissed ? '#f87171' : '#60a5fa');

    function tick(now) {
      progress = Math.min((now - start) / dur, 1);
      const ease = 1 - Math.pow(1 - progress, 3);
      const x = startX + (endX - startX) * ease;
      line.setAttribute('x2', x.toString());
      pktGroup.setAttribute('transform', `translate(${x}, 70)`);
      if (progress < 1) requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }

  /* ── Log entry ─────────────────────────────────────────────────────── */
  function addLogEntry(r) {
    const shortKey = hexBlock(r.newKey)[0] || '';
    const div = document.createElement('div');
    div.className = 'flex items-start gap-2 log-animate' + (r.packetNum > 1 ? '' : '');
    div.innerHTML = (r.eveMissed ? SVG_X : SVG_CHECK)
      + `<span class="break-all">Packet #${r.packetNum}: ${shortKey}…</span>`;
    const log = $('packet-log');
    log.prepend(div);
    // Fade older entries
    Array.from(log.children).forEach((el, i) => {
      if (i > 0) el.classList.add('opacity-60');
    });
    while (log.children.length > 200) log.removeChild(log.lastChild);
  }

  /* ── Chart ──────────────────────────────────────────────────────────── */
  function drawChart(history) {
    const canvas = $('chart-canvas');
    const rect = canvas.parentElement.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    const ctx = canvas.getContext('2d');
    ctx.scale(dpr, dpr);
    const W = rect.width, H = rect.height;
    const pad = { top: 15, right: 15, bottom: 25, left: 35 };
    const pW = W - pad.left - pad.right;
    const pH = H - pad.top - pad.bottom;

    ctx.clearRect(0, 0, W, H);

    // Grid
    ctx.strokeStyle = '#373a40';
    ctx.lineWidth = 1;
    for (let i = 0; i <= 2; i++) {
      const y = pad.top + (pH / 2) * i;
      ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(pad.left + pW, y); ctx.stroke();
    }
    // Y labels
    ctx.fillStyle = '#6b7280';
    ctx.font = '10px JetBrains Mono, monospace';
    ctx.textAlign = 'right';
    ['1.00', '0.50', '0.00'].forEach((v, i) => {
      ctx.fillText(v, pad.left - 6, pad.top + (pH / 2) * i + 4);
    });

    if (!history || history.length < 2) return;

    const maxN = history.length;
    // X labels
    ctx.textAlign = 'center';
    const tickStep = Math.max(1, Math.ceil(maxN / 6));
    for (let i = 0; i <= maxN; i += tickStep) {
      const x = pad.left + (i / maxN) * pW;
      ctx.fillText(i.toString(), x, H - 3);
    }

    // Area fill
    ctx.beginPath();
    for (let i = 0; i < history.length; i++) {
      const x = pad.left + (i / (maxN - 1)) * pW;
      const y = pad.top + (1 - history[i]) * pH;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    const lastX = pad.left + pW;
    ctx.lineTo(lastX, pad.top + pH);
    ctx.lineTo(pad.left, pad.top + pH);
    ctx.closePath();
    const grad = ctx.createLinearGradient(0, pad.top, 0, pad.top + pH);
    grad.addColorStop(0, 'rgba(96,165,250,0.2)');
    grad.addColorStop(1, 'rgba(96,165,250,0)');
    ctx.fillStyle = grad;
    ctx.fill();

    // Line
    ctx.beginPath();
    for (let i = 0; i < history.length; i++) {
      const x = pad.left + (i / (maxN - 1)) * pW;
      const y = pad.top + (1 - history[i]) * pH;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.strokeStyle = '#93c5fd';
    ctx.lineWidth = 2;
    ctx.lineJoin = 'round';
    ctx.stroke();

    // Dot
    const lastVal = history[history.length - 1];
    const dotX = pad.left + ((history.length - 1) / (maxN - 1)) * pW;
    const dotY = pad.top + (1 - lastVal) * pH;
    ctx.beginPath(); ctx.arc(dotX, dotY, 4, 0, Math.PI * 2);
    ctx.fillStyle = '#93c5fd'; ctx.fill();
  }

  /* ── Auto run ──────────────────────────────────────────────────────── */
  function startAuto() {
    if (autoInterval) return;
    $('btn-auto').innerHTML = '<svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24"><rect x="6" y="5" width="4" height="14"/><rect x="14" y="5" width="4" height="14"/></svg> Stop';
    $('btn-auto').classList.add('bg-red-900/30', 'border-red-800/50', 'text-red-300');
    autoInterval = setInterval(stepPacket, speed);
  }
  function stopAuto() {
    if (autoInterval) { clearInterval(autoInterval); autoInterval = null; }
    $('btn-auto').innerHTML = '<svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24"><path d="M4 18l8.5-6L4 6v12zm9-12v12l8.5-6L13 6z"/></svg> Auto';
    $('btn-auto').classList.remove('bg-red-900/30', 'border-red-800/50', 'text-red-300');
  }
  function toggleAuto() { autoInterval ? stopAuto() : startAuto(); }

  /* ── Slider labels ─────────────────────────────────────────────────── */
  function updateLabels() {
    $('val-mu').textContent = (parseInt($('slider-mu').value) / 100).toFixed(2);
    $('val-alpha').textContent = (parseInt($('slider-alpha').value) / 100).toFixed(2);
    $('val-payload').textContent = $('slider-payload').value + ' B';
    speed = parseInt($('slider-speed').value);
    $('val-speed').textContent = speed + ' ms';
    if (autoInterval) { stopAuto(); startAuto(); }
  }

  /* ── Key size toggle ───────────────────────────────────────────────── */
  function setKeySize(bytes) {
    keyBytes = bytes;
    const pill = $('toggle-pill');
    const t128 = $('toggle-128');
    const t256 = $('toggle-256');
    if (bytes === 16) {
      pill.style.left = '0.25rem'; pill.style.right = '';
      t128.className = 'flex-1 text-center text-xs z-10 py-1 text-white';
      t256.className = 'flex-1 text-center text-xs z-10 py-1 text-gray-400';
    } else {
      pill.style.left = ''; pill.style.right = '0.25rem';
      t128.className = 'flex-1 text-center text-xs z-10 py-1 text-gray-400';
      t256.className = 'flex-1 text-center text-xs z-10 py-1 text-white';
    }
    $('badge-keysize').innerHTML = (bytes * 8) + '-bit AES <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path d="M8 9l4-4 4 4m0 6l-4 4-4-4" stroke-linecap="round" stroke-linejoin="round" stroke-width="2"></path></svg>';
    resetSim();
  }

  /* ── Events ────────────────────────────────────────────────────────── */
  $('btn-step').addEventListener('click', stepPacket);
  $('btn-auto').addEventListener('click', toggleAuto);
  $('btn-reset').addEventListener('click', resetSim);
  $('toggle-128').addEventListener('click', () => setKeySize(16));
  $('toggle-256').addEventListener('click', () => setKeySize(32));
  $('slider-mu').addEventListener('input', updateLabels);
  $('slider-alpha').addEventListener('input', updateLabels);
  $('slider-payload').addEventListener('input', updateLabels);
  $('slider-speed').addEventListener('input', updateLabels);

  document.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'INPUT' && e.target.type === 'text') return;
    if (e.code === 'Space') { e.preventDefault(); stepPacket(); }
    if (e.code === 'KeyA') { e.preventDefault(); toggleAuto(); }
    if (e.code === 'KeyR') { e.preventDefault(); resetSim(); }
  });

  window.addEventListener('resize', () => {
    if (sim.equivocationHistory.length > 0) drawChart(sim.equivocationHistory);
  });

  resetSim();
})();
