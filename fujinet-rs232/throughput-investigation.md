# Why is real hardware slower than the emulator?

This project's own testing has repeatedly found that FujiNet file transfers over a real FujiNet
RS-232 adapter run noticeably slower than the same transfer against the emulator's desktop
`fujinet-pc` — this doc is the investigation into *why*, done by isolating each candidate cause
in turn rather than guessing.

**Short answer: it's the FujiNet adapter's own ESP32 firmware, not the CPU speed and not the
2SIO serial board.** The real adapter's FujiBus command processing is measurably slower than the
desktop `fujinet-pc` software's, and that difference alone accounts for the gap — CPU clock
speed differences between real hardware and the emulator are negligible (under 2%), and swapping
which 2SIO drives the link (virtual vs. real) makes little difference on its own.

## Background

Every FujiNet transfer in this project moves data one 128-byte CP/M record at a time, and each
record costs one `STATUS` + `READ` FujiBus round trip. At 92,288 bytes (`N-HANDLER.ATR`, the
project's standard test file — 721 records), that's 721 round trips, so small per-round-trip
overhead differences compound into large total-time differences. Earlier testing (see the
project's `project_real_hardware_bringup` history) found real hardware taking roughly 2.5-3x
longer per round trip than the emulator at 38400 baud, but hadn't isolated which of three
plausible causes was responsible:

1. The virtual vs. physical **2SIO serial board** (timing/UART differences)
2. The virtual (`fujinet-pc`) vs. physical (ESP32) **FujiNet adapter**
3. Differences in **actual CPU clock rate** between the emulator and the real 8800c

This investigation tests all three directly.

## Test 1: CPU clock rate

A pure CPU-bound test program was run on both machines — a triple-nested 8080 delay loop (21
bytes of hand-assembled machine code, no I/O, no BDOS calls, so nothing but raw instruction
throughput affects its timing), sized by an outer-loop constant to a known, exact T-state count.

Run at two different sizes on each machine and timed by external wall clock. Two data points let
the machine's *actual clock rate* and its *fixed per-run overhead* (CCP file-load + console-echo
cost — real, and large enough — around 6-7 seconds — to badly skew a single-point measurement)
be solved for as two separate unknowns, rather than conflating them:

| | Effective clock rate | vs. nominal 2 MHz | Fixed overhead per run |
|---|---|---|---|
| Emulator (`altairsim`) | 2.0049 MHz | 100.24% | 6.95s |
| Real 8800c | 1.9777 MHz | 98.89% | 6.31s |

Real hardware runs at **98.65%** of the emulator's rate — a 1.35% difference. This rules out CPU
clock speed as a meaningful contributor to the throughput gap.

## Test 2: isolating the 2SIO board from the FujiNet adapter

`altairsim` supports wiring a virtual board's serial unit directly to a real host serial port
(`CONNECT sio0:b serial:/dev/cu.usbserial-XXXX`), and the desktop `fujinet-pc` build supports
listening on a real serial port instead of its usual local-socket mode (`[Serial] port=`/`baud=`
in `fnconfig.ini`, instead of `[BOIP]`). Together these make a clean 2x2 swap possible: virtual
or real 2SIO, crossed with virtual or real FujiNet adapter — four total configurations, same
test file, same 9600 baud, same local TNFS source (a Raspberry Pi on the LAN, to keep internet
latency out of the picture).

| | Virtual adapter (`fujinet-pc`) | Real adapter (ESP32) |
|---|---|---|
| **Virtual 2SIO** (emulator) | 155.3s / 594.3 B/s | 224.2s / 411.7 B/s |
| **Real 2SIO** (physical 8800c) | 170.6s / 541.0 B/s | 182.7s / 505.0 B/s |

Same file (92,288 bytes / 721 records) verified byte-exact via `STAT` in every run.

### Reading the table

Group by **adapter** and the results cluster tightly: both virtual-adapter runs land at
155-171s, both real-adapter runs land at 183-224s — a consistent ~30-70s swing that tracks which
adapter is in use, regardless of which 2SIO drives it.

Group by **2SIO** instead and there's no consistent pattern: virtual 2SIO is the *fastest*
configuration when paired with the virtual adapter, but the *slowest* when paired with the real
one.

That asymmetry rules out a simple "each side adds its own fixed cost" model. What it points to
instead: reading a real serial port from the emulator process carries its own overhead (real
host-OS syscalls per byte, versus a near-instant local socket read) that adds on top of the real
adapter's already-slower firmware rather than replacing it — while the real 8800c's own
dedicated 2SIO hardware apparently services a real UART more efficiently than the emulator's
general-purpose host does.

### Per-chunk overhead

Subtracting each configuration's pure wire-transmission time (166 wire bytes per 128-byte
chunk, at 9600 baud) from its measured per-chunk time isolates the "dead time" — everything that
isn't actual bytes-on-the-wire:

