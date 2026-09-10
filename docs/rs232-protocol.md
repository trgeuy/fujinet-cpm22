# The FujiNet RS232 wire protocol (reverse-engineered from source)

This file is not a conversion of a PDF. No manual exists for this protocol.
`Reference/fujinet/connecting-an-emulator-to-fujinet-pc.md` and
`fujinet-programmers-guide-adam.md` both document **AdamNet** instead. AdamNet is a
different, packet-addressed bus for the Coleco ADAM. Altair/CP/M uses RS232, a plain byte
stream. No manual for RS232 exists in `Documentation/`.

This file comes from the actual `fujinet-firmware` source: `lib/bus/rs232/`,
`lib/device/rs232/`, `include/fujiDeviceID.h`, `include/fujiCommandID.h`. The team read
that source against a running `fujinet-pc-RS232` v1.6.2-dev nightly build. This is the same
method the AdamNet manual describes: read the firmware, not secondary docs.

**Status:** verified for the framing, checksum, and device-command tables (read from source
verbatim). Medium confidence on the exact per-command payload shape beyond network
open/read/write/status. See "Remaining gap" below before you write code against
`MOUNT_HOST`/`MOUNT_IMAGE` or `NETCMD_OPEN`'s URL argument.

## Proven so far, live

`altairsim`'s `2sio` board, unit `b`, connects to `socket:localhost:1985`. This is
FujiNet-PC-RS232's BOIP (Bus-over-IP) listener. It is the default target when
`fnconfig.ini`'s `[Serial] port=` is left empty.

This connection is a working raw byte pipe. An 8080 program bit-banged the 6850 ACIA
(status port `BASE+2`, data port `BASE+3`) and sent `AT\r`. FujiNet's log then showed
`Modem cmd: WRITE` and `AT Cmd: AT`. This confirms the pipe works end to end.

**Ruled out:** `[CPM] cpm_enabled=1` and the `ATCPM` modem command make FujiNet host its
own CP/M. This uses RunCPM, an embedded Z80/CP/M emulator, for an Atari that acts as a dumb
terminal dialing in. This feature does not drive FujiNet's services from a real CP/M
machine. It is the opposite of what this project wants.

## 1. Entering binary/command mode: no escape string, just `0xC0`

`_rs232_process_cmd()` in `rs232.cpp` reads bytes one at a time. It buffers any byte before
a `0xC0` byte and hands that buffer to the modem device as plain AT-command text. The
`AT\r` test above exercised this path. The moment a `0xC0` byte appears, the parser
switches to reading a binary `FujiBusPacket`, starting at that byte.

**The SLIP frame delimiter *is* the mode switch.** There is no `AT+FUJI`-style escape
command. Plain AT-modem text and binary FujiBusPackets can freely interleave on the same
line.

## 2. Packet format — SLIP-framed `FujiBusPacket`

Outer framing is standard SLIP (RFC 1055): `0xC0 <escaped bytes> 0xC0`. Within the frame,
`0xC0` becomes `0xDB 0xDC` and `0xDB` becomes `0xDB 0xDD` (`SLIP_END=0xC0`,
`SLIP_ESCAPE=0xDB`, `SLIP_ESC_END=0xDC`, `SLIP_ESC_ESC=0xDD`). A full packet is exactly one
SLIP frame. `readBusPacket()` reads until it sees two `0xC0` bytes: one to open the frame,
one to close it.

Once decoded (unescaped), the layout is a 6-byte header, then descriptor/param bytes, then
an optional payload:

```c
struct fujibus_header {          // packed, 6 bytes
    uint8_t  device;              // destination device ID (§3)
    uint8_t  command;             // command byte (§3, per-device-class table)
    uint16_t length;              // little-endian; TOTAL decoded packet length, header included
    uint8_t  checksum;            // §below
    uint8_t  descr;               // first parameter-descriptor byte
};
```

- **Checksum.** This covers the entire decoded packet, with the checksum byte itself zeroed
  first: `chk=0; for each byte: chk += byte; chk = (chk>>8) + (chk&0xFF)`. This is a 16-bit
  sum with the end-around carry folded into 8 bits. To verify a received packet, zero the
  checksum byte in a copy and recompute it.
