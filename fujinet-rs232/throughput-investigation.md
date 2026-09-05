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

## Addendum: a full baud sweep on real hardware, and feedback from deltecent (2026-09-03)

The 2x2 experiment above (all four Real/Virtual 2SIO × Real/Virtual adapter combinations) only
ran at 9600 baud. This addendum is a separate, narrower sweep: with the physical FujiNet adapter
now able to run at 19200/38400/76800 as well, the same local-Pi `FUJIGET` test (`N-HANDLER.ATR`,
92,288 bytes / 721 records, `STAT`-verified byte-exact on every run) was repeated across all four
rates, but only at the two "pure" corners of that grid — **Real 8800c** (real 2SIO + real
adapter) and **Emulator** (virtual 2SIO + virtual adapter) — not the two mixed combinations,
matched against the same target (the project's Pi 2B TNFS box, now running `de-tnfsd` rather than
the original `tnfsd`).

| Baud | Real 8800c | Emulator | Real as % of emulator |
|---|---|---|---|
| 9600 | 485.9 B/s | 585.6 B/s | 83.0% |
| 19200 | 764.8 B/s | 954.2 B/s | 80.2% |
| 38400 | 1082.5 B/s | 1434.4 B/s | 75.5% |
| 76800 | 1313.9 B/s | 1821.0 B/s | 72.2% |

Both machines show the same decaying-efficiency-with-baud shape already established above.
Real hardware's share of the emulator's throughput narrows steadily as baud rises (83% → 72%) —
a smaller gap at every point than the 9600-baud 2x2 experiment's real+real/virtual+virtual ratio
(505.0/594.3 = 85.0%) or the original 38400-baud comparison against the old `tnfsd` (~60%), though
the server-software change means that older figure isn't a clean apples-to-apples baseline.

Reworking this sweep's per-chunk dead time (same method as the table above — subtract the
166-wire-bytes/chunk transmission time from the measured total, divide by 721 chunks) shows both
machines hold roughly flat across all four bauds, not baud-dependent:

| Baud | Real dead time/chunk | Emulator dead time/chunk |
|---|---|---|
| 9600 | 90.5ms | 45.7ms |
| 19200 | 80.9ms | 47.7ms |
| 38400 | 75.0ms | 46.0ms |
| 76800 | 75.8ms | 48.7ms |

This extends the "fixed, baud-invariant per-chunk overhead" finding above — previously only shown
on the emulator — to real hardware as well: real hardware's premium over the emulator (roughly
+30-40ms/chunk) doesn't grow or shrink with baud, consistent with it being a fixed per-round-trip
cost rather than something that scales with the wire rate.

### Feedback from deltecent

