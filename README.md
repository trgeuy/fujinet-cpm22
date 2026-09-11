# FujiNet for CP/M on altairsim

Three small CP/M utilities give a CP/M machine access to FujiNet's `N:` network device. The
machine must run under [`altairsim`](https://github.com/deltecent/altairsim). The tools
transfer files and list directories over TCP, HTTP, TNFS, and any other protocol that
FujiNet's network layer understands.

The tools are modeled on Mike Douglas's classic
[`PCGET`/`PCPUT`](https://deramp.com/downloads/altair/software/utilities/PCGET%20and%20PCPUT/).
Those are Xmodem-based CP/M-to-PC transfer tools for the Altair 88-2SIO. FujiNet's own
request/response protocol replaces Xmodem here.

(`altairsim` also ships its own `R.COM`/`W.COM` file-transfer tools. But those talk to a
"Host Bridge" virtual card that is unique to the emulator. Real hardware has no equivalent.
PCGET/PCPUT's serial-line approach generalizes to any CP/M machine, real or emulated. That is
why FUJIGET/FUJIPUT follow that lineage instead.)

```
FUJIGET N:<url> file.ext        pull a file down, e.g. FUJIGET N1:TNFS://192.168.1.5/HELLO.TXT HELLO.TXT
FUJIPUT file.ext N:<url> [B|T]  push a file up,    e.g. FUJIPUT HELLO.TXT N1:TNFS://192.168.1.5/HELLO.TXT T
FUJIDIR N:<url>                 list a directory,  e.g. FUJIDIR N1:TNFS://192.168.1.5/
```

Each tool has its own version number. Each tool changes on its own schedule, not together.
Each tool prints its own version when you run it with no arguments. Current versions:
`FUJIGET` v1.6, `FUJIPUT` v1.4, `FUJIDIR` v1.5.

FujiNet's protocol supports a delete/remove counterpart (`RMDIR`, file `DELETE`). This
project deliberately does not include one. See "Known limitations" below.

This folder has all three programs ready to run (`.COM`) and their assembly source (`.ASM`).
This project uses no cross-assembler anywhere. CP/M's own `ASM.COM`/`LOAD.COM` built these
tools, running inside the emulated machine.

This repo also has `NC.COM` in `testing/`. `NC.COM` is a raw netcat-style tool
(`NC <host> <port>`). It opens a TCP connection through FujiNet's `N:` device directly. It was
the first of these tools built. It is also useful on its own for testing a link or talking to
a plain TCP service. It is a diagnostic aid, not part of the packaged release. Download
`testing/NC.COM`/`.HEX`/`.ASM` separately from this repo if you need it.

Likewise, `altairsim/` has a ready-to-run `8800c.toml`, two disk images, and a `run-fujinet`
launcher script (see sections 1 and 2 below). It is only useful if you are actually setting up
`altairsim` itself. So it is not in the packaged release either. Get it from
<https://github.com/trgeuy/fujinet-cpm22/tree/main/altairsim> if you want it.

`tnfsd-server-setup/` gets the same treatment. It points you at
[de-tnfsd](https://github.com/trgeuy/de-tnfsd), our fork of a TNFS daemon built around a
classic anonymous-FTP layout (read-only `pub/`, write-only `incoming/`), and covers what is
specific to CP/M on top of that: the CCP-uppercases-everything gotcha and a verification
checklist using this repo's own tools. It is only useful if you are running a server, not a
client. So it is repo-only too. See
<https://github.com/trgeuy/fujinet-cpm22/tree/main/tnfsd-server-setup>.

`fujinet-rs232/` covers bringing up a **physical** FujiNet RS-232 adapter for CP/M. WiFi and
serial-baud setup happen entirely through the adapter's own `fnconfig.ini` and web UI, since
CP/M has no `CONFIG.SYS`/`CONFIG.EXE` equivalent. It is repo-only, for the same reason as the
other two. See <https://github.com/trgeuy/fujinet-cpm22/tree/main/fujinet-rs232>.

`wget/` is a fourth tool, `WGET`. It prompts for its URL at runtime instead of taking it on the
command line. CP/M's CCP uppercases the whole command tail before any program sees it. This
silently breaks a `FUJIGET`/`FUJIPUT`/`FUJIDIR` URL against a case-sensitive remote like a real
HTTP/HTTPS server. It is repo-only, for the same reason as the other three. See
<https://github.com/trgeuy/fujinet-cpm22/tree/main/wget>.

`firmware-uploader-apple-silicon/` is unrelated to CP/M itself. It is useful to anyone bringing
up a real FujiNet adapter from an Apple Silicon Mac. It is a patched drop-in replacement for
upstream `fujinet-firmware`'s firmware-flashing script. It fixes an Apple Silicon compatibility
gap in the stock version. It is an interim fix, not a fork or a pending PR. See
<https://github.com/trgeuy/fujinet-cpm22/tree/main/firmware-uploader-apple-silicon> for why.

## What's tested so far

Everything here has been built and verified against the **emulated** `fujinet-pc-RS232`
build, talking to a local `tnfsd` test server, on **macOS**. All three tools have also been
verified end to end against a real `tnfsd` running on actual Raspberry Pi hardware over a real
LAN. This includes the mixed read-only/write-only permission layout described in
`tnfsd-server-setup/`. **All three tools have also now been verified on a real physical
FujiNet RS232 adapter on a real Altair 8800c.** See `fujinet-rs232/` for bring-up
instructions. **Windows/Linux instructions for the emulator host side (FujiNet-PC) are not
written yet.** This project has only run FujiNet-PC on macOS so far. That is the one
remaining open follow-up.

**Have a physical FujiNet RS232 adapter instead of FujiNet-PC?** Sections 1-2 below are
emulator-specific: installing FujiNet-PC, wiring `altairsim` to its BOIP port. Skip them. Go
to [`fujinet-rs232/`](https://github.com/trgeuy/fujinet-cpm22/tree/main/fujinet-rs232) for the
physical equivalent: WiFi/baud setup through the adapter's own `fnconfig.ini` and web UI. Then
come back to section 3 below. Everything from there on (installing the tools, using them) is
the same whether the other end of the serial line is FujiNet-PC or the real adapter.

---

## 1. Get and install FujiNet-PC (the RS232 build)

FujiNet-PC is FujiNet's own project: a desktop program that emulates the real FujiNet
hardware. It lets you develop and test against FujiNet without an ESP32 on your bench. It
comes in several flavors for different host machines (ADAM, Atari, Apple, CoCo, and others).
This project needs the **RS232** flavor, since the Altair talks to it over a serial line (the
88-2SIO), not a machine-specific bus.

**Download**: <https://github.com/FujiNetWIFI/fujinet-firmware/releases>. Look for a release
with an asset named `fujinet-pc-RS232_<version>_<platform>.<ext>` (or, on older/nightly tags,
just `fujinet-RS232-<build>.zip`). Pick the asset matching your OS and CPU:
`macos-14-arm64`/`macos-15-arm64` for Apple Silicon, `macos-15-x64` for Intel Macs,
`ubuntu-22.04-amd64`/`ubuntu-24.04-amd64` for Linux, `windows-x64` for Windows. This project
was built and tested against a nightly build reporting itself as `FujiNet v1.6-947873d94
(RS232)`. If something does not match this guide, that version is the reference point.

**Install** (macOS):

```
tar xzf fujinet-pc-RS232_*.tar.gz -C fujinet-rs232/     # or wherever you want it to live
cd fujinet-rs232
xattr -d com.apple.quarantine ./fujinet                 # macOS will otherwise refuse to run it
chmod +x ./fujinet
```

Keep the extracted `fujinet` binary together with the `fnconfig.ini`, `data/`, and `SD/` that
come with the archive (or that get created on first run). The program uses paths relative to
its own working directory, not absolute ones. Always run it *from* that directory.

**Configure it for BOIP** (Bus-over-IP: a raw TCP byte pipe standing in for the physical
serial cable). Open `fnconfig.ini` and make sure

```ini
[Serial]
port=
```

is **empty**. A blank `[Serial] port` tells FujiNet-PC to listen for a BOIP TCP connection
instead of trying to open a real serial device. `[BOIP]`'s `host=localhost` and blank `port=`
(defaults to `1985`) are fine as shipped.

**Run it**:

```
./fujinet -u 127.0.0.1:8005
```

`-u` is the address for FujiNet's own web config UI (host slots, WiFi, and so on). This is
mostly irrelevant here, but useful for checking config. Watch its console output for:

```
Setting up BoIPChannel: listening on localhost:1985
### BoIPChannel accepting connections ###
```

That is your signal it is ready. Leave it running in its own terminal or process for the
whole `altairsim` session.

**Convenience launcher**: `altairsim/run-fujinet` in this repo is a small wrapper. Drop it
into your extracted FujiNet-PC directory and run `./run-fujinet -u 127.0.0.1:8005` instead of
calling `./fujinet` directly. It automatically re-launches FujiNet-PC if it exits with code 75
(`EX_TEMPFAIL`, "please retry"), instead of leaving you to notice and restart it by hand. It is
not required. `./fujinet` on its own works fine. But it is one less thing to watch during a
long session.

---

## 2. Point altairsim at it

**Already have a machine you like?** Skip to the `.toml` snippet below and adapt it.
**Starting from scratch?** This repo's `altairsim/` folder has a ready-made `8800c.toml` plus
two disk images: `CPM22-8MB-56K.DSK`, an 8MB CP/M 2.2 system disk, and `BLANK-8MB.DSK`, an
empty second drive. Both are already wired up the way this section describes. Run
`cd altairsim && altairsim 8800c.toml` (with FujiNet-PC already running per section 1) and you
land at the `A>` prompt. The system disk ships with stock CP/M plus `altairsim`'s own Host
Bridge tools (`R`/`W`/`HDIR`) and the `PCGET`/`PCPUT` reference utilities. It deliberately does
**not** ship the `FUJIGET`/`FUJIPUT`/`FUJIDIR` tools themselves, so section 3 below is
something you actually do, not something already done for you.

`altairsim`'s serial boards can connect a unit to a raw TCP socket directly from your
machine's `.toml` file, with no code and no wrapper script. Your machine needs a 2SIO card
(the usual console board) with a **second unit free**. Unit `a` is normally the console, so
this uses unit `b`. Add (or edit) this in your machine's `.toml`:

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

(`port = 10` is the 2SIO's usual base address. If yours is elsewhere, or you have more than
one 2SIO, adjust `id`/`port` and the board id you reference below to match. Whatever board id
you give this card is also the id the four programs need to know about; see "Adapting to
different hardware" below.)

That is the whole integration on the `altairsim` side. Boot the machine normally with
FujiNet-PC already running, and `sio0:b` is live the moment CP/M starts. If you need to point
at a different host/port (FujiNet-PC running elsewhere, or on a non-default BOIP port), change
the `connect` string. `socket:HOST:PORT` is the general form. Or issue
`CONNECT sio0:b socket:HOST:PORT` at the `altairsim>` prompt to rewire it live, without editing
the file.

---

## 3. Get the tools onto your CP/M disk

This folder includes each program three ways: `.COM` (ready to run), `.HEX` (Intel hex, what
`ASM`/`LOAD` produce and consume), and `.ASM` (source). So you can get them onto a disk by
whatever transfer method your setup already has. If you have *any* existing way to get a file
from your host machine onto the CP/M disk (a shared/mounted disk image, a custom bridge of
your own, `altairsim`'s own file-loading tools if it has any, and so on), just use it to copy
the `.COM` files across, then skip to "Using the tools" below.

**If you have nothing else, here is the classic, universal CP/M way.** It needs nothing but a
terminal connection to the console and CP/M's own `PIP`, `ASM`, and `LOAD`, which are on every
CP/M 2.2 system:

1. Connect a terminal program to `altairsim`'s console with a **paced/delayed** ASCII send.
   Most terminal emulators call this something like "line delay" or "msec/char" under their
   file-transfer or serial settings. A `.HEX` file is plain ASCII text, but CP/M's console
   input is not buffered deeply, so sending it flat out will drop characters. About 10ms/char
   is a safe starting point.
2. At the CP/M prompt, type `A>PIP FUJIGET.HEX=CON:[H]` (the `[H]` strips the high bit some
   terminals set), then send `FUJIGET.HEX` as plain ASCII text. When it is done, type Ctrl-Z
   to signal end-of-file. PIP returns to the prompt.
3. Type `A>LOAD FUJIGET`. This reads `FUJIGET.HEX` and writes `FUJIGET.COM`, ready to run.
4. Repeat for `FUJIPUT.HEX` and `FUJIDIR.HEX` (or skip whichever you do not need). If you also
   want the `testing/NC.COM` diagnostic tool, its `.HEX` works the same way.

**To rebuild from source** instead of using the provided `.HEX`/`.COM`: get the `.ASM` onto
the disk the same paced-paste way (`PIP FUJIGET.ASM=CON:[H]`), then run `ASM FUJIGET`
(produces a fresh `.HEX`) followed by `LOAD FUJIGET`. **One thing will bite you** if you edit
the source on a modern machine first: most host-side text editors write LF-only line endings,
but CP/M text wants CRLF. A paste straight from an LF-only file tends to run every line
together on one logical line by the time it reaches `ASM.COM`. `ASM` will either choke on it
outright or, worse, silently assemble almost nothing. Check that the `.HEX` it produces is not
suspiciously tiny, and that `LOAD` reports a sane `FIRST ADDRESS`/`LAST ADDRESS`, not
`0000`/`0000`. Convert line endings to CRLF on the host before transferring a modified `.ASM`
(e.g. `sed -i '' 's/$/\r/' FILE.ASM` on macOS/Linux).

---

## 4. Using the tools

Everything below is the same whether the other end of the serial line is FujiNet-PC or a real
physical FujiNet RS232 adapter. The tools talk to whatever `N:` resolves to over the wire;
they have no idea which one it is. The only real-hardware difference worth knowing about is
throughput: it is lower than the emulator's. Measured on a real Altair 8800c against a real
FujiNet RS232 adapter at 38400 baud, a 92 KB file (`FUJIGET`) took roughly 2.6x longer per
request/response cycle than the same transfer against FujiNet-PC, even to a server on the same
LAN. This is most likely the real ESP32 firmware's own processing time, not a network effect.
Expect real transfers to feel noticeably slower than the numbers you would get testing against
FujiNet-PC locally. That is normal, not a sign something is wrong. See
[`fujinet-rs232/`](https://github.com/trgeuy/fujinet-cpm22/tree/main/fujinet-rs232) for
physical bring-up and other real-hardware notes (pacing, no flow control on classic serial
boards).

### FUJIGET: pull a file down

```
FUJIGET N:<url> file.ext
```

FUJIGET opens `<url>` for read on FujiNet's `N:` device. It writes the bytes into a new CP/M
file `file.ext`, creating or overwriting it. Type the URL exactly as FujiNet expects it,
including the `Nx:` channel prefix, e.g. `N1:TNFS://192.168.1.5/HELLO.TXT`,
`N1:TCP://192.168.1.5:9000/`, `N1:HTTP://example.com/file.txt`. FUJIGET confirms the network
side is open and readable *before* it touches anything on the CP/M side. A failed open never
deletes an existing local file of the same name.

If `file.ext` already exists locally, FUJIGET asks `HELLO.TXT exists. Replace? (Y/N)` before
touching the network side at all. Decline, and nothing happens, on either side.

As of v1.4, FUJIGET prints `Received NNNN KB...` in place (overwriting itself, not scrolling)
once every 1KB received. So a transfer that takes a while shows a visible sign of life
without filling the screen the way a dot per packet would.

If the network open fails, FUJIGET now tells you *which kind* of failure it probably was.
(FujiNet's reply itself carries no error detail, so this is a best-effort diagnosis, not
something the server actually reported; see "Where the protocol details live" below.) It
reports `not found on that remote server` (the URL's parent path exists, but the target does
not; by far the most common cause) or `failed -- parent path does not exist` (not even the
containing directory is there).

For a CP/M version of the Linux `wget` command, one that prompts for the URL instead of
taking it on the command line so its case survives a case-sensitive remote like a real HTTP
server, see [`wget/`](https://github.com/trgeuy/fujinet-cpm22/tree/main/wget).

### FUJIPUT: push a file up

```
FUJIPUT file.ext N:<url> [B|T]
```

FUJIPUT is the mirror image. It opens `file.ext` on the CP/M side first, again so a bad remote
target cannot clobber anything, then streams it up to `<url>`.

Before it ever opens `<url>` for write, FUJIPUT probes it read-only first to check whether it
is already there. Clobbering a CP/M file is a bad day for one person. Clobbering a file on a
remote server is a bad day for everyone else who uses it. So if the probe finds something,
FUJIPUT asks `<url> exists on the remote. Replace? (Y/N)` before it opens for write at all.
This only means something for a target where "exists" is meaningful (TNFS, SD, HTTP). A raw
`TCP://` stream has no file to find, so the probe just comes back "not there" and nothing is
asked.

CP/M stores files as whole 128-byte records with no exact byte count, so the last record of a
short file is padded with `^Z` (`1AH`). The optional third argument controls what happens to
that padding on the way out:

- **`B`** (the default): send every byte of every record, exactly. A `.COM` file survives the
  trip byte-for-byte; a text file arrives with up to 127 trailing `^Z` bytes tacked on.
- **`T`**: stop at the first `^Z`. This cleans up a text file perfectly, but it **truncates**
  any binary file that happens to contain a real `1AH` byte partway through, which is why it
  is not the default.

As of v1.4, FUJIPUT prints `Sent NNNN KB...` in place the same way FUJIGET does (see above),
once every 1KB sent.

If the write-mode open fails (after the overwrite check above has already been answered, or
found nothing to ask about), FUJIPUT diagnoses it the same best-effort way (see "Where the
protocol details live" below). It reports `denied (permission or server restriction)` if the
parent path checks out, since creating or writing was expected to just work, or
`failed -- parent path does not exist` if the parent is not there either.

### FUJIDIR: list a directory

```
FUJIDIR N:<url>
```

FUJIDIR opens `<url>` in FujiNet's directory-listing mode and prints what comes back, one
entry per line. Files get a right-justified size column: plain bytes under 1K, `NNNNK` up to
1MB, `N.NM` above that. Subdirectories are marked with a trailing `/` and no size (FujiNet
always reports one for directories too, but it is a meaningless placeholder, so FUJIDIR drops
it). A bare number and a `K`/`M`-suffixed one look inconsistent side by side with no label. So
running bare `FUJIDIR` with no arguments explains what the column means, as part of its usage
message (v1.5; earlier versions repeated that explanation before every listing, which got old
fast once you knew it). FUJIDIR works for any URL scheme FujiNet's `N:` device treats as a
filesystem (TNFS, SMB, and others), e.g. `FUJIDIR N1:TNFS://192.168.1.5/` lists the TNFS
server's root, `FUJIDIR N1:TNFS://192.168.1.5/SUBDIR/` lists inside a subdirectory. A trailing
slash on the target is optional as of v1.2. FUJIDIR adds one internally before opening if you
leave it off (earlier versions needed it typed explicitly, or risked listing the *parent*
directory's matching entries instead of the subdirectory you meant).

If the open fails, FUJIDIR reports `not found on that remote server` (the parent path exists,
the target does not) or `failed -- parent path does not exist` (same best-effort diagnosis as
FUJIGET, for the same reason; see that section above).

### If FujiNet-PC never answers at all

All three tools now give up after a bounded wait, rather than hanging forever, if nothing
comes back: `<TOOL>: destination server not responding.` This covers FujiNet-PC itself going
unreachable (crashed, or its own connect attempt to a dead remote hanging indefinitely), not a
normal ACK/NAK reply. The wait is a busy-wait loop, not a real timer (CP/M 2.2 has no
general-purpose one, and none of these programs use a BDOS timer call). So how long it
actually takes depends on your hardware's clock speed, roughly 15-20 real seconds on a stock
2MHz Altair. Each `.ASM`'s `TOOUTR` constant, right next to the port equates, controls it;
raise or lower it if the default feels wrong for your setup. A reply that starts arriving is
trusted to finish; only complete silence triggers this.

### A worked example, start to finish

```
A0>FUJIDIR N1:TNFS://192.168.1.5/
FUJIDIR: listing N1:TNFS://192.168.1.5/
HELLO.TXT                          14

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

All four of these programs (and `testing/NC.ASM`) talk **directly to I/O ports**, with no
BDOS or BIOS indirection in between. That is deliberate, not an oversight. CP/M's BDOS console
calls are wired to the one `CON:` device only, so there is no BDOS console call that reaches a
*second* serial line.

That means **the source is the config file**. If your hardware does not match this project's
assumptions, you edit the `.ASM`, reassemble (`ASM FUJIGET` / `LOAD FUJIGET`, etc.), and you
are done. There is no separate settings file, because CP/M's `ASM.COM` has no `INCLUDE`
directive. Each `.ASM` carries its own copy of the two things below. If you change one,
**change it in all of them** (including `testing/NC.ASM`, if you use it) and rebuild each one.

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
hardware, **this is the only thing that needs to change** to point these tools at it. Nothing
else in the file cares what the actual numbers are; they are used everywhere else only by
name.

### 2. The UART initialization

A few lines into each program's `START:`, before it does anything else with the port:

```asm
        MVI     A,SIORST        ; the ACIA out of reset...
        OUT     SIOST
        MVI     A,SIOCTL        ; ...and into a real operating mode
        OUT     SIOST
```

This is specific to the **6850 ACIA** the 88-2SIO uses. Unlike boards such as the 88-SIO or
88-ACR, whose word format is set by jumpers, baud-rate division, word format (data/parity/stop
bits), and RTS/interrupt behavior are **registers the guest program writes**, not something
fixed in hardware. `03H` is the 6850's master-reset code. `15H` (`00010101`) selects ÷16
clocking with 8N1 framing and both interrupts left off, matched to the example `sio0` unit b
in section 2 above, running at 9600 baud with no interrupts.

If your hardware's serial interface **sets its format with jumpers or switches instead** (or
uses some other chip entirely: an 8251 USART, a bit-banged port, whatever), **delete these
four lines outright**. There is nothing for the guest to configure, and writing an ACIA-style
control byte to a port that is not a 6850 could do something you do not want. If it is a 6850
but at a different baud rate or word format, change `15H` to whatever control byte your setup
needs. The two bits at the bottom select the clock divide, the next three select word format,
and the top three control RTS and the two interrupt-enable bits. Any 6850 datasheet has the
full table.

### 3. The response-timeout budget

Also worth knowing about while you are in there: `TOOUTR`, near the port equates, controls how
long each program waits for a reply before reporting `destination server not responding` (see
section 4 above). It is a busy-wait iteration count, not a real timer, so it scales with your
actual CPU clock speed. If your machine is slower or faster than a stock 2MHz Altair, adjust
it. You are not likely to need to touch it otherwise.

---

## 6. Testing without a real network host

You do not need a real TNFS/HTTP server on your network to try any of this. A local `tnfsd`
test server works fine, and is what these tools were actually verified against:

1. Download the official `tnfsd` binary for your platform from
   <https://github.com/FujiNetWIFI/tnfsd/releases> (it is a small, standalone server from the
   FujiNet project itself; a few tens of KB, no install needed).
2. Make a directory to serve, e.g. `mkdir share` and drop a test file or two in it.
3. Run it: `./tnfsd share` (add `-r` for read-only, `-p PORT` for a non-default port; it
   listens on UDP/TCP `16384` by default). On macOS you will likely need
   `xattr -d com.apple.quarantine ./tnfsd` first, same as FujiNet-PC above.
4. Point your `N:` URLs at it, e.g. `FUJIDIR N1:TNFS://127.0.0.1/`.

That is it. FujiNet-PC talks to `tnfsd` the same way it would talk to any real TNFS server. So
everything above works identically against `127.0.0.1` as it would against a real remote host.

**Want to run a real server with mixed read-only/write-only folders** (an "upload here, browse
there" layout, like an old-school anonymous FTP site)? See `tnfsd-server-setup/` in this repo,
which points you at [de-tnfsd](https://github.com/trgeuy/de-tnfsd) for the server itself and
covers a real CP/M-side gotcha (command-line case-folding) that will otherwise make lowercase
server paths unreachable.

---

## Known limitations

- **Failure messages ("not found," "denied," "parent path does not exist") are inferred, not
  server-reported.** FujiNet's NAK carries no error detail at all for any of these commands
  (confirmed from `fujinet-firmware` source). So each tool probes the parent directory after a
  failure and guesses from that: a strong heuristic, not a guarantee. See
  `docs/rs232-protocol.md` for the full reasoning.
- **No delete/remove tools (`RMDIR`, file `DELETE`).** FujiNet's protocol supports both (see
  `docs/rs232-protocol.md`), but they are not implemented here. This is a deliberate choice,
  not a gap, to avoid shipping easy ways to destroy data on a remote server you may not
  control.
- **The upstream `fnTcpClient` idle-disconnect bug.** Confirmed in `fujinet-firmware`'s
  source: a non-blocking `recv(MSG_PEEK)` returning 0 is misread as "connection closed," which
  can happen to a perfectly healthy but momentarily quiet TCP connection. This affects raw
  `TCP:` connections (like this project's earlier `NC.COM` netcat tool). It has not been
  observed against `FUJIGET`/`FUJIPUT`/`FUJIDIR`'s TNFS-based testing, which is UDP-based and
  unaffected. Worth knowing about if you point these tools at a raw `TCP:` URL and see
  unexpected disconnects on an idle link.
- **Disk mounting** (`FUJICMD_MOUNT_HOST`/`MOUNT_IMAGE`, i.e. making a remote disk image appear
  as a real CP/M drive letter) is not implemented and not planned for now. It would need a new
  CP/M BIOS driver speaking a completely separate, Atari-SIO-flavored sector protocol
  (`DISKCMD_*`): a much bigger undertaking than these four utilities, and untested at the
  protocol level besides. The simple workaround already available: `FUJIGET` a `.DSK` image
  down to the host machine, then point `altairsim`'s own disk board at it directly.
- **Windows and Linux instructions for FujiNet-PC** are not written yet (see the top of this
  document). This project has only run on macOS so far.

## Where the protocol details live

This README is about *using* the tools. The wire protocol they implement (SLIP framing, packet
layout, command bytes) is documented in `docs/rs232-protocol.md` in this folder,
reverse-engineered from `fujinet-firmware`'s source and verified live against a running
`fujinet-pc-RS232`.

---

## What changed

Full Simplified-Technical-English-style rewrite, not a light pass. Every fact, number,
filename, version number, URL, code block, and quoted string from the original is preserved
exactly. Nothing was added or dropped.

**Rule 2 (sentence limits) — the dominant violation.** The original is written in a dense,
compound-clause style: single sentences carrying two, three, or four ideas joined with "but,"
"so," "since," and parenthetical asides (the opening paragraphs, "What's tested so far," the
FUJIGET/FUJIPUT/FUJIDIR descriptions, and the "Known limitations" bullets are the worst
offenders). Nearly every sentence in the rewrite is one idea, one clause; long originals were
split into several short sentences in reading order, with no fact reordered.

**Rule 10 (em dashes).** The original uses em dashes throughout, standing in for commas,
colons, periods, and parentheses. All were replaced with a period, comma, colon, or plain
parentheses depending on what the dash was doing in that sentence. The three subsection
headings that used an em dash as a label separator (`FUJIGET — pull a file down`, and the two
that follow it) were changed to a colon (`FUJIGET: pull a file down`); no wording changed.

**Rule 4 (active voice).** A few passive constructions were rewritten with a clear subject
doing the action, e.g. "the network side is confirmed open... before anything on the CP/M side
is touched" became "FUJIGET confirms the network side is open and readable before it touches
anything on the CP/M side."

**Rule 7 (noun clusters) and long parentheticals.** Several long parenthetical asides (e.g. the
`altairsim`/`tnfsd-server-setup`/`fujinet-rs232`/`wget` folder descriptions in the intro, and
the "Adapting to different hardware" preamble) were unpacked into their own sentences rather
than nested in a single sprawling one.

**Left alone.** Every code block, `.toml`/`.asm`/`.ini` snippet, command, URL, table cell, file
name, version number, and the worked-example transcript are reproduced exactly as in the
original, per the skill's rule against simplifying exact strings. Bold emphasis markers on key
terms (`**B**`, `**T**`, `**RS232**`, etc.) were kept where the original used them to flag a
critical distinction. No AI-slop blocklist words (*delve, crucial, seamless,* and so on)
appeared in the original; this was a structural rewrite, not a filler-removal pass.