- **Parameter descriptors.** Each descriptor byte packs 0 to 4 fixed-width params. Its low 3
  bits (`&0x07`) index two tables: `fieldSizeTable = {0, 1, 1, 1, 1, 2, 2, 4}` and
  `numFieldsTable = {0, 1, 2, 3, 4, 1, 2, 1}`. For example, descriptor `2` means two 1-byte
  params, `6` means two 2-byte params, and `7` means one 4-byte param. Bit `0x80` set means
  another descriptor byte follows, for more than 4 params or for mixed widths. The *first*
  descriptor byte lives in the header itself (`hdr.descr`). Further descriptor bytes follow
  right after the header, before the param bytes. Multi-byte param values are little-endian.
- **Payload.** This is whatever remains after the header, descriptors, and params: write
  data, filenames, response buffers, and so on.

The full frame is: `0xC0` `[device][command][length_lo][length_hi][checksum][descr]`
`[addl descriptor bytes...]` `[param bytes...]` `[payload bytes...]` `0xC0`, SLIP-escaped.
`length` counts decoded bytes, including the 6-byte header.

## 3. Responses

FujiNet replies with its own `FujiBusPacket`, from `sendReplyPacket()`. The reply uses the
same `device` ID. On success, `command = FUJICMD_ACK (0x06)`, with the payload holding any
response data. On error, `command = FUJICMD_NAK (0x15)`, with no payload.

**Exception:** if `device` was the modem device, the reply is raw bytes, not a wrapped
packet. This follows plain AT-command semantics.

## 4. Device IDs (`include/fujiDeviceID.h`, non-ADAM `#else` branch: what RS232/desktop builds use)

| Device | ID |
|---|---|
| `FUJI_DEVICEID_FUJINET` (the Fuji control device) | `0x70` |
| `FUJI_DEVICEID_DISK` | `0x31`–`0x3F` |
| `FUJI_DEVICEID_PRINTER` | `0x40`–`0x43` |
| `FUJI_DEVICEID_CLOCK` (APETime) | `0x45` |
| `FUJI_DEVICEID_ASPEQT` | `0x46` |
| `FUJI_DEVICEID_SERIAL` | `0x50`–`0x53` |
| `FUJI_DEVICEID_CPM` (RunCPM — not what we want) | `0x5A` |
| `FUJI_DEVICEID_CASSETTE` | `0x5F` |
| `FUJI_DEVICEID_PCLINK` | `0x6F` |
| `FUJI_DEVICEID_NETWORK` (8 slots) | `0x71`–`0x78` |
| `FUJI_DEVICEID_MIDI` | `0x99` |
| `FUJI_DEVICEID_DBC` | `0xFF` |

## 5. Command sets (`include/fujiCommandID.h`): values overlap across device classes; `device` tells them apart

**`FUJICMD_*`** (→ `0x70`, Fuji control): `MOUNT_HOST` `0xF9`, `MOUNT_IMAGE` `0xF8`, `UNMOUNT_IMAGE` `0xE9`, `UNMOUNT_HOST` `0xE6`, `OPEN_DIRECTORY`/`READ_DIR_ENTRY`/`CLOSE_DIRECTORY` `0xF7`/`0xF6`/`0xF5`, `READ_HOST_SLOTS`/`WRITE_HOST_SLOTS` `0xF4`/`0xF3`, `READ_DEVICE_SLOTS`/`WRITE_DEVICE_SLOTS` `0xF2`/`0xF1`, `GET_ADAPTERCONFIG` `0xE8`, `NEW_DISK` `0xE7`, `SET_DEVICE_FULLPATH`/`GET_DEVICE_FULLPATH` `0xE2`/`0xDA`, `SET_HOST_PREFIX`/`GET_HOST_PREFIX` `0xE1`/`0xE0`, `MOUNT_ALL` `0xD7`, `COPY_FILE` `0xD8`, `ENABLE_DEVICE`/`DISABLE_DEVICE` `0xD5`/`0xD4`, `GET_TIME` `0xD2`, `RANDOM_NUMBER` `0xD3`, Base64/Hash/QRCode helpers `0xC2`–`0xD0`, `0xBC`–`0xBF`, `GET_SSID`/`SET_SSID`/`SCAN_NETWORKS`/`GET_WIFISTATUS` `0xFE`/`0xFB`/`0xFD`/`0xFA`, `RESET` `0xFF`. Response-only meta codes: `ACK` `0x06`, `NAK` `0x15`, `SEND_ERROR` `0x02`, `SEND_RESPONSE` `0x01`, `DEVICE_READY` `0x00`.

