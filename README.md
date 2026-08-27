# FujiNet for CP/M on altairsim

Three small CP/M utilities that give a CP/M machine running under
[`altairsim`](https://github.com/deltecent/altairsim) access to FujiNet's `N:` network device —
file transfer and directory listing over TCP, HTTP, TNFS, and anything else FujiNet's network
protocol layer understands. Modeled on Mike Douglas's classic
[`PCGET`/`PCPUT`](https://deramp.com/downloads/altair/software/utilities/PCGET%20and%20PCPUT/)
(Xmodem-based CP/M↔PC transfer tools for the Altair 88-2SIO), with FujiNet's own
request/response protocol standing in for Xmodem.

(`altairsim` also ships its own `R.COM`/`W.COM` file-transfer tools, but those talk to a
"Host Bridge" virtual card that's unique to the emulator — there's no equivalent on real
hardware. PCGET/PCPUT's serial-line approach is the one that generalizes to any CP/M machine,
real or emulated, which is why FUJIGET/FUJIPUT follow that lineage instead.)

```
FUJIGET N:<url> file.ext        pull a file down, e.g. FUJIGET N1:TNFS://192.168.1.5/HELLO.TXT HELLO.TXT
FUJIPUT file.ext N:<url> [B|T]  push a file up,    e.g. FUJIPUT HELLO.TXT N1:TNFS://192.168.1.5/HELLO.TXT T
FUJIDIR N:<url>                 list a directory,  e.g. FUJIDIR N1:TNFS://192.168.1.5/
```

Also included: `NC.COM`, a raw netcat-style tool (`NC <host> <port>`) that opens a TCP
connection through FujiNet's `N:` device directly — the first of these four tools built, and
useful on its own for testing a link or talking to a plain TCP service.

Each tool is versioned independently (they change on their own schedule, not together) and
prints its own version when run with no arguments. Current versions: `NC` v1.0, `FUJIGET`
v1.0, `FUJIPUT` v1.0, `FUJIDIR` v1.0.

This folder has all four programs ready to run (`.COM`), their assembly source (`.ASM`), and
the assembler listings (`.PRN`). No cross-assembler is used anywhere in this project — these
were built by CP/M's own `ASM.COM`/`LOAD.COM`, running inside the emulated machine.

## What's tested so far

Everything here has been built and verified against the **emulated** `fujinet-pc-RS232`
build, talking to a local `tnfsd` test server, on **macOS**. A real physical FujiNet RS232
adapter is expected shortly; this document doesn't cover real hardware yet, and **Windows/
Linux instructions for the host side (FujiNet-PC) are not written yet either** — this project
has only been run on macOS so far. Both are open follow-ups.

---

## 1. Get and install FujiNet-PC (the RS232 build)

FujiNet-PC is FujiNet's own project — a desktop program that emulates the real FujiNet
hardware so you can develop and test against it without an ESP32 on your bench. It comes in
several flavors for different host machines (ADAM, Atari, Apple, CoCo, ...); the one this
project needs is the **RS232** flavor, since the Altair talks to it over a serial line (the
88-2SIO), not a machine-specific bus.

**Download**: <https://github.com/FujiNetWIFI/fujinet-firmware/releases> — look for a release
with an asset named `fujinet-pc-RS232_<version>_<platform>.<ext>` (or, on older/nightly tags,
just `fujinet-RS232-<build>.zip`). Pick the asset matching your OS and CPU
(`macos-14-arm64`/`macos-15-arm64` for Apple Silicon, `macos-15-x64` for Intel Macs,
`ubuntu-22.04-amd64`/`ubuntu-24.04-amd64` for Linux, `windows-x64` for Windows). This project
was built and tested against a nightly build reporting itself as `FujiNet v1.6-947873d94
(RS232)` — if something doesn't match this guide, that version is the reference point.

**Install** (macOS):

```
tar xzf fujinet-pc-RS232_*.tar.gz -C fujinet-rs232/     # or wherever you want it to live
cd fujinet-rs232
xattr -d com.apple.quarantine ./fujinet                 # macOS will otherwise refuse to run it
chmod +x ./fujinet
```

Keep the extracted `fujinet` binary together with the `fnconfig.ini`, `data/`, and `SD/` that
come with the archive (or get created on first run) — the program uses paths relative to its
own working directory, not absolute ones. Run it *from* that directory, always.

**Configure it for BOIP** (Bus-over-IP — a raw TCP byte pipe standing in for the physical
serial cable): open `fnconfig.ini` and make sure

```ini
[Serial]
port=
```

is **empty**. A blank `[Serial] port` is what tells FujiNet-PC to listen for a BOIP TCP
connection instead of trying to open a real serial device. `[BOIP]`'s `host=localhost` and
blank `port=` (defaults to `1985`) are fine as shipped.

**Run it**:

```
./fujinet -u 127.0.0.1:8005
```

`-u` is the address for FujiNet's own web config UI (host slots, WiFi, etc. — mostly
irrelevant here, but useful for poking at config). Watch its console output for:

```
Setting up BoIPChannel: listening on localhost:1985
### BoIPChannel accepting connections ###
```

That's your signal it's ready. Leave it running in its own terminal/process for the whole
`altairsim` session.

---

## 2. Point altairsim at it

`altairsim`'s serial boards can connect a unit to a raw TCP socket directly from your
machine's `.toml` file — no code, no wrapper script. Your machine needs a 2SIO card (the
usual console board) with a **second unit free** — unit `a` is normally the console, so this
uses unit `b`. Add (or edit) this in your machine's `.toml`:

