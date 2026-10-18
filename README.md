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
FUJIGET N:<url> file.ext [/O]   pull a file down, e.g. FUJIGET N1:TNFS://192.168.1.5/HELLO.TXT HELLO.TXT
FUJIPUT file.ext N:<url> [B|T]  push a file up,    e.g. FUJIPUT HELLO.TXT N1:TNFS://192.168.1.5/HELLO.TXT T
FUJIDIR N:<url>[pattern]        list a directory,  e.g. FUJIDIR N1:TNFS://192.168.1.5/*.COM
```

Each tool has its own version number. Each tool changes on its own schedule, not together.
Each tool prints its own version when you run it with no arguments. Current versions:
`FUJIGET` v1.9, `FUJIPUT` v1.6, `FUJIDIR` v1.7.

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
[de-tnfsd](https://github.com/deltecent/de-tnfsd), a TNFS daemon built around a
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

`cpm-tnfsd/` is `TNFSD`, a TNFS server that runs on CP/M itself. Another machine with a
FujiNet can then use `FUJIGET`, `FUJIPUT` and `FUJIDIR` on this machine's files: CP/M-to-CP/M
file transfer over a LAN. It has real limits, and no password protection. Read its README
before you use it. It is repo-only. See
<https://github.com/trgeuy/fujinet-cpm22/tree/main/cpm-tnfsd>.

`firmware-uploader-apple-silicon/` is unrelated to CP/M itself. It is useful to anyone bringing
up a real FujiNet adapter from an Apple Silicon Mac. It is a patched drop-in replacement for
upstream `fujinet-firmware`'s firmware-flashing script. It fixes an Apple Silicon compatibility
gap in the stock version. It is an interim fix, not a fork or a pending PR. See
<https://github.com/trgeuy/fujinet-cpm22/tree/main/firmware-uploader-apple-silicon> for why.

## What's tested so far

Everything here has been built and verified against the **emulated** `fujinet-pc-RS232`
build, talking to a local TNFS test server, on **macOS**. All three tools have also been
verified end to end against a TNFS server running on actual Raspberry Pi hardware over a real
LAN. This includes the mixed read-only/write-only permission layout described in
`tnfsd-server-setup/`. **All three tools have also now been verified on a real physical
FujiNet RS232 adapter on a real Altair 8800c.** See `fujinet-rs232/` for bring-up
instructions. **All four tools also run on a non-Altair machine**: a CompuPro Interfacer 1 in
a Z80 system, changed as described in [section 5](#5-adapting-to-different-hardware).
**Windows/Linux instructions for the emulator host side (FujiNet-PC) are not
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
was tested against a nightly build that reports itself as `FujiNet v1.6-8f7231a78 2026-10-12
23:27:33 (RS232)`. If something does not match this guide, that version is the reference point.

**Check the version line, not the file date.** The nightly release is one page, and its files
are replaced in place. Each platform file has its own date, and a file can get a new date
while the program in it stays the same. When FujiNet-PC starts, it prints its version and
build date in a line that starts with `FujiNet v`. Use that line to identify your build. Do
not use a build dated 2026-10-02 to 2026-10-06. Those builds can cut off a `FUJIDIR` listing
that is longer than 512 bytes.

**Install** (macOS):

```
brew install openssl@4                       # FujiNet-PC needs Homebrew's OpenSSL
mkdir -p ~/fujinet-pc                        # or wherever you want it to live
tar xf ~/Downloads/fujinet-pc-RS232_*.tar* -C ~/fujinet-pc
cd ~/fujinet-pc/fujinet-pc-RS232
xattr -dr com.apple.quarantine .             # macOS will otherwise refuse to run it
```

Safari removes the `.gz` from the download name, so the file can end in `.tar` or `.tar.gz`.
`tar xf` reads both. The archive holds one folder, `fujinet-pc-RS232/`. macOS marks every
file in it as downloaded, so `xattr -dr` clears the whole folder, not only `fujinet`.

The macOS build of FujiNet-PC loads the OpenSSL library from [Homebrew](https://brew.sh). If
the library is missing, FujiNet-PC stops at once with `Library not loaded:
/opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib`. Install the OpenSSL version that this
error names. Older builds, such as `947873d94`, use `openssl@3`.

Keep the extracted `fujinet` binary together with the `fnconfig.ini`, `data/`, and `SD/` that
come with the archive (or that get created on first run). The program uses paths relative to
its own working directory, not absolute ones. Always run it *from* that directory.

**Configure it for BOIP** (Bus-over-IP: a raw TCP byte pipe standing in for the physical
serial cable). The `fnconfig.ini` in the download is already correct for this. If you changed
it, make sure that

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

**Convenience launcher**: the download includes `run-fujinet`, a small wrapper. Run
`./run-fujinet -u 127.0.0.1:8005` instead of calling `./fujinet` directly. (If your download
does not have it, `altairsim/run-fujinet` in this repo is the same file. Copy it into the
folder.) It automatically re-launches FujiNet-PC if it exits with code 75
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
you give this card is also the id the four programs need to know about. If you move the card
to other ports, the programs need the new port addresses; see
[section 5](#5-adapting-to-different-hardware).)

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
whatever transfer method your setup already has.

**On `altairsim`, use its Host Bridge.** The system disk in `altairsim/` already has the Host
Bridge tools `R`, `W`, and `HDIR`. `R` copies a file from your host into CP/M. It reads from the
folder you started `altairsim` in (`altairsim/`, if you followed its README).

1. Copy `FUJIGET.COM`, `FUJIPUT.COM`, and `FUJIDIR.COM` from the top of this repo into
   `altairsim/`.
2. At the CP/M prompt, type `R FUJIGET.COM`. `R` copies the file and reports its size.
3. Repeat for `FUJIPUT.COM` and `FUJIDIR.COM`. `HDIR` lists the host files that `R` can see.

Then skip to "Using the tools" below. Any other way to get a file from your host onto the CP/M
disk also works, for example a disk image you can mount on the host.

**On other machines, here is the classic, universal CP/M way.** It needs nothing but a
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
FUJIGET N:<url> file.ext [/O]
```