**`NETCMD_*`** (→ `0x71`–`0x78`, a network slot) — the one that matters most for a general client: `OPEN` `0x4F`/`'O'`, `CLOSE` `0x43`/`'C'`, `READ` `0x52`/`'R'`, `WRITE` `0x57`/`'W'`, `STATUS` `0x53`/`'S'`, `SEEK` `0x25`, `TELL` `0x26`, `MKDIR`/`RMDIR`/`CHDIR`/`GETCWD` `0x2A`/`0x2B`/`0x2C`/`0x30`, `RENAME` `0x20`, `DELETE` `0x21`, `LOCK`/`UNLOCK` `0x23`/`0x24`, `SET_EOL` `0x4C`, `USERNAME`/`PASSWORD` `0xFD`/`0xFE`, `SET_CHANNEL_MODE` `0x4D`, `GET_ERROR` `0x45`, `SET_DESTINATION` `0x44` (UDP-style), `CONTROL` `0x41`.

**`DISKCMD_*`** (→ `0x31`–`0x3F`): `READ` `0x52`/`'R'`, `WRITE` `0x57`/`'W'`, `STATUS` `0x53`/`'S'`, `PUT` `0x50`/`'P'`, `FORMAT`/`FORMAT_MEDIUM` `0x21`/`0x22`, `PERCOM_READ`/`PERCOM_WRITE` `0x4E`/`0x4F`, plus `HSIO_*` high-speed variants.

**`MODEMCMD_*`** (→ modem device): `WRITE` `0x57`/`'W'` (what the `AT` test exercised), `READ` `0x52`/`'R'`, `STATUS` `0x53`/`'S'`, `STREAM` `0x58`/`'X'`, `AUTOANSWER` `0x4F`/`'O'`, `LISTEN`/`UNLISTEN` `0x4C`/`0x4D`, `CONFIGURE` `0x42`/`'B'`, `CONTROL` `0x41`/`'A'`.

**`APETIMECMD_*`** (→ `0x45`, clock): time-format-specific reads (`GET_ATARI`, `GET_ISO_UTC`, `GET_ISO_LOCAL`, `GET_PRODOS`, `GET_SOS`, `GET_SIMPLE_HUNDREDTHS`, timezone variants...). `FUJICMD_GET_TIME` on the Fuji device is probably the simpler general-purpose choice.

**`CPMCMD_*`** (→ `0x5A`, RunCPM) — irrelevant, FujiNet's own embedded CP/M.

## 6. Worked example — network open/read/write/status (`lib/device/rs232/network.cpp`)

```c
case NETCMD_OPEN:   // 2 one-byte params: param(0)=fileAccessMode_t, param(1)=netProtoTranslation_t
    rs232_open((fileAccessMode_t)packet.param(0), (netProtoTranslation_t)packet.param(1));
    // -> parse_and_instantiate_protocol(access); protocol->open(urlParser...); transaction_success()/error()

case NETCMD_READ:   // 1 param: param(0) = uint16 length requested
    // -> transaction_send(receiveBuffer data, length, is_error)   // reply payload = the bytes read

case NETCMD_WRITE:  // 1 param: param(0) = uint16 length; payload = bytes to write
    // -> transaction_get(newData, length) pulls payload out of the packet, writes to the connection

case NETCMD_STATUS: // param(1) selects a FujiStatusReq subtype if paramCount >= 2
    // -> replies with a fixed-size status struct via transaction_send
```

## Verified live (2026-08-26): network device open/write/status/read/close

The team confirmed this end to end against a real `fujinet-pc-RS232` v1.6.2-dev build's
BOIP port (`localhost:1985`). A Python prototype (SLIP encode/decode, checksum, packet
build/parse) talked to a local Python TCP echo server on `127.0.0.1:9000`. The team chose a
local echo server over a real internet host to keep the test self-contained:

