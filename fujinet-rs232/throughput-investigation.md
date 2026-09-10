# Why is real hardware slower than the emulator?

This project tested FujiNet file transfers many times. Real hardware, over a real FujiNet
RS-232 adapter, sends files slower than the emulator's desktop `fujinet-pc` software. This
document explains why. It isolates each possible cause, one at a time, instead of guessing.

**Short answer:** the cause is the FujiNet adapter's own ESP32 firmware. It is not the CPU
speed. It is not the 2SIO serial board. The real adapter's FujiBus command processing is
slower than the desktop `fujinet-pc` software's processing. This difference alone accounts
for the whole gap. CPU clock speed differences between real hardware and the emulator are
small, under 2%. The choice of 2SIO board, virtual or real, makes little difference by
itself.

**Update (2026-09-09):** see the closing addendum at the bottom of this document. The ESP32
firmware fixes below, core-pinning and the UART tick fix, were real and worth the work. But
they were only part of the story. The team added timers to the adapter's own firmware. The
timers measured each stage of a round trip on its own. This test found the largest remaining
cost on real hardware. The cost is not the adapter. The cost is the 8800c's own disk write,
through the FDC+ card's serial link to its disk emulator. See "Closing the investigation"
below for the full breakdown. It also explains why buffering the writes does not help.

## Background

Every FujiNet transfer in this project moves data one 128-byte CP/M record at a time. Each
record costs one `STATUS` + `READ` FujiBus round trip.

The project's standard test file, `N-HANDLER.ATR`, is 92,288 bytes, or 721 records. So one
transfer needs 721 round trips. Small differences in the cost of one round trip add up to
large differences in total time.

Earlier testing found that real hardware took about 2.5 to 3 times longer per round trip
than the emulator, at 38400 baud. See the project's `project_real_hardware_bringup` history
for that test. But that testing did not isolate which of three possible causes was
responsible:

1. The 2SIO serial board: virtual or physical (timing and UART differences)
2. The FujiNet adapter: virtual (`fujinet-pc`) or physical (ESP32)
3. The actual CPU clock rate: differences between the emulator and the real 8800c

This investigation tests all three directly.

## Test 1: CPU clock rate

The team ran a CPU-bound test program on both machines. The program was a triple-nested
8080 delay loop. The loop is 21 bytes of hand-assembled machine code. It has no I/O and no
BDOS calls. So only raw instruction speed affects its timing. An outer-loop constant sets
the loop to an exact, known T-state count.

The team ran the loop at two sizes on each machine. They timed each run with an external
wall clock. Two data points let the team solve for two separate values: the machine's actual
clock rate, and its fixed cost per run. The fixed cost per run comes from the CCP file load
and the console echo. This cost is real. It is about 6 to 7 seconds, large enough to skew a
single measurement badly.

| | Effective clock rate | vs. nominal 2 MHz | Fixed overhead per run |
|---|---|---|---|
| Emulator (`altairsim`) | 2.0049 MHz | 100.24% | 6.95s |
| Real 8800c | 1.9777 MHz | 98.89% | 6.31s |

Real hardware runs at 98.65% of the emulator's rate, a difference of 1.35%. This rules out
CPU clock speed as a real cause of the throughput gap.

## Test 2: isolating the 2SIO board from the FujiNet adapter

`altairsim` can wire a virtual board's serial unit directly to a real host serial port. The
command is `CONNECT sio0:b serial:/dev/cu.usbserial-XXXX`.

The desktop `fujinet-pc` build can also listen on a real serial port. This replaces its
usual local-socket mode. Set `[Serial] port=` and `baud=` in `fnconfig.ini`, instead of
`[BOIP]`.

Together, these two features allow a clean 2x2 test: virtual or real 2SIO, crossed with
virtual or real FujiNet adapter. This gives four configurations. Every configuration used
the same test file, the same 9600 baud rate, and the same local TNFS source: a Raspberry Pi
on the LAN. This kept internet latency out of the test.

| | Virtual adapter (`fujinet-pc`) | Real adapter (ESP32) |
|---|---|---|
| **Virtual 2SIO** (emulator) | 155.3s / 594.3 B/s | 224.2s / 411.7 B/s |
| **Real 2SIO** (physical 8800c) | 170.6s / 541.0 B/s | 182.7s / 505.0 B/s |

Every run used the same file, 92,288 bytes and 721 records. `STAT` confirmed the file was
byte-exact in every run.

### Reading the table

Group the results by adapter, and they cluster tightly. Both virtual-adapter runs land at
155 to 171 seconds. Both real-adapter runs land at 183 to 224 seconds. This is a consistent
swing of about 30 to 70 seconds. The swing tracks which adapter is in use. It does not
depend on which 2SIO drives it.