```toml
[[board]]
type = "2sio"
id   = "sio0"
port = 10

  [board.unit.a]
  connect = "console"
  baud    = 9600

  [board.unit.b]
  connect = "socket:localhost:1985"   # FujiNet-PC-RS232's BOIP port
  baud    = 9600
```

(`port = 10` is the 2SIO's usual base address — if yours is elsewhere, or you have more than
one 2SIO, adjust `id`/`port` and the board id you reference below accordingly. Whatever board
id you give this card is also the id the four programs need to know about — see "Adapting to
different hardware" below.)

That's the whole integration on the `altairsim` side: boot the machine normally with
FujiNet-PC already running, and `sio0:b` is live the moment CP/M starts. If you need to point
at a different host/port (FujiNet-PC running elsewhere, or on a non-default BOIP port), change
the `connect` string — `socket:HOST:PORT` is the general form — or issue `CONNECT sio0:b
socket:HOST:PORT` at the `altairsim>` prompt to rewire it live without editing the file.

---

## 3. Get the tools onto your CP/M disk

This folder includes each program three ways — `.COM` (ready to run), `.HEX` (Intel hex,
what `ASM`/`LOAD` produce and consume), and `.ASM` (source) — so you can get them onto a disk
by whatever transfer method your setup already has. If you have *any* existing way to get a
file from your host machine onto the CP/M disk (a shared/mounted disk image, a custom bridge
of your own, `altairsim`'s own file-loading tools if it has any, etc.), just use it to copy the
`.COM` files across and skip to "Using the tools" below.

**If you have nothing else, here's the classic, universal CP/M way** — it needs nothing but a
terminal connection to the console and CP/M's own `PIP`, `ASM`, and `LOAD`, which are on every
CP/M 2.2 system:

1. Connect a terminal program to `altairsim`'s console with a **paced/delayed** ASCII send —
   most terminal emulators call this something like "line delay" or "msec/char" under their
   file-transfer or serial settings. A `.HEX` file is plain ASCII text but CP/M's console input
   isn't buffered deeply, so sending it flat out will drop characters; ~10ms/char is a safe
   starting point.
2. At the CP/M prompt: `A>PIP FUJIGET.HEX=CON:[H]` (the `[H]` strips the high bit some
   terminals set), then send `FUJIGET.HEX` as plain ASCII text. When it's done, type Ctrl-Z to
   signal end-of-file; PIP returns to the prompt.
3. `A>LOAD FUJIGET` — this reads `FUJIGET.HEX` and writes `FUJIGET.COM`, ready to run.
4. Repeat for `FUJIPUT.HEX`, `FUJIDIR.HEX`, and `NC.HEX` (or skip whichever you don't need).

**To rebuild from source** instead of using the provided `.HEX`/`.COM`: get the `.ASM` onto the
disk the same paced-paste way (`PIP FUJIGET.ASM=CON:[H]`), then `ASM FUJIGET` (produces a fresh
`.HEX`) followed by `LOAD FUJIGET`. **One thing that will bite you** if you edit the source on
a modern machine first: most host-side text editors write LF-only line endings; CP/M text
wants CRLF. A paste straight from an LF-only file tends to run every line together on one
logical line by the time it reaches `ASM.COM`, and `ASM` will either choke on it outright or
(worse) silently assemble almost nothing — check the `.HEX` it produces isn't suspiciously
tiny, and that `LOAD` reports a sane `FIRST ADDRESS`/`LAST ADDRESS`, not `0000`/`0000`. Convert
line endings to CRLF on the host before transferring a modified `.ASM` (e.g. `sed -i ''
's/$/\r/' FILE.ASM` on macOS/Linux).

---

## 4. Using the tools

### FUJIGET — pull a file down

```
FUJIGET N:<url> file.ext
```

Opens `<url>` for read on FujiNet's `N:` device and writes the bytes into a new CP/M file
`file.ext`, creating or overwriting it. The URL is typed exactly as FujiNet expects it,
including the `Nx:` channel prefix — e.g. `N1:TNFS://192.168.1.5/HELLO.TXT`,
`N1:TCP://192.168.1.5:9000/`, `N1:HTTP://example.com/file.txt`. The network side is confirmed
open (and readable) *before* anything on the CP/M side is touched — a failed open never
deletes an existing local file of the same name.

If `file.ext` already exists locally, FUJIGET asks `HELLO.TXT exists. Replace? (Y/N)` before
touching the network side at all — decline and nothing happens, on either side.

### FUJIPUT — push a file up

```
FUJIPUT file.ext N:<url> [B|T]
```

The mirror image: opens `file.ext` on the CP/M side first (again, so a bad remote target
can't clobber anything), then streams it up to `<url>`.

Before ever opening `<url>` for write, FUJIPUT probes it read-only first to check whether it's
already there. Clobbering a CP/M file is a bad day for one person; clobbering a file on a
remote server is a bad day for everyone else who uses it, so if the probe finds something,
FUJIPUT asks `<url> exists on the remote. Replace? (Y/N)` before opening for write at all. This
only means something for a target where "exists" is meaningful (TNFS, SD, HTTP) — a raw
`TCP://` stream has no file to find, so the probe just comes back "not there" and nothing is
asked.

CP/M stores files as whole 128-byte records with no exact byte count, so the last record of a
short file is padded with `^Z` (`1AH`). The optional third argument controls what happens to
that padding on the way out:

- **`B`** (the default) — send every byte of every record, exactly. A `.COM` file survives the
  trip byte-for-byte; a text file arrives with up to 127 trailing `^Z` bytes tacked on.
- **`T`** — stop at the first `^Z`. Cleans up a text file perfectly, but **truncates** any
  binary file that happens to contain a real `1AH` byte partway through — which is why it
  isn't the default.

### FUJIDIR — list a directory

```
FUJIDIR N:<url>
```

Opens `<url>` in FujiNet's directory-listing mode and prints what comes back: one name per
line, subdirectories marked with a trailing `/`. Works for any URL scheme FujiNet's `N:`
device treats as a filesystem (TNFS, SMB, etc.) — e.g. `FUJIDIR N1:TNFS://192.168.1.5/` lists
the TNFS server's root, `FUJIDIR N1:TNFS://192.168.1.5/SUBDIR/` lists inside a subdirectory.

### A worked example, start to finish

```
A0>FUJIDIR N1:TNFS://192.168.1.5/
FUJIDIR: listing N1:TNFS://192.168.1.5/
HELLO.TXT

A0>FUJIGET N1:TNFS://192.168.1.5/HELLO.TXT HELLO.TXT
FUJIGET: opening N1:TNFS://192.168.1.5/HELLO.TXT
Open OK. Receiving...

1 records received.

A0>FUJIPUT HELLO.TXT N1:TNFS://192.168.1.5/COPY.TXT T
FUJIPUT: opening N1:TNFS://192.168.1.5/COPY.TXT
Open OK. Sending...

1 records sent.
```

---

## 5. Adapting to different hardware

All four of these programs talk **directly to I/O ports**, with no BDOS or BIOS
indirection in between. That's deliberate, not an oversight: CP/M's BDOS console calls are
wired to the one `CON:` device only, so there's no BDOS console call that reaches a *second*
serial line. (There *is* a CP/M-standard indirection mechanism that can, on some systems —
`IOBYTE`, routed through BDOS functions 3/4 — and it was confirmed, by disassembling the BIOS
this project develops against, to genuinely reach the second 2SIO unit on *that* BIOS via `STAT
RDR:=UR2:`/`PUN:=UP2:`. See `docs/iobyte-rdr-pun.md` in this folder for the full finding and
why it wasn't adopted here — it's a property of that one BIOS, not something to assume for
yours, so these programs still use direct port I/O by default.)

That means **the source is the config file**. If your hardware doesn't match this project's
assumptions, you edit the `.ASM`, reassemble (`ASM FUJIGET` / `LOAD FUJIGET`, etc.), and you're
done — there's no separate settings file, because CP/M's `ASM.COM` has no `INCLUDE` directive.
Each `.ASM` carries its own copy of the two things below; if you change one, **change it in
all four files** and rebuild each one.

### 1. The port addresses

Near the top of each `.ASM`, right after the CP/M equates:

```asm
;---- The 2SIO card, unit b ---------------------------------------------
SIOST   EQU     12H             ; status (IN) / control (OUT)
SIODT   EQU     13H             ; data, both ways
SIORST  EQU     03H
SIOCTL  EQU     15H
```

`SIOST`/`SIODT` are this project's default: the second unit of an 88-2SIO card at base port
`10H` (unit `a` = `10H`/`11H`, the console; unit `b` = `12H`/`13H`, wired to FujiNet). If
FujiNet is on a different card, a different unit, or a different base address on your
hardware, **this is the only thing that needs to change** to point these tools at it — nothing
else in the file cares what the actual numbers are, they're used everywhere else only by name.

### 2. The UART initialization

A few lines into each program's `START:`, before it does anything else with the port:

```asm
        MVI     A,SIORST        ; the ACIA out of reset...
        OUT     SIOST
        MVI     A,SIOCTL        ; ...and into a real operating mode
        OUT     SIOST
```

This is specific to the **6850 ACIA** the 88-2SIO uses, where — unlike boards such as the
88-SIO or 88-ACR, whose word format is set by jumpers — baud-rate division, word format
(data/parity/stop bits), and RTS/interrupt behavior are **registers the guest program writes**,
not something fixed in hardware. `03H` is the 6850's master-reset code; `15H` (`00010101`)
selects ÷16 clocking with 8N1 framing and both interrupts left off — matched to the example
`sio0` unit b in section 2 above, running at 9600 baud with no interrupts.

If your hardware's serial interface **sets its format with jumpers or switches instead** (or
uses some other chip entirely — an 8251 USART, a bit-banged port, whatever), **delete these
four lines outright**: there's nothing for the guest to configure, and writing an ACIA-style
control byte to a port that isn't a 6850 could do something you don't want. If it's a 6850 but
at a different baud rate or word format, change `15H` to whatever control byte your setup
needs — the two bits at the bottom select the clock divide, the next three select word format,
and the top three control RTS and the two interrupt-enable bits; any 6850 datasheet has the
full table.

---

## 6. Testing without a real network host

You don't need a real TNFS/HTTP server on your network to try any of this — a local `tnfsd`
test server works fine, and is what these tools were actually verified against:

1. Download the official `tnfsd` binary for your platform from
   <https://github.com/FujiNetWIFI/tnfsd/releases> (it's a small, standalone server from the
   FujiNet project itself — a few tens of KB, no install needed).
2. Make a directory to serve, e.g. `mkdir share` and drop a test file or two in it.
3. Run it: `./tnfsd share` (add `-r` for read-only, `-p PORT` for a non-default port — it
   listens on UDP/TCP `16384` by default). On macOS you'll likely need
   `xattr -d com.apple.quarantine ./tnfsd` first, same as FujiNet-PC above.
4. Point your `N:` URLs at it, e.g. `FUJIDIR N1:TNFS://127.0.0.1/`.

That's it — FujiNet-PC talks to `tnfsd` the same way it'd talk to any real TNFS server, so
everything above works identically against `127.0.0.1` as it would against a real remote host.

---

## Known limitations

- **The upstream `fnTcpClient` idle-disconnect bug** (confirmed in `fujinet-firmware`'s
  source: a non-blocking `recv(MSG_PEEK)` returning 0 is misread as "connection closed," which
  can happen to a perfectly healthy but momentarily quiet TCP connection). This affects raw
  `TCP:` connections (like this project's earlier `NC.COM` netcat tool); it hasn't been
  observed against `FUJIGET`/`FUJIPUT`/`FUJIDIR`'s TNFS-based testing, which is UDP-based and
  unaffected. Worth knowing about if you point these tools at a raw `TCP:` URL and see
  unexpected disconnects on an idle link.
- **Disk mounting** (`FUJICMD_MOUNT_HOST`/`MOUNT_IMAGE`, i.e. making a remote disk image appear
  as a real CP/M drive letter) is not implemented and not planned for now — it would need a
  new CP/M BIOS driver speaking a completely separate, Atari-SIO-flavored sector protocol
  (`DISKCMD_*`), a much bigger undertaking than these three utilities, and untested at the
  protocol level besides. The simple workaround already available: `FUJIGET` a `.DSK` image
  down to the host machine and point `altairsim`'s own disk board at it directly.
- **Windows and Linux instructions for FujiNet-PC** are not written yet (see the top of this
  document) — this project has only run on macOS so far.
- **Real hardware** (a physical FujiNet RS232 adapter) hasn't been tested yet either — only
  the emulated `fujinet-pc-RS232`.

## Where the protocol details live

This README is about *using* the tools; the wire protocol they implement (SLIP framing,
packet layout, command bytes) is documented in `docs/rs232-protocol.md` in this folder,
reverse-engineered from `fujinet-firmware`'s source and verified live against a running
`fujinet-pc-RS232`. `docs/iobyte-rdr-pun.md` (referenced above) has the `IOBYTE`/BIOS research.