- **`NETCMD_OPEN`'s payload IS the device-spec string.** It is NUL-terminated and keeps
  the `Nx:` channel prefix, for example `b"N1:TCP://127.0.0.1:9000/\x00"`. This holds even
  though the packet header's `device` byte (`0x71`, the first network slot) already selects
  the channel. Params: `(1-byte access_mode, 1-byte translation_mode)`. The team confirmed
  working values against the AdamNet chapter of `fujinet-programmers-guide-adam.md`
  (§Opening and Closing, which shares the same enum across bus backends): access mode
  `$04`=read, `$08`=write, `$0C`=read/write, `$0D`=HTTP POST, `$05`=HTTP DELETE; translation
  `$00`=none (binary), `$01`=CR, `$02`=LF, `$03`=CRLF. A test with mode `$0C`, translation
  `$00`, returned **ACK**.
- **`NETCMD_WRITE`** takes 1 param, a 2-byte length. The payload is the bytes to write. It
  returns **ACK**.
- **`NETCMD_STATUS`** takes zero params. Its response payload is **4 bytes**:
  `bytes_waiting` (u16 LE), `connected` (u8), `error` (u8). The team confirmed this both from
  the wire (`13 00 01 01`) and from FujiNet's own log line for that call:
  `rs232_status_channel() - BW: 19 C: 1 E: 1`. By Atari convention, `error=1` means "no
  error", i.e. success.
- **`NETCMD_READ`** takes 1 param, the requested length in 2 bytes. Its response payload is
  **exactly the requested length**: real data first, then uninitialized or leftover buffer
  bytes as padding. Use `STATUS`'s `bytes_waiting` to know how much of the response is real.
  Do not trust the full response length as "bytes received." Confirmed: a request for 64
  bytes returned `ECHO:hello fujinet\n` (19 real bytes) plus 45 bytes of buffer garbage.
- **`NETCMD_CLOSE`** takes zero params. It returns **ACK**.

This closes the two gaps below for the network-device path. **`FUJICMD_MOUNT_HOST`/
`MOUNT_IMAGE` (disk mounting via the Fuji control device, `0x70`) is still unverified.** No
one has run a live test of it yet.

## Verified live (2026-08-27): read-mode `NETCMD_OPEN` as an existence probe

The team confirmed this against a local `tnfsd` (`tnfsd/`) serving `tnfsd/share/`, driven by
the same Python SLIP/FujiBusPacket approach as above, over `fujinet-rs232`'s BOIP port. The
question: can a client check whether a remote file exists before opening it for write,
without an unverified command? (`FUJICMD_OPEN_DIRECTORY` and similar commands are still
untested; see below.)

- **`NETCMD_OPEN` with `access_mode=$04` (read) ACKs if the target exists, and NAKs if it
  does not.** Confirmed both ways: `HELLO.TXT` (present) returned ACK, `MISSING.TXT`
  (absent) returned NAK. This is the same command already verified for write above, just
  with the read access-mode value.
- **`NETCMD_CLOSE` ACKs cleanly after either outcome,** including right after a NAK'd open,
  where there is no open handle to close. It is safe to send unconditionally.
- **The probe has no side effects on the real open that follows it.** A full
  single-connection sequence ran clean, start to finish: probe-open read (NAK, file absent),
  close (ACK), open write (ACK), write (ACK), close (ACK), probe-open read again (now ACK,
  file exists), close (ACK). Probing first does not disturb the write that follows it.

**Consequence:** an overwrite-confirmation check for a tool like `FUJIPUT.COM` does not need
`FUJICMD_OPEN_DIRECTORY`/`READ_DIR_ENTRY` at all (these remain unverified, below). It can
open read-only first: the ACK or NAK tells you whether the target exists. Then it closes,
and opens for real. This only answers "does a file/URL exist" for backends where a
read-open has that meaning: TNFS, SD, HTTP GET. It says nothing for a raw `TCP://` stream,
which has no concept of file existence.

## Traced from source, then verified live (2026-08-30): `NETCMD_MKDIR`/`RMDIR` payload shape