Group the results by 2SIO instead, and there is no consistent pattern. The virtual 2SIO is
the fastest configuration when paired with the virtual adapter. But it is the slowest
configuration when paired with the real adapter.

This pattern rules out a simple model, where each side adds its own fixed cost. Instead, it
points to a different cause. Reading a real serial port from the emulator process has its
own overhead. The overhead is a real host-OS system call for every byte, instead of a
near-instant local socket read. This overhead adds on top of the real adapter's slower
firmware. It does not replace that cost. At the same time, the real 8800c's own dedicated
2SIO hardware seems to service a real UART better than the emulator's general-purpose host
does.

### Per-chunk overhead

Each 128-byte chunk needs 166 wire bytes, at 9600 baud. This is the pure wire-transmission
time. Subtract this wire-transmission time from the measured time per chunk. The result is
the "dead time": everything that is not actual bytes on the wire.

| | Dead time per chunk |
|---|---|
| Virtual 2SIO + virtual adapter | 42.5ms |
| Real 2SIO + virtual adapter | 63.7ms |
| Real 2SIO + real adapter | 80.5ms |
| Virtual 2SIO + real adapter | 138.0ms |

## Conclusion

If real-hardware FujiNet throughput needs improvement, look at the ESP32 adapter firmware's
own FujiBus command processing. That is where the time goes. It is not the CP/M tools. It is
not the 2SIO board. It is not the CPU. Any future optimization or upstream bug report should
target the FujiBus command processing.

## Appendix: efficiency vs. baud, both bauds tested

"Efficiency against raw baud" is throughput divided by the nominal bits-per-second rate.
This measure understates how well a configuration actually performs. The reason: the
FujiBus protocol itself can never reach 100% of raw baud. Each 128-byte payload costs 166
wire bytes of `STATUS` and `READ` framing. This caps any implementation at 128/166, or
77.1%, of raw baud, even with zero processing delay. The table below gives both figures.

| Configuration | Baud | Time | Throughput | vs. raw baud | vs. protocol ceiling |
|---|---|---|---|---|---|
| Emulator (virtual+virtual), local | 38400 | 54.6s | 1690.3 B/s | 44.0% | 57.1% |
| Real hardware (real+real), local | 38400 | 91.3s | 1010.8 B/s | 26.3% | 34.1% |
| Virtual 2SIO + virtual adapter | 9600 | 155.3s | 594.3 B/s | 61.9% | 80.3% |
| Real 2SIO + real adapter | 9600 | 182.7s | 505.0 B/s | 52.6% | 68.2% |
| Virtual 2SIO + real adapter | 9600 | 224.2s | 411.7 B/s | 42.9% | 55.6% |
| Real 2SIO + virtual adapter | 9600 | 170.6s | 541.0 B/s | 56.4% | 73.1% |

The rows for 38400 baud are the pure-emulator and pure-real-hardware configurations from
earlier testing. They are included for reference.

## Appendix: setup notes for reproducing this

- **CPU test program**: a fixed 8080 machine-code loop. Load it with `PIP
  dest.HEX=CON:[H]` and then `LOAD`, on both machines. The source is available on request.
  It is 21 bytes, and easy to hand-assemble: `MVI D,n` / `MVI B,0` / `MVI C,0` / `DCR C` /
  `JNZ` / `DCR B` / `JNZ` / `DCR D` / `JNZ` / `JMP 0000H`. This is three nested 8-bit
  counters.
- **`altairsim` real-serial wiring**: `CONNECT sio0:b serial:/dev/cu.usbserial-XXXX` opens
  the real port at 9600 8N1. Then the emulated 2SIO board reprograms it to the baud rate you
  set, for example `SET sio0:b baud=9600`.
- **`fujinet-pc` real-serial mode**: edit `fnconfig.ini`. Set `[BOIP] enabled=0`. Under
  `[Serial]`, set `port=/dev/cu.usbserial-XXXX` and `baud=9600`. The config file is read
  once, at startup. Restart the process after you edit it.
- **A straight-through USB-serial cable did not work** for the real 8800c's port B.
  `fujinet-pc`'s log showed zero bytes received, even when it tried to open the file with
  `FUJIGET`. A crossover, or null-modem, connection was needed. This is the same kind of
  problem as the documented need for a crossover cable between the physical FujiNet adapter
  and its network switch.

## Addendum: a full baud sweep on real hardware, and feedback from deltecent (2026-09-03)

The 2x2 experiment above ran all four combinations of real/virtual 2SIO and real/virtual
adapter. But it only ran at 9600 baud.