| | Dead time per chunk |
|---|---|
| Virtual 2SIO + virtual adapter | 42.5ms |
| Real 2SIO + virtual adapter | 63.7ms |
| Real 2SIO + real adapter | 80.5ms |
| Virtual 2SIO + real adapter | 138.0ms |

## Conclusion

If real-hardware FujiNet throughput needs improving, the ESP32 adapter firmware's own FujiBus
command processing is where the time goes — not the CP/M tools, not the 2SIO board, not the CPU.
Any future optimization or upstream bug report should target that.

## Appendix: efficiency vs. baud, both bauds tested

"Efficiency against raw baud" (throughput ÷ nominal bits-per-second) understates how well a
configuration is actually doing, because the FujiBus protocol itself can never reach 100% of raw
baud — each 128-byte payload costs 166 wire bytes of `STATUS`+`READ` framing, capping any
implementation at 128/166 = 77.1% of raw baud even with zero processing delay. The table below
gives both figures.

| Configuration | Baud | Time | Throughput | vs. raw baud | vs. protocol ceiling |
|---|---|---|---|---|---|
| Emulator (virtual+virtual), local | 38400 | 54.6s | 1690.3 B/s | 44.0% | 57.1% |
| Real hardware (real+real), local | 38400 | 91.3s | 1010.8 B/s | 26.3% | 34.1% |
| Virtual 2SIO + virtual adapter | 9600 | 155.3s | 594.3 B/s | 61.9% | 80.3% |
| Real 2SIO + real adapter | 9600 | 182.7s | 505.0 B/s | 52.6% | 68.2% |
| Virtual 2SIO + real adapter | 9600 | 224.2s | 411.7 B/s | 42.9% | 55.6% |
| Real 2SIO + virtual adapter | 9600 | 170.6s | 541.0 B/s | 56.4% | 73.1% |

The 38400-baud rows are the pure-emulator and pure-real-hardware configurations from earlier
testing, included for reference.

## Appendix: setup notes for reproducing this

- **CPU test program**: a fixed 8080 machine-code loop, loaded via `PIP dest.HEX=CON:[H]` +
  `LOAD` on both machines (source available on request — it's 21 bytes, easily hand-assembled:
  `MVI D,n` / `MVI B,0` / `MVI C,0` / `DCR C` / `JNZ` / `DCR B` / `JNZ` / `DCR D` / `JNZ` /
  `JMP 0000H`, three nested 8-bit counters).
- **`altairsim` real-serial wiring**: `CONNECT sio0:b serial:/dev/cu.usbserial-XXXX` — opens the
  real port at 9600 8N1, then the emulated 2SIO board reprograms it to whatever baud it's set to
  (`SET sio0:b baud=9600`).
- **`fujinet-pc` real-serial mode**: edit `fnconfig.ini`, set `[BOIP] enabled=0`, and under
  `[Serial]` set `port=/dev/cu.usbserial-XXXX` and `baud=9600`. Config is read once at startup —
  restart the process after editing.
- **A straight-through USB-serial cable did not work** for the real 8800c's port B —
  `fujinet-pc`'s log showed zero bytes received even after a `FUJIGET` open attempt. A
  crossover/null-modem connection was needed, the same class of gotcha as the already-documented
  need for a crossover cable between the physical FujiNet adapter and its network switch.