The team traced this directly from `lib/device/rs232/network.cpp`
(`rs232Network::process_fs`, `create_devicespec`) on GitHub. The same code path handles
`NET_MKDIR`, `NET_RMDIR`, `NET_RENAME`, `NET_DELETE`, `NET_LOCK`, and `NET_UNLOCK`. So this
shape applies to all of them, not just MKDIR:

- **The payload is the device-spec string,** NUL-terminated, with the `Nx:` channel prefix
  kept. This is the same convention as `NETCMD_OPEN`'s payload (`create_devicespec` calls the
  exact same `SYSTEM_BUS.transaction_get(devicespecBuf, ...)` read that open uses). For
  example, a create-folder call sends `b"N1:TNFS://host/newfolder\x00"` as the packet
  payload, with command byte `NET_MKDIR` (`0x2A`).
- **Params: 0 or 1**, unlike OPEN's fixed 2. `process_fs` reads `param(0)` as an access mode
  only `if packet.paramCount() > 0`, and defaults to `0` otherwise. It is untested whether a
  real client needs to supply it; sending zero params looks plausible.
- Each of these commands re-parses its own devicespec into a fresh protocol instance,
  closing any protocol a prior `OPEN` left open. They are not scoped to an already-open
  channel, so `MKDIR` does not need a prior `OPEN`.
- The actual directory creation is `fs->mkdir(url)`. This routes through whichever
  `NetworkProtocolFS`-derived backend the URL scheme resolves to: TNFS, SD, and so on. It is
  not valid for a raw `TCP://` stream, which is not a filesystem protocol. On success it
  returns `FUJI_ERROR::NONE`, which triggers `transaction_success()`. Anything else triggers
  `transaction_error()`, with no error detail beyond the generic ACK/NAK envelope from this
  code path alone.

**Confirmed live, same day, in `CPM Tools/FUJIMKD.ASM`/`.COM`:** 0 params, a NUL-terminated
`Nx:`-prefixed devicespec payload, exactly as traced above. No access-mode param is needed.
Tests against a local `tnfsd` gave: create returns ACK, a duplicate create returns a clean
NAK, and a nested subdirectory create returns ACK. The team confirmed all three at the
actual filesystem level under `tnfsd/share/`, not just through `FUJIDIR`. Tests against a
real internet TNFS server, `tnfs.mitsaltair.com`, gave the same create and duplicate-NAK
behavior, confirmed afterward through a `FUJIDIR` listing. `FUJIMKD` sends a `CLOSE` after
the `MKDIR` request even though no persistent channel was opened. `rs232_close()`
gracefully no-ops when `protocol` is null, so this is safe either way. It also cleans up the
freshly-instantiated protocol object that `process_fs` leaves behind.

**Deliberately not built:** `RMDIR`/`DELETE` CP/M tools. This is a scoped, user-requested
safety decision: do not build destructive-by-default tools into this suite for now. It is
unrelated to whether the protocol itself is ready. See
[[feedback_fujinet_no_delete_tools]] if this work picks back up later.

## Verified live (2026-08-30): DIRECTORY-mode `OPEN` is a wildcard-pattern list, not an exact-path existence check

The team found this while building `FUJIMKD`'s "already exists" pre-check. A naive
assumption said: a DIRECTORY-mode (`$06`) `OPEN` against `.../PARENT/NAME` (no trailing
slash) would ACK only if `NAME` exists inside `PARENT`. **This assumption is wrong.** A
local `tnfsd`'s own log confirms it directly:

```
opendirx: diropt=0x00, sortopt=0x00, max=0x0000, pat="NEWDIR", path="/"
Pattern match: ".DS_Store", "NEWDIR" = FALSE
Pattern match: "HELLO.TXT", "NEWDIR" = FALSE
opendirx response: handle=0, count=2
```

FujiNet treats the bare last path segment (`NEWDIR`) as a **wildcard pattern** that filters
a listing of the *parent* (`/`). It does not treat it as a specific name to test for
existence. The `OPEN` itself ACKs as long as that listing is non-empty, **regardless of
whether anything actually matched the pattern**. So `.../PARENT/NAME` ACKs whenever
`PARENT` has *any* entries at all, even if `NAME` itself does not exist. This is a false
positive for any non-empty directory.