This addendum is a separate, narrower sweep. The physical FujiNet adapter can now also run
at 19200, 38400, and 76800 baud. The team repeated the same local-Pi `FUJIGET` test across
all four rates. The test file was `N-HANDLER.ATR`, 92,288 bytes and 721 records, and `STAT`
confirmed it was byte-exact on every run.

This sweep only tested the two "pure" corners of the grid: **Real 8800c** (real 2SIO and
real adapter), and **Emulator** (virtual 2SIO and virtual adapter). It did not test the two
mixed combinations. Every test used the same target: the project's Pi 2B TNFS box. This box
now runs `de-tnfsd`, instead of the original `tnfsd`.

| Baud | Real 8800c | Emulator | Real as % of emulator |
|---|---|---|---|
| 9600 | 485.9 B/s | 585.6 B/s | 83.0% |
| 19200 | 764.8 B/s | 954.2 B/s | 80.2% |
| 38400 | 1082.5 B/s | 1434.4 B/s | 75.5% |
| 76800 | 1313.9 B/s | 1821.0 B/s | 72.2% |

Both machines show the same shape: efficiency decays as baud rises. This shape matches the
earlier finding above. Real hardware's share of the emulator's throughput narrows steadily
as baud rises, from 83% to 72%. This gap is smaller at every point than two earlier
comparisons: the 9600-baud 2x2 experiment's ratio of 505.0/594.3, or 85.0%, and the original
38400-baud comparison against the old `tnfsd`, about 60%. But the server software changed
between tests. So that older 60% figure is not a clean, direct comparison.

The team reworked this sweep's per-chunk dead time, using the same method as the table
above: subtract the 166-wire-bytes-per-chunk transmission time from the measured total, then
divide by 721 chunks. Both machines hold roughly flat across all four baud rates. The dead
time does not depend on baud.

| Baud | Real dead time/chunk | Emulator dead time/chunk |
|---|---|---|
| 9600 | 90.5ms | 45.7ms |
| 19200 | 80.9ms | 47.7ms |
| 38400 | 75.0ms | 46.0ms |
| 76800 | 75.8ms | 48.7ms |

This extends the earlier finding of a fixed, baud-invariant per-chunk overhead, shown before
only on the emulator, to real hardware as well. Real hardware's extra cost over the
emulator, about 30 to 40 milliseconds per chunk, does not grow or shrink with baud. This
fits a fixed cost per round trip. It does not fit a cost that scales with the wire rate.

### Feedback from deltecent

