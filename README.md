# AAA Secret-Key Generation Engine

An implementation of the **Accumulative, Adaptable, and Additive (AAA)** secret-key generation method designed for mobile networks and wireless communications. 

This repository contains a lightweight C engine for embedded systems and a visually interactive dashboard to demonstrate the key generation concepts described in *"A Remark on the AAA Method for Secret-Key Generation in Mobile Networks"* by Y. Hua (IEEE Wireless Commun. Letters, Dec. 2025).

## ⚡ Live Demo

[**Launch the Interactive Dashboard**](https://kaushikvada3.github.io/AAA-Implementation/)

![AAA Key Engine Dashboard Preview](dashboard_preview.png)

The web dashboard is a complete JavaScript port of the C engine, allowing you to visualize:
- Packet flow between Alice and Bob
- Real-time XOR key accumulation
- Eve's packet interception and resulting partial key knowledge
- Eventual achievement of perfect secrecy (Equivocation $\epsilon_n \to 1.0$)

## 🛠 Features Operations

- **Hardware Portable:** The core C engine (`aaa_key_engine.c`) is designed for embedded microcontrollers (ARM Cortex-M, ESP32, RISC-V). It requires no dynamic memory allocation (`malloc`).
- **Configurable Key Size:** Supports 128-bit, 256-bit, or custom key sizes via a direct compile-time macro or runtime toggle in the GUI.
- **Resilient to Correlation:** Theorem 1 of the paper proves that even if intercepted packets are highly correlated (Markov model), perfect secrecy is achieved asymptotically.
- **Lightweight PRNG:** Uses a fast Xorshift32 algorithm for the public bit-selection protocol.

## 📦 Project Structure

```
├── aaa_key_engine.h    # Core C API headers
├── aaa_key_engine.c    # portable C engine implementation
├── aaa_demo.c          # CLI demonstration of 3 simulated scenarios
├── gui/                # Interactive web dashboard (HTML/CSS/JS)
│   ├── index.html      # Professional Tailwind-based UI
│   ├── app.js          # App logic and charting
│   └── engine.js       # JS port of the AAA engine
├── A_Remark_...pdf     # Reference paper
└── LICENSE             # MIT License
```

## 🚀 Building the C Engine

You can run the interactive CLI demo directly with GCC:

```bash
gcc -O2 -Wall -o aaa_demo aaa_demo.c aaa_key_engine.c -lm
./aaa_demo
```

### Integration into your custom Radio stack

To use this in your own project, just copy `aaa_key_engine.h` and `aaa_key_engine.c` into your source tree. See Scenario 3 in `aaa_demo.c` for a complete integration template with a mock packet receive callback.

## 📖 How AAA Works

The core principle is elegantly simple but cryptographically secure. For a desired key length $L$:

1. Alice and Bob publicly agree on a PRNG seed.
2. For every packet $i$ received successfully by both, they use the PRNG to select $L$ bits from the random payload ($X_{l,i}$).
3. The key after $n$ packets is the cumulative XOR sum:
   $$K_{l,n} = X_{l,1} \oplus X_{l,2} \oplus \dots \oplus X_{l,n}$$
4. Security relies on Eve missing at least one packet. Once she misses a packet that Alice and Bob both received, she permanently loses the deterministic chain required to resolve the XOR accumulation, and her equivocation (uncertainty) per bit approaches 1.0.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