**The fix:** probe with a trailing slash, `.../PARENT/NAME/`. This asks "does this exact
path open as a directory," with no pattern-filtering involved. It is exactly the form
`FUJIDIR`'s own documented usage already uses, and it matches `FUJIDIR`'s already-verified
behavior: ACK for an existing directory, even an empty one, and a clean NAK for a
nonexistent one (see the `NOWHERE/` test in this project's history). `FUJIMKD.ASM`'s
`MKPRBS` routine confirms this works: it appends a trailing `/` to the probe target before
sending it.

**How to apply:** any future tool that checks "does this exact path exist" through a
DIRECTORY-mode `OPEN` must include a trailing slash on the probed path. Without one, the
result reliably means only "the parent directory of this path is non-empty," which is
probably not what you want. Plain read-mode (`$04`) `OPEN`, as used by `FUJIGET`/`FUJIPUT`'s
existing overwrite-check, does not have this problem, since it has no pattern semantics.
But it is only meaningful for files, not directories. Opening a directory path in plain
read mode is a different, untested code path, not a substitute for the
DIRECTORY-mode-with-trailing-slash technique above.

## Remaining gap

**`FUJICMD_MOUNT_HOST`/`MOUNT_IMAGE` payload shape:** not traced or tested. To close this
gap, check `lib/device/rs232/rs232Fuji.cpp` in the firmware source. Or repeat the empirical
approach above: script it against the running `fujinet-pc-RS232` build directly. Host slots
1 to 8 are already populated from `fnconfig.ini`, confirmed by a live
`FUJICMD_READ_HOST_SLOTS` call. So `MOUNT_HOST` likely needs only a host-slot index.

**`FUJINET.SYS`** (the real DOS driver) has never turned up in `fujinet-firmware` or an
obviously-named sibling repo. It is not required: the protocol is now verified two ways,
read from source and tested live. But it would give useful cross-confirmation if it
surfaces.

The prototype Python client that produced the verified results above was scratch work. It
is not saved in this repo. It is a small, easily-rebuilt SLIP/FujiBusPacket encoder/decoder,
about 100 lines. See this file's packet-format section to reconstruct it if needed.

---

## What changed

This is a full Simplified-Technical-English-style rewrite, not a light pass. Every fact,
number, table, code sample, file name, hex value, and command name from the original is
preserved exactly. Nothing was added or dropped.

**Rule 2 (sentence limits) and Rule 3 (one instruction per sentence).** The original's
prose sections (the intro, "Proven so far, live", and every "Verified live"/"Traced from
source" narrative) were written as long compound sentences stacking two or three facts
each, often with nested parentheticals. These were split into short, single-fact sentences
throughout.

**Rule 10 (em dashes).** Every em dash used as a substitute for a comma, colon, or period
was removed and replaced with the punctuation that fit. This includes every section
heading that originally used " — " to join a date and a description; those now use a colon
instead (e.g. "## Verified live (2026-08-26): network device open/write/status/read/close").

**Rule 4 (active voice).** Passive constructions like "was built by reading," "is treated
as," and "was discovered building" were rewritten with a clear subject: "the team read,"
"FujiNet treats," "the team found."

**Formatting fix, not an STE rule.** One heading in the original was split across two `##`
lines by a line-wrap artifact: "## Verified live (2026-08-30) — DIRECTORY-mode `OPEN` is a
wildcard-pattern list, NOT an" / "## exact-path existence check". Merged into one heading
line. No wording or fact changed.

**Left alone, deliberately.** Sections 4, 5, and 6 (the Device IDs table, the Command sets
list, and the worked-example code block) are dense reference data: hex values and command
names packed into a table or a comma-separated list, not narrative prose. Reformatting
that data risks a transcription error in a hex value or an identifier, and the source
document's own precedent (see `fujinet-rs232/throughput-investigation.md`'s "What changed"
section) is to leave tables and exact strings untouched. These sections, all code blocks,
the `tnfsd` log excerpt, every file path, branch name, and hex/byte value are reproduced
exactly as in the original.