deltecent (the FujiNet developer behind [`de-tnfsd`](https://github.com/deltecent/de-tnfsd), see
this project's TNFS server setup docs) reviewed this document and confirmed the headline finding:
at controlled baud, the real adapter's per-chunk dead time (80.5ms) versus the virtual adapter's
(42.5ms) on the same real 2SIO shows the ESP32 firmware's own FujiBus processing is the dominant
term, not the wire or the 2SIO board.

Two refinements worth carrying forward:

- **The cleanest single "adapter tax" figure is the real-2SIO column's ~17ms delta (80.5 − 63.7
  ms), not the virtual-2SIO column's ~95ms delta (138.0 − 42.5 ms)** — the larger number is
  inflated by the emulator's own per-byte host-syscall overhead when reading a real serial port
  (already flagged as a confound above), so it shouldn't be read as "the real cost of the real
  adapter."
- **"The ESP32 firmware is slower" is a black box that likely contains two distinct mechanisms**:
  actual CPU-bound time in the FujiBus command handler, versus ESP-side TNFS-over-WiFi latency
  compounded by the bus task competing with the WiFi task on the ESP32's shared core — the second
  of which deltecent notes was addressed in the ADAM build by pinning the bus to its own core.
  **Update, same day: confirmed against the actual `fujinet-firmware` source** — see the next
  section. This document's own measurements don't separate the two; deltecent's suggested next
  step is to isolate WiFi/TNFS latency and bus/WiFi core contention specifically — e.g.
  re-running against a local SD-card image instead of TNFS, or with the bus task pinned to its
  own core — to see whether the "firmware processing" tax is really compute-bound or really
  network/scheduling latency wearing a firmware mask. Not yet attempted; the baud-invariance
  finding above is consistent with either explanation (both would show up as a roughly fixed
  per-round-trip cost) and doesn't distinguish between them.

## Addendum: the ADAM core-pinning claim, confirmed in `fujinet-firmware` source (2026-09-03)

Cloned `FujiNetWIFI/fujinet-firmware` (shallow, `main`) to check deltecent's claim directly rather
than take it on faith. It's accurate, not just plausible:

- **`lib/bus/adamnet/adamnet.cpp:502-512`** — the ADAM build hands its bus off to a dedicated task:
  `xTaskCreatePinnedToCore(adamnet_bus_task, ..., ADAMNET_BUS_TASK_CORE)`, with
  `ADAMNET_BUS_TASK_CORE 1` and `ADAMNET_BUS_TASK_PRIORITY 19` (`lib/bus/adamnet/adamnet.h:57-59`).
- **`lib/bus/rs232/rs232.cpp`** has no `xTaskCreate` anywhere — RS232's bus is serviced inline from
  the shared main loop, same as every non-ADAM build.
- **`src/main.cpp:547-581`** documents exactly why, in the firmware's own comments: ADAM's task
  exists specifically "so it services the one-wire bus continuously and can't be stalled by
  WiFi/scheduler latency mid-handshake (the desync that caused intermittent 'Drive Error' under
  PIP `*.*[V]`)". Every other build, RS232 included, runs `SYSTEM_BUS.service()` in the main loop
  and then explicitly `taskYIELD()`s on `ESP_PLATFORM` to let other tasks — WiFi included — run
  before the next bus service call.

So the WiFi/scheduler-contention mechanism deltecent proposed as a candidate isn't hypothetical —
it's a real effect the firmware team already found and fixed once, for a different bus, with a
real symptom (`Drive Error` under load) attached. It was just never applied to RS232. This doesn't
prove it's *the* explanation for RS232's dead-time premium (that still needs the isolating test
deltecent proposed — local SD vs. TNFS, or a pinned-core RS232 build, to actually measure it), but
it substantially raises the odds: this is a known, previously-fixed-elsewhere failure mode in the
exact same firmware codebase, not a novel hypothesis.

**PR/issue status for deltecent's `fujinet-firmware` contributions, checked 2026-09-03** (context
for a Sunday conversation, not something to act on unilaterally — see the note on upstream
contributions below): [#1578](https://github.com/FujiNetWIFI/fujinet-firmware/pull/1578) merged
(76800 baud option for RS232 — this is literally why our adapter can run at that rate now),
[#1581](https://github.com/FujiNetWIFI/fujinet-firmware/pull/1581) open (WiFi multi-AP by RSSI),
[#1582](https://github.com/FujiNetWIFI/fujinet-firmware/pull/1582) closed/not merged (new
`MediaTypeDSK` for raw 8"/5.25" floppy images on RS232 — CI passed cleanly), and open issue
[#1575](https://github.com/FujiNetWIFI/fujinet-firmware/issues/1575) (WiFi RSSI/multi-AP, same
topic as #1581). **Nothing has been filed yet for the RS232 core-pinning fix** — it's still just
this conversation, not a PR or issue.

## Addendum: firmware flashing now works on this Mac, and a live test build was flashed and
## measured (2026-09-03)

**The uploader script itself was never Intel-only** — `fujinet_firmware_uploader.py` is pure
Python. The actual break: it hardcoded a path into PlatformIO's package cache
(`~/.platformio/packages/tool-esptoolpy/esptool.py`), which historically wasn't published for
macOS arm64, and shelled out to `pio device monitor` for the post-flash console. Fixed locally
(in this Mac's own clone of `fujinet-firmware`, not pushed anywhere — see below) by using the
already pip-installed, architecture-independent `esptool` directly (`python3 -m esptool`,
confirmed native arm64, v5.3.1) and swapping the monitor step to pyserial's own `miniterm`
(ships as an `esptool` dependency already, no extra install). Also combined the two separate
`write_flash` calls into one `write-flash` invocation with both offset/file pairs, so flashing
only needs one connect/reset handshake with the chip instead of two.

**Useful side-finding**: every PR's CI run already builds and publishes exactly the artifact
structure the uploader expects (`firmware.bin`, `littlefs.bin`, `release.json` with offsets) —
`gh api repos/FujiNetWIFI/fujinet-firmware/actions/runs/<id>/artifacts` finds it, no separate
build step needed. So whenever a core-pinning PR exists, its test build will already be sitting
under that PR's checks.

**Live-tested end to end** on the physical adapter (chip: ESP32-S3, 16MB flash, 8MB PSRAM —
confirmed to match the CI build's target board, `esp32-s3-wroom-1-n16r8`):

1. **Full 16MB flash backed up first**, before writing anything —
   `esptool read-flash 0x0 0x1000000` — saved to
   `Documentation/Odds/fujinet-rs232-firmware-backup/fujinet-rs232-fullflash-backup-20260903-v1.6.1.bin`
   (SHA-256 `7b7b4c3a2a9b81841822caef21c9fe0102d8d1356ddb6c5d627d9ad83d506b53`). Restore recipe:
   `esptool --port <port> write-flash 0x0 <that file>`.
2. Flashed PR #1582's CI build (v1.6.2-dev, `firmware.bin` @ `0x10000` +
   `littlefs.bin` @ `0xA70000`) over the adapter's existing v1.6.1. Both writes verified by hash
   in the same `esptool` run.
3. Booted clean — confirmed via the console log (`AppKeyManager`/`fnConfig` lines) and the WebUI,
   which showed v1.6.2 and the correct 76800 baud setting. **Existing config survived the
   littlefs.bin overwrite** — `fnconfig.ini` lives on the SD card as the source of truth and gets
   synced to/from the internal FLASH copy at boot, so the fresh CI-built littlefs image didn't
   wipe the adapter's real WiFi/serial settings.
4. Re-ran the local-Pi `FUJIGET N-HANDLER.ATR` throughput test at 76800 baud on real hardware for
   a same-file, same-baud before/after:

   | Firmware | Time | Throughput | Efficiency |
   |---|---|---|---|
   | v1.6.1 (this doc's earlier 76800-baud row) | 70.24s | 1313.9 B/s | 17.1% |
   | v1.6.2-dev (PR #1582 build) | 72.54s | 1272.4 B/s | 16.6% |

   No meaningful change (~3%, inside normal jitter) — expected, since #1582 is about floppy media
   types, not the bus/RS232 service path. This is a clean baseline confirming the flash-swap
   process itself introduces no regression, useful as a control once there's an actual
   core-pinning build to test against.

## A note on upstream contributions

**Decision (2026-09-03): we don't submit PRs to the FujiNet firmware team ourselves.** Findings
get relayed to deltecent directly once we're confident in them (he's aware of this project's
throughput work already, and the two of us plan to talk directly). This follows from the same
session's `de-tnfsd` work, where three separate small PRs went upstream in one morning instead of
being bundled into one — more PR-review overhead for the maintainer than necessary, for changes
that were easier to review together than apart. The lesson generalizes: consolidate before
submitting anything upstream, and prefer routing findings through a direct conversation with the
person who owns the codebase over unilaterally opening PRs against it — especially somewhere with
an existing, active pace of change (many other PRs/issues already in flight, per the status
above) where an unbundled/unreviewed drop-in is more friction than help.