FUJIGET opens `<url>` for read on FujiNet's `N:` device. It writes the bytes into a new CP/M
file `file.ext`, creating or overwriting it. Type the URL exactly as FujiNet expects it,
including the `Nx:` channel prefix, e.g. `N1:TNFS://192.168.1.5/HELLO.TXT`,
`N1:TCP://192.168.1.5:9000/`, `N1:HTTP://example.com/file.txt`. FUJIGET confirms the network
side is open and readable *before* it touches anything on the CP/M side. A failed open never
deletes an existing local file of the same name.

If `file.ext` already exists locally, FUJIGET asks `HELLO.TXT exists. Replace? (Y/N)` before
touching the network side at all. Decline, and nothing happens, on either side.

Since v1.9, `/O` after the filename replaces the file without that question, for scripts that
cannot know whether it will come. The old file is still kept until a clean end of file (see
"When a transfer fails" below), so a failed fetch with `/O` loses nothing. Anything else after
the filename stops FUJIGET with `FUJIGET: the only switch is /O (replace without asking).`

As of v1.4, FUJIGET prints `Received NNNN KB...` in place (overwriting itself, not scrolling)
once every 1KB received. So a transfer that takes a while shows a visible sign of life
without filling the screen the way a dot per packet would.

If the network open fails, FUJIGET tells you *which kind* of failure it was. Since v1.8 it
first asks FujiNet for the reason. FujiNet firmware from 2026-09-27 on keeps the reason for a
failed open. If the server refused access, FUJIGET reports `denied (permission or server
restriction)`, for example for a read from a server's write-only `incoming/` drop box. In
all other cases, and with older firmware, it makes a best-effort diagnosis from the parent
directory (see "Where the protocol details live" below). It reports `not found on that
remote server` (the URL's parent path exists, but the target does not; by far the most
common cause) or `failed -- parent path does not exist` (not even the containing directory
is there).