deltecent is the FujiNet developer behind [`de-tnfsd`](https://github.com/deltecent/de-tnfsd).
See this project's TNFS server setup docs for more detail. deltecent reviewed this document
and confirmed the headline finding. At a controlled baud, on the same real 2SIO: the real
adapter's per-chunk dead time is 80.5ms, and the virtual adapter's is 42.5ms. This shows the
ESP32 firmware's own FujiBus processing is the dominant cost. It is not the wire. It is not
the 2SIO board.

Two refinements worth carrying forward:

- **The cleanest single figure for the "adapter tax" is the real-2SIO column's delta of
  about 17ms (80.5 minus 63.7 ms).** It is not the virtual-2SIO column's delta of about 95ms
  (138.0 minus 42.5 ms). The larger number is inflated by the emulator's own per-byte
  host-syscall overhead, when it reads a real serial port. The section above already flags
  this as a confound. So do not read the 95ms figure as "the real cost of the real adapter."
- **"The ESP32 firmware is slower" is likely a black box with two separate causes inside
  it.** One cause: actual CPU-bound time in the FujiBus command handler. The other cause:
  ESP-side TNFS-over-WiFi latency, made worse by the bus task competing with the WiFi task on
  the ESP32's shared core. deltecent notes that the ADAM build already fixed the second
  cause, by pinning the bus to its own core. **Update, same day:** the team confirmed this
  against the actual `fujinet-firmware` source. See the next section. This document's own
  measurements do not separate the two causes. deltecent's suggested next step: isolate
  WiFi/TNFS latency from bus/WiFi core contention. For example, re-run the test against a
  local SD-card image instead of TNFS, or with the bus task pinned to its own core. This
  would show whether the "firmware processing" tax is really compute-bound, or really network
  and scheduling latency that looks like firmware cost. The team has not tried this yet. The
  baud-invariance finding above fits either explanation. Both would show up as a roughly
  fixed cost per round trip. The finding does not tell them apart.

## Addendum: the ADAM core-pinning claim, confirmed in `fujinet-firmware` source (2026-09-03)

The team cloned `FujiNetWIFI/fujinet-firmware`, a shallow clone of `main`, to check
deltecent's claim directly instead of trusting it. The claim is accurate, not just possible:

- **`lib/bus/adamnet/adamnet.cpp:502-512`**: the ADAM build hands its bus off to a dedicated
  task, with `xTaskCreatePinnedToCore(adamnet_bus_task, ..., ADAMNET_BUS_TASK_CORE)`. It sets
  `ADAMNET_BUS_TASK_CORE 1` and `ADAMNET_BUS_TASK_PRIORITY 19`
  (`lib/bus/adamnet/adamnet.h:57-59`).
- **`lib/bus/rs232/rs232.cpp`** has no `xTaskCreate` anywhere. RS232's bus is serviced
  inline, from the shared main loop, the same as every non-ADAM build.
- **`src/main.cpp:547-581`** documents exactly why, in the firmware's own comments. ADAM's
  task exists "so it services the one-wire bus continuously and can't be stalled by
  WiFi/scheduler latency mid-handshake." This is the desync that caused intermittent 'Drive
  Error' under PIP `*.*[V]`. Every other build, RS232 included, runs `SYSTEM_BUS.service()`
  in the main loop. Then it calls `taskYIELD()` on `ESP_PLATFORM`. This lets other tasks,
  WiFi included, run before the next bus service call.

So the WiFi/scheduler-contention mechanism deltecent proposed is not just a hypothesis. It
is a real effect. The firmware team already found and fixed this effect once, for a
different bus. It had a real symptom: `Drive Error` under load. The team just never applied
the fix to RS232. This does not prove it is *the* explanation for RS232's extra dead time.
That still needs the isolating test deltecent proposed: local SD versus TNFS, or a
pinned-core RS232 build, to actually measure it. But it raises the odds a great deal. This is
a known failure mode, already fixed elsewhere in the exact same firmware codebase. It is not
a new, untested idea.

**PR and issue status for deltecent's `fujinet-firmware` contributions, checked
2026-09-03.** This is context for a Sunday conversation. It is not something to act on
alone. See the note on upstream contributions below.

- [#1578](https://github.com/FujiNetWIFI/fujinet-firmware/pull/1578): merged. It adds the
  76800 baud option for RS232. This is the reason our adapter can run at that rate now.
- [#1581](https://github.com/FujiNetWIFI/fujinet-firmware/pull/1581): open. It adds WiFi
  multi-AP by RSSI.
- [#1582](https://github.com/FujiNetWIFI/fujinet-firmware/pull/1582): closed, not merged. It
  would add a new `MediaTypeDSK` for raw 8-inch and 5.25-inch floppy images on RS232. CI
  passed cleanly.
- Issue [#1575](https://github.com/FujiNetWIFI/fujinet-firmware/issues/1575): open. Same
  topic as #1581, WiFi RSSI and multi-AP.

**Nothing has been filed yet for the RS232 core-pinning fix.** It is still just this
conversation, not a PR or an issue.

## Addendum: firmware flashing works on this Mac now; a live test build was flashed and measured (2026-09-03)

**The uploader script itself was never Intel-only.** `fujinet_firmware_uploader.py` is pure
Python. The real break was different: the script hardcoded a path into PlatformIO's package
cache, `~/.platformio/packages/tool-esptoolpy/esptool.py`. This path was not published for
macOS arm64 in the past. The script also shelled out to `pio device monitor` for the
post-flash console.

The team fixed this locally, in this Mac's own clone of `fujinet-firmware`. The fix is not
pushed anywhere; see below. The fix: use the already pip-installed, architecture-independent
`esptool` directly, with `python3 -m esptool`, confirmed as native arm64, version 5.3.1. It
also swaps the monitor step to pyserial's own `miniterm`, which already ships as an
`esptool` dependency, so it needs no extra install. The team also combined the two separate
`write_flash` calls into one `write-flash` call, with both offset and file pairs. So
flashing now needs only one connect and reset handshake with the chip, instead of two.

**Useful side-finding:** every PR's CI run already builds and publishes exactly the artifact
structure the uploader expects: `firmware.bin`, `littlefs.bin`, and `release.json` with
offsets. The command `gh api repos/FujiNetWIFI/fujinet-firmware/actions/runs/<id>/artifacts`
finds these files. No separate build step is needed. So when a core-pinning PR exists, its
test build will already sit under that PR's checks.

**The team live-tested this end to end**, on the physical adapter. The chip is an
ESP32-S3, with 16MB flash and 8MB PSRAM. This matches the CI build's target board,
`esp32-s3-wroom-1-n16r8`.

1. The team backed up the full 16MB flash first, before writing anything. The command was
   `esptool read-flash 0x0 0x1000000`. They saved the backup to
   `Documentation/Odds/fujinet-rs232-firmware-backup/fujinet-rs232-fullflash-backup-20260903-v1.6.1.bin`,
   SHA-256 `7b7b4c3a2a9b81841822caef21c9fe0102d8d1356ddb6c5d627d9ad83d506b53`. To restore it:
   `esptool --port <port> write-flash 0x0 <that file>`.
2. They flashed PR #1582's CI build, v1.6.2-dev, over the adapter's existing v1.6.1:
   `firmware.bin` at `0x10000`, and `littlefs.bin` at `0xA70000`. The same `esptool` run
   verified both writes by hash.
3. The adapter booted clean. The console log, its `AppKeyManager` and `fnConfig` lines, and
   the WebUI confirmed this. The WebUI showed v1.6.2 and the correct 76800 baud setting.
   **The existing config survived the `littlefs.bin` overwrite.** `fnconfig.ini` lives on
   the SD card, as the source of truth. It syncs to and from the internal FLASH copy at
   boot. So the fresh CI-built littlefs image did not wipe the adapter's real WiFi and
   serial settings.
4. The team re-ran the local-Pi `FUJIGET N-HANDLER.ATR` throughput test at 76800 baud, on
   real hardware. This gave a same-file, same-baud before-and-after comparison:

   | Firmware | Time | Throughput | Efficiency |
   |---|---|---|---|
   | v1.6.1 (this doc's earlier 76800-baud row) | 70.24s | 1313.9 B/s | 17.1% |
   | v1.6.2-dev (PR #1582 build) | 72.54s | 1272.4 B/s | 16.6% |

   There was no real change, about 3%, inside normal jitter. This was expected, since #1582
   is about floppy media types, not the bus and RS232 service path. This gives a clean
   baseline. It confirms the flash-swap process itself does not cause a regression. It will
   be a useful control once an actual core-pinning build exists to test.

## A note on upstream contributions

**Decision (2026-09-03): the team does not submit PRs to the FujiNet firmware team.**

Instead, the team relays findings directly to deltecent, once they are confident in them.
deltecent already knows about this project's throughput work. The two plan to talk directly.

This decision follows from the same session's `de-tnfsd` work. There, three separate small
PRs went upstream in one morning, instead of one bundled PR. This gave the maintainer more
PR-review work than needed, for changes that were easier to review together.

The lesson applies more broadly: consolidate changes before you submit anything upstream.
Prefer a direct conversation with the person who owns the codebase, over opening PRs against
it alone. This matters even more in a codebase with an active pace of change, like this one,
with many other PRs and issues already in flight. There, an unbundled, unreviewed drop-in
causes more friction than help.

## Addendum: the core-pinning fix shipped and measured, plus a second firmware fix and the client-side round-trip cuts (2026-09-04 to 2026-09-08)

This is a condensed summary of everything between the previous addendum and the closing
addendum below. The previous addendum confirmed, at the source level, that the core-pinning
mechanism was real, but not yet applied. Full detail lives in this project's own session
memory, if any of it needs review again.

**RS232 core-pinning, mirroring ADAM's existing fix.** This is on the `rs232-core-pin`
branch, pushed to a fork only, with no PR; see the note above. A dedicated, high-priority
core-1 FreeRTOS task now services the RS232 bus continuously. It no longer shares the main
loop with WiFi and scheduler work. The team measured this on the real adapter, with the same
`N-HANDLER.ATR` test at 76800 baud as the rest of this document:

| Build | Time | Throughput | Efficiency | Dead time/chunk |
|---|---|---|---|---|
| v1.6.1 (baseline) | 70.24s | 1313.9 B/s | 17.1% | 75.8ms |
| v1.6.2-dev (unrelated PR, control) | 72.54s | 1272.4 B/s | 16.6% | 79.0ms |
| **rs232-core-pin** | **51.29s** | **1799.5 B/s** | **23.4%** | **49.5ms** |

This is a real, large win. Per-chunk dead time dropped about 35%. This confirms the WiFi and
scheduler-contention mechanism from the previous addendum. It was not just possible. It was
real, and fixable, with the same mechanism ADAM already used.

**A second, more detailed firmware fix.** On the S3 target, `ESP32UARTChannel.cpp`'s
`updateFIFO()` called `xQueueReceive(_uart_q, &event, 1)`. The `1` here is a FreeRTOS
*tick*, not about 1ms as the number suggests. This project's `CONFIG_FREERTOS_HZ=100` makes
one tick 10ms. This tick-versus-ms mixup dates back over a year in `fujinet-firmware`'s
history. Any time the UART's local FIFO drained empty mid-exchange, the next single-byte
read could silently block for up to 10ms. The team fixed this to a non-blocking `0`-tick
wait.

The measured effect was real, but noisier than hoped. The baseline, core-pin only, 3 trials,
was 58.30, 58.80, and 58.18 seconds. With the fix: 58.95, 53.01, and 51.92 seconds. This is a
win of about 9 to 11% on two of three trials, and no change on the third. That baseline is
itself much slower than the 51.29 seconds recorded when core-pinning was first measured, a
few sessions earlier. Real network and Pi-side conditions vary from session to session. This
is a reminder: always re-measure a baseline in the same session, rather than trust an old
number.

**Client-side fixes, independent of the firmware.** A review of `FUJIGET.ASM`'s own read
loop found two real inefficiencies. Both fixes went into `FUJIGET.ASM` and `WGET.ASM`
identically, and shipped as `fujinet-cpm22` v1.5.

First: the code called `STATUS` before every `READ`, even when the previous `STATUS` had
already said more bytes were waiting. The fix cut this from 721 calls to 3. Second: every
`READ` was capped at 128 bytes, even though FujiNet's protocol supports up to 525 bytes. The
fix raised `MAXREAD` to 512, so each network round trip now carries four CP/M records
instead of one. This cut `READ` calls from 721 to about 181.

A lesson repeats here, and in the firmware fixes above: every fix traced its mechanism
correctly. But cutting the round-trip count always over-predicted the time saved. 99.6%
fewer `STATUS` calls bought about 7% less time. About 75% fewer `READ`s bought about 4.7%
less time. Something other than round-trip *count* was always the larger cost. The closing
addendum below finally identifies that cost directly.

**A large correction to this whole document's "Emulator" numbers.** The team chased the
emulator side's own remaining dead time, with the client fixes applied. At 76800 baud, about
93% of that dead time came from `altairsim`'s own paced-clock `sleep_for()`. This is the
mechanism that keeps the guest CPU in step with real 2MHz time. This mechanism stalls far
longer than the pacing math calls for, whenever the guest waits on an external socket reply
instead of doing CPU-bound work.

A packet capture confirmed this: the OS delivered every response in 13 microseconds, but the
guest then sat in silence for about 127ms before its next byte. A `clock_hz=0` free-running
A/B test also confirmed it: the mean round-trip gap collapsed from 179.7ms to 8.74ms.

**Every "Emulator" absolute throughput and dead-time figure earlier in this document was, to
a large degree, measuring this artifact, not FujiNet software's real ceiling.** The
structural and relative findings are unaffected: the adapter-versus-2SIO grouping, and the
CPU-clock-rate measurement. They do not depend on the emulator's absolute numbers being
clean. But read the raw bytes-per-second and dead-time-per-chunk figures for the emulator,
throughout this document, with that caveat. This is an `altairsim`-side finding, not a
FujiNet one. It has not been raised with that project separately.

**Net real-hardware result of everything in this addendum:** about 46.5 seconds for the 92KB
test file at 76800 baud, down from the original 70.24-second baseline. This is 17.1% up to
about 25.9% of the 7680 B/s wire ceiling. It is real, compounding progress from three
independent fixes. But a rough wire-time floor, about 12.5 seconds, plus TNFS and network
cost, still left about **34 seconds unaccounted for**. This averages about 185ms per round
trip. That gap, and what is actually in it, is the subject of the closing addendum below.

## Closing the investigation: instrumenting the adapter itself, and why buffering does not help (2026-09-09)

Every fix up to this point came from reasoning from the outside: measuring total transfer
time, and inferring where the time went.

This session instead added timers directly to the adapter's own firmware, with `esp_timer`
and `fnSystem.micros()`. This used a throwaway `rs232-timing-diag` branch, off
`rs232-core-pin`, never merged or shipped. The timers measured four stages of every
`NET_READ` and `NET_STATUS` round trip, separately. Each round trip logged one `RTIMING`
line, over the adapter's own USB debug console:

- **`cmd`**: reading and framing the incoming command packet off the wire.
- **`fetch`**: time inside `protocol->read()` and `status()`, the actual TNFS round trip to
  the Pi.
- **`reply`**: writing the reply packet back out to the wire.
- **`gap`**: idle time since the *previous* reply finished. This is how long the adapter
  waited for the 8800c to send its next command.

### The breakdown

Test: a 92,288-byte file, at 76800 baud, on real hardware, with plain `FUJIGET` (v1.6).
**Result: 41.95 seconds total, 721 records, 186 round trips captured.**

| Stage | Sum | Mean | Median | What it means |
|---|---|---|---|---|
| **gap** | 23.95s (57%) | 128.8ms | 60.5ms | idle, waiting on the 8800c |
| **reply** | 11.06s (26%) | 59.5ms | 61.3ms | wire time — physics, not overhead |
| **fetch** | 1.28s (3%) | 6.9ms | 6.3ms | the real TNFS round trip |
| **cmd** | 0.07s (<1%) | 0.4ms | 0.4ms | framing — negligible |

Three things this settles on their own:

- **`fetch` closes the last open caveat from the addendum above:** "WiFi-specific latency
  from the ESP32's actual radio is still completely unmeasured." Now it is measured live, on
  the real radio, during a real transfer: a median of 6.9ms. TNFS and WiFi were never the
  bottleneck.
- **`reply` is just wire physics.** About 61ms for a SLIP frame of about 522 bytes, at 76800
  baud, is exactly where the baud-rate math puts it. It cannot be fixed without smaller
  frames or a higher baud.
- **`gap` is the dominant cost, and it is not the adapter.** `cmd`, the adapter noticing and
  framing a new command, is near-instant once bytes exist on the wire. So `gap` is dead time
  on the *8800c's* side: CPU, BDOS, and disk-write latency. It is not FujiBus. It is not
  WiFi. It is not the 2SIO board. This reverses the leading suspect from every earlier
  addendum in this document. The ESP32 firmware fixes were real and worth shipping. But they
  were never the dominant cost for this hardware combination. The 8800c's own disk write was
  the dominant cost.

### Isolating the disk write: `FGNODISK`

The team built a throwaway fork of `FUJIGET.ASM`, called `FGNODISK`, never installed
alongside the real tools. It had one change: `RFLUSH`'s `BDOS FWRITE` call was removed
entirely, replaced with just the bookkeeping. Bytes are still copied out of the network
buffer. They are just never written to disk. The team used the same file, the same baud, and
the same instrumented firmware:

| | With disk writes (`FUJIGET`) | Without (`FGNODISK`) | Δ |
|---|---|---|---|
| **Total time** | 41.95s | 23.25s | **−18.7s (−44.6%)** |
| `gap` sum | 23.95s | 6.73s | −17.22s |
| `reply`/`fetch`/`cmd` | 11.06s / 1.28s / 0.07s | 11.06s / 1.30s / 0.07s | unchanged (confirms a clean isolation) |

`BDOS FWRITE` alone accounts for 44.6% of total transfer time, and about 72% of the
previously-unexplained `gap`. This is the real hardware bottleneck for this project. It is
not the FujiNet adapter.

**Why disk writes cost this much on real hardware, but nothing on the emulator:** the
physical 8800c's disk is an FDC+ card. Per its original designer's own account, Mike
Douglas of DeRamp, this card presents CP/M with a fake drive geometry, about 2048 tracks, to
fit 8MB into a model CP/M's BDOS that never actually shipped this hardware.

The FDC+ card itself talks to a *separate* disk emulator, originally a dedicated PC, now an
ESP32-based emulator from deltecent. This link runs at its own dedicated 403.2kbaud serial
rate, confirmed live on this exact setup. A full command-and-acknowledge round trip, for one
128-byte sector write over that link, takes about 3.2ms of raw data time alone at
403.2kbaud, plus protocol overhead. This lines up well with the about-23ms-per-call this
session measured, 17.2 seconds divided by 744 real `FWRITE` calls. `altairsim`'s own virtual
disk board has no such link, and no seek or rotation timing at all. This is exactly why none
of this showed up in any emulator-side measurement anywhere else in this document.

### Would buffering the writes help? `FGBUFFER` says no.

CP/M 2.2's `BDOS FWRITE` writes exactly one 128-byte record per call. There is no bulk-write
function. So buffering the incoming data can only change *when* those calls happen. It can
never change how many calls there are.

The team built `FGBUFFER`, another throwaway `FUJIGET` fork, never installed, to test this
properly instead of guessing. `FGBUFFER` sizes a write buffer dynamically at startup, from
free TPA memory. The word at `0006H` is BDOS's own base address, a standard CP/M convention,
not a hardcoded constant. The buffer accumulates records across many `READ`s. It only
burst-flushes, still one `FWRITE` per record, but back-to-back with no network I/O between
them, when the buffer would overflow on the next `READ`, or at true end of file. A file
smaller than the buffer gets exactly one flush, at the very end. This is the classic CP/M
`PIP`-style buffered-copy shape, for disks bigger than RAM, often with only one drive.

Development caught a real correctness bug, before this ever went near real hardware. The
room check that triggers a flush can fire *mid-record*, since a `READ`'s payload does not
have to end on a 128-byte boundary. The first version silently discarded up to 127 bytes of
in-flight partial-record data, on every such flush. A byte-exact `SHA-256` diff, against
`FUJIGET`'s own output on the emulator, caught this before deployment. The team tested both a
tiny single-flush file and the full 92KB, 3-flush file. The fix carries the partial bytes
forward across the flush. The team then re-verified the output was byte-identical.

**Real-hardware result, same file and baud: 41.27 seconds, 721 records, 3 buffer flushes.
This is 1.6% faster than plain `FUJIGET`.** This is almost no improvement. The `RTIMING`
breakdown shows why: about 182 ordinary round trips, each with a `gap` of about 37 to 39ms.
This almost exactly matches `FGNODISK`'s no-write baseline. Plus exactly **3 huge
outliers**: 1.3, 8.6, and 8.8 seconds. These match the 3 reported flushes, and sum to about
18.7 seconds. This is the *same total* disk-write cost that `FGNODISK` eliminated. It is
just concentrated into 3 multi-second pauses, instead of spread across 181 small ones.

**Conclusion: the per-`FWRITE` cost is flat. It is not an idle or reselect penalty that
batching can spread out.** Total write time stays the same, no matter how it is spread out
in time. This fits with each `FWRITE` paying its own independent round trip, over the FDC+'s
403.2kbaud link to its disk emulator, regardless of what happened just before it. Buffering
also makes the transfer visibly freeze for several seconds at a time, instead of moving
steadily. This is a real problem for the user, for zero benefit in total time.

### Where this leaves the project

This is the practical throughput floor, for this specific hardware combination: the 8800c,
the FDC+ card, and a real FujiNet RS232 adapter. Two things could change this floor. First,
cutting the *number* of `FWRITE` calls needed, which is not possible under stock CP/M 2.2's
one-record-per-call BDOS API. Second, fixing the FDC+-to-disk-emulator link itself, which is
third-party hardware and firmware, outside this project's reach.

The ESP32 adapter fixes earlier in this document, core-pinning and the UART tick fix, were
real, measured, and worth keeping. But the dominant real-hardware cost was never the
adapter. The project has not pursued this further.

---

## What changed

This is a full Simplified-Technical-English-style rewrite, not a light pass. Every fact,
number, table, code sample, file name, branch name, PR number, and quoted string from the
original is preserved exactly. Nothing was added.

**Rule 2 (sentence limits) — the biggest violation, by far.** The original is written in a
dense, essay-like style with many 40-70 word sentences carrying two or three ideas each
(e.g. the opening paragraph, the "Reading the table" section, most of the addenda). Nearly
every sentence in the rewrite is under 20 words; each original long sentence was split into
several short ones, one idea per sentence.

**Rule 10 (em dashes) — the second-biggest violation.** The original uses the em dash
constantly, as a substitute for commas, colons, periods, and parentheses alike. Every one was
removed and replaced with a period, comma, or colon, depending on what it was doing in that
sentence. (Two em dashes remain, inside the "What it means" column of the RTIMING breakdown
table — `wire time — physics, not overhead` and `framing — negligible` — left alone because
that column is short, tightly-packed data-table text, not prose, and splitting it into full
sentences would have made the table harder to scan, not easier.)

**Rule 4 (active voice) / hedge language.** A few constructions like "was reasoned about"
and "is inflated by" were rewritten with a clear subject doing the action ("the team
reasoned", "the larger number is inflated by X" kept where X *is* the true agent).

**Rule 9 (word substitution) and the slop blocklist.** A handful of words were swapped for
their plain equivalents or cut outright as filler: *literally* (cut, e.g. "this is literally
why" → "this is the reason"), *essentially* → *almost*, *notably* → *much*, *substantially* →
*a great deal*, *significant* → *large*, *genuine* → *real*, *attempt* (noun) →
*it tried to open the file*, and the idiom *apples-to-apples* → *a clean, direct comparison*.
Contractions (*doesn't*, *isn't*, *can't*, *it's*) were expanded throughout, except inside
one direct quote from the firmware's own source comments, which is left byte-for-byte exact
per the skill's rule against simplifying quoted text.

**Formatting fix, not an STE rule.** Two headings in the original were split across two `##`
lines by what looks like a line-wrap artifact from how the document was generated
(`## Addendum: firmware flashing now works on this Mac, and a live test build was flashed and` /
`## measured (2026-09-03)`, and similarly for the closing-investigation heading). Both were
merged back into single heading lines. No wording or fact changed.

**Left alone.** Every table, every code/command snippet, every hex address, branch name, PR
link, and the one direct quote from `fujinet-firmware`'s source comments are reproduced
exactly as in the original — per the skill's rule that exact strings are not simplified.
Established short technical compounds (`FujiBus command processing`, `FDC+ card's serial
link`, `RS232 core-pinning`) were kept as-is: each is three nouns or fewer, so none trips the
noun-cluster rule, and breaking up a project's own established term would have made it
*less* recognizable, not clearer.