#### When a transfer fails (v1.7)

FUJIGET writes the data to a temporary file first: the same name with the type `$$$`, for
example `HELLO.$$$`. Only after a clean end of file does it erase the old `HELLO.TXT` and rename
`HELLO.$$$` to it. If anything fails, or you press Ctrl-C, FUJIGET erases the temporary file. Your
old file stays as it was. The message ends with `Nothing was saved.`

After the open, FujiNet reports problems in an error code. FUJIGET checks that code each time it
asks FujiNet for the transfer's status, and stops with the code and its meaning, for example:

```
FUJIGET: FujiNet reported error 170 (not found). Nothing was saved.
```

Some codes you can see (the full list is in the RS-232 FujiNet User's Manual, 9.12):

| Code | Meaning | Typical cause |
|---|---|---|
| 170 | not found | An HTTP 404: the URL's file is not on the web server. |
| 212 | invalid user name or password | An HTTP 401 or 403. FUJIGET prints the number only. |
| 207 | could not connect | Nothing listens at the host and port in the URL. |
| 144 | general error | The server refused a write (FUJIPUT): full disk, size limit. |
| 215 | server error | An HTTP 5xx. |

Before v1.7, FUJIGET saved an HTTP error page as if it were the file, and a server that was not
there gave `0 records received.` after the old local file was already erased.

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
asked. Over HTTP an open always succeeds, so since v1.5 the probe also asks FujiNet for the
status: error 170 (not found) means "not there".

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

Since v1.5, FUJIPUT checks FujiNet's answer to every block it sends. If the server refuses the
data (a full disk, a size limit, a dropped connection), FUJIPUT stops and says so:

```
FUJIPUT: the server refused the data (FujiNet error 144 (general error)).
The remote file is incomplete.
```

Before v1.5, FUJIPUT printed `NNN records sent.` even when the server had kept only part of the
file. A file on the server cannot be put back the way it was: send it again when the cause is
fixed.

If the write-mode open fails (after the overwrite check above has already been answered, or
found nothing to ask about), FUJIPUT also asks FujiNet for the reason first (since v1.6).
Access denied gives `denied (permission or server restriction)`, for example a name that is
already taken in a drop box. Not found gives `failed -- parent path does not exist`. With
older firmware, FUJIPUT makes the same best-effort diagnosis as FUJIGET (see "Where the
protocol details live" below). It reports `denied (permission or server restriction)` if the
parent path checks out, since creating or writing was expected to just work, or
`failed -- parent path does not exist` if the parent is not there either.

### FUJIDIR: list a directory

```
FUJIDIR N:<url>
FUJIDIR N:<url><pattern>
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

#### Wildcards (v1.6)

Put a pattern with `*` as the last part of the URL. FUJIDIR then lists only the entries
that match:

```
FUJIDIR N1:TNFS://192.168.1.5/*.COM
FUJIDIR N1:TNFS://192.168.1.5/GAMES/PAC*.*
```

- **Use `*`, not `?`.** FujiNet reads a `?` in a URL as the start of a URL query, and cuts
  the path there. FUJIDIR refuses a `?` in the pattern with a message.
- **The server does the matching**, so its rules apply. `de-tnfsd` matches like a Unix
  shell: `FUJI*` matches `FUJIGET.COM`. `TNFSD` (in `cpm-tnfsd/`) matches like CP/M's
  `DIR`: `FUJI*` matches only files with no extension, so use `FUJI*.*`.
- **No match** gives `FUJIDIR: nothing matches.`
- **Only the last part of the path is a pattern.** FUJIDIR sends a `*` in a folder name
  as part of the folder name.

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
raise or lower it if the default feels wrong for your setup.

Since FUJIGET v1.7, FUJIPUT v1.5 and FUJIDIR v1.7 (and WGET v1.3), the tools also check each reply
that does arrive. A reply that stops part-way (no byte for about 1.5 s at 2 MHz), is too long, or
fails its length or checksum check gives `<TOOL>: damaged or incomplete reply from FujiNet.` These
checks cost about 7% of the transfer speed on a 2 MHz 8800c (92 KB: 46.6 s, against 43.4 s
before).

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

The tools talk to the FujiNet through an 88-2SIO, unit b, at ports `12H`/`13H`. They use the
I/O ports directly, so a different serial board needs changes in the source:

- the port addresses,
- the status bits, for any UART that is not a 6850,
- the UART initialization, for any UART that is not a 6850.

[`docs/adapting-to-hardware.md`](docs/adapting-to-hardware.md) gives the full instructions, a
list of every place to change in each file, and a worked example: a CompuPro Interfacer 1 in a
Z80 system, with all four tools tested on the real machine.

---

## 6. Testing without a real network host

You do not need a real TNFS/HTTP server on your network to try any of this. Run
[de-tnfsd](https://github.com/deltecent/de-tnfsd), a TNFS server, on your own machine:

1. Build it from source: `git clone https://github.com/deltecent/de-tnfsd`, then `make` in that
   folder. It is a small C program with no dependencies, and POSIX only (macOS and Linux, not
   Windows). The build puts the server at `bin/de-tnfsd`.
2. Make a directory to serve, e.g. `mkdir share`, and put a test file or two in it.
3. Run it: `bin/de-tnfsd --serve-root-rw share`. This serves the whole directory, read/write.
   It listens on port `16384` by default; `-p PORT` picks another.
4. Point your `N:` URLs at it, e.g. `FUJIDIR N1:TNFS://127.0.0.1/`.

That is it. FujiNet-PC talks to `de-tnfsd` the same way it talks to any real TNFS server. So
everything above works the same against `127.0.0.1` as against a real remote host.

**Want to run a real server with a read-only folder and a write-only upload folder** (an
"upload here, browse there" layout, like an old-school anonymous FTP site)? That is
`de-tnfsd`'s default mode. See `tnfsd-server-setup/` in this repo for the setup, and for a
real CP/M-side gotcha (command-line case-folding) that will otherwise make lowercase server
paths unreachable.

---

## Known limitations

- **A failed open is partly diagnosed by inference.** FUJIGET (v1.8) and FUJIPUT (v1.6) first
  ask FujiNet for the reason, which firmware from 2026-09-27 on keeps. Otherwise, and in
  FUJIDIR, the messages "not found," "denied" and "parent path does not exist" are inferred,
  not server-reported: each tool probes the parent directory and guesses from that. A strong
  heuristic, not a guarantee. See `docs/rs232-protocol.md`. Failures *after* the open come
  from FujiNet's own error code (see "When a transfer fails" above).
- **No delete/remove tools (`RMDIR`, file `DELETE`).** FujiNet's protocol supports both (see
  `docs/rs232-protocol.md`), but they are not implemented here. This is a deliberate choice,
  not a gap, to avoid shipping easy ways to destroy data on a remote server you may not
  control.
- **The upstream `fnTcpClient` idle-disconnect bug.** Confirmed in `fujinet-firmware`'s
  source: a non-blocking `recv(MSG_PEEK)` returning 0 is misread as "connection closed," which
  can happen to a perfectly healthy but momentarily quiet TCP connection. This affects raw
  `TCP:` connections (like this project's earlier `NC.COM` netcat tool). It has not been
  observed in `FUJIGET`/`FUJIPUT`/`FUJIDIR`'s TNFS testing. Note that TNFS is not always UDP:
  FujiNet's TNFS client tries TCP first, and falls back to UDP only when the server does not
  answer on TCP. Against a server that accepts TCP, such as `de-tnfsd` or `TNFSD`, TNFS runs
  over TCP. Worth knowing about if you point these tools at a raw `TCP:` URL and see
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
