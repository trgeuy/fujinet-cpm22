# The FujiNet RS232 wire protocol (reverse-engineered from source)

Not a conversion of a PDF — there is no manual for this. `Reference/fujinet/connecting-an-emulator-to-fujinet-pc.md` and `fujinet-programmers-guide-adam.md` both document **AdamNet**, a different, packet-addressed bus for the Coleco ADAM. Altair/CP/M is RS232, a plain byte stream, and no manual for that side exists in `Documentation/`. This file was built by reading the actual `fujinet-firmware` source (`lib/bus/rs232/`, `lib/device/rs232/`, `include/fujiDeviceID.h`, `include/fujiCommandID.h`) against a running `fujinet-pc-RS232` v1.6.2-dev nightly build, the same way the AdamNet manual describes having been sourced from firmware, not secondary docs.

**Status: verified for framing/checksum/device-command tables (read from source verbatim). Medium confidence on exact per-command payload shape beyond network open/read/write/status — see Gaps, below, before writing code against `MOUNT_HOST`/`MOUNT_IMAGE` or `NETCMD_OPEN`'s URL argument.**

## Proven so far, live

`altairsim`'s `2sio` board, unit `b`, `CONNECT`ed to `socket:localhost:1985` (FujiNet-PC-RS232's BOIP — Bus-over-IP — listener, the default when `fnconfig.ini`'s `[Serial] port=` is left empty) is a working raw byte pipe: an 8080 program bit-banging the 6850 ACIA (status port `BASE+2`, data port `BASE+3`) sent `AT\r` and FujiNet's log showed `Modem cmd: WRITE` / `AT Cmd: AT` — confirmed end to end.

**Ruled out:** `[CPM] cpm_enabled=1` / the `ATCPM` modem command is FujiNet **hosting its own CP/M** (RunCPM, an embedded Z80/CP/M emulator) for an Atari acting as a dumb terminal dialing in. Not related to driving FujiNet's services from a real CP/M machine — the opposite of what we want.

## 1. Entering binary/command mode: no escape string, just `0xC0`

`_rs232_process_cmd()` in `rs232.cpp` reads bytes one at a time. Anything before a `0xC0` byte appears is buffered and handed to the modem device as plain AT-command text — this is what the `AT\r` test exercised. The moment a `0xC0` byte appears, the parser switches to reading a binary `FujiBusPacket` starting there. **The SLIP frame delimiter *is* the mode switch** — there is no `AT+FUJI`-style escape command. Plain AT-modem text and binary FujiBusPackets can be freely interleaved on the same line.

## 2. Packet format — SLIP-framed `FujiBusPacket`

Outer framing is standard SLIP (RFC 1055): `0xC0 <escaped bytes> 0xC0`. Within the frame: `0xC0` → `0xDB 0xDC`, `0xDB` → `0xDB 0xDD` (`SLIP_END=0xC0`, `SLIP_ESCAPE=0xDB`, `SLIP_ESC_END=0xDC`, `SLIP_ESC_ESC=0xDD`). A full packet is exactly one SLIP frame — `readBusPacket()` reads until it has seen two `0xC0` bytes (open + close).

Decoded (post-unescape) layout — a 6-byte header, then descriptor/param bytes, then optional payload:

```c
struct fujibus_header {          // packed, 6 bytes
    uint8_t  device;              // destination device ID (§3)
    uint8_t  command;             // command byte (§3, per-device-class table)
    uint16_t length;              // little-endian; TOTAL decoded packet length, header included
    uint8_t  checksum;            // §below
    uint8_t  descr;               // first parameter-descriptor byte
};
```

- **Checksum**: over the entire decoded packet with the checksum byte itself zeroed: `chk=0; for each byte: chk += byte; chk = (chk>>8) + (chk&0xFF)` (16-bit sum, end-around carry folded to 8 bits). Verify on receipt by zeroing the checksum byte in a copy and recomputing.
- **Parameter descriptors**: pack 0–4 fixed-width params per descriptor byte. Low 3 bits (`&0x07`) index:
  `fieldSizeTable  = {0, 1, 1, 1, 1, 2, 2, 4}`
  `numFieldsTable  = {0, 1, 2, 3, 4, 1, 2, 1}`
  e.g. descriptor `2` = two 1-byte params; `6` = two 2-byte params; `7` = one 4-byte param. Bit `0x80` set means another descriptor byte follows (for >4 params, or mixed widths). The *first* descriptor byte lives in the header itself (`hdr.descr`); further ones follow immediately after the header, before the param bytes. Multi-byte param values are little-endian.
- **Payload**: whatever's left after header + descriptors + params — write data, filenames, response buffers, etc.

Full frame: `0xC0` `[device][command][length_lo][length_hi][checksum][descr]` `[addl descriptor bytes...]` `[param bytes...]` `[payload bytes...]` `0xC0`, SLIP-escaped. `length` counts decoded bytes including the 6-byte header.

## 3. Responses

FujiNet replies with its own `FujiBusPacket`: same `device` ID, `command = FUJICMD_ACK (0x06)` on success (payload = response data, if any) or `FUJICMD_NAK (0x15)` on error (no payload) — from `sendReplyPacket()`. **Exception:** if `device` was the modem device, the reply is raw bytes, not a wrapped packet (plain AT-command semantics).

## 4. Device IDs (`include/fujiDeviceID.h`, non-ADAM `#else` branch — what RS232/desktop builds use)

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

## 5. Command sets (`include/fujiCommandID.h`) — values overlap across device classes; `device` disambiguates

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

## Verified live (2026-08-26) — network device open/write/status/read/close

Confirmed end-to-end against a real `fujinet-pc-RS232` v1.6.2-dev build's BOIP port
(`localhost:1985`), using a Python prototype (SLIP encode/decode, checksum, packet
build/parse) talking to a local Python TCP echo server on `127.0.0.1:9000` (chosen over a
real internet host to keep the test self-contained):

- **`NETCMD_OPEN` payload IS the device-spec string, NUL-terminated, WITH the `Nx:` channel
  prefix** — e.g. `b"N1:TCP://127.0.0.1:9000/\x00"` — even though the packet header's
  `device` byte (`0x71`, the first network slot) already selects the channel. Params:
  `(1-byte access_mode, 1-byte translation_mode)`. Confirmed working values, cross-checked
  against the AdamNet chapter of `fujinet-programmers-guide-adam.md` (§Opening and Closing,
  same shared enum across bus backends): access mode `$04`=read, `$08`=write, `$0C`=read/write,
  `$0D`=HTTP POST, `$05`=HTTP DELETE; translation `$00`=none(binary), `$01`=CR, `$02`=LF,
  `$03`=CRLF. Tested with mode `$0C`, translation `$00` → **ACK**.
- **`NETCMD_WRITE`**: 1 param `(2-byte length)`, payload = the bytes to write. → **ACK**.
- **`NETCMD_STATUS`**: zero params. Response payload is **4 bytes**: `bytes_waiting` (u16 LE),
  `connected` (u8), `error` (u8) — confirmed both from the wire (`13 00 01 01`) and from
  FujiNet's own log line for that call: `rs232_status_channel() - BW: 19 C: 1 E: 1`. `error=1`
  is Atari-convention for "no error"/success.
- **`NETCMD_READ`**: 1 param `(2-byte length requested)`. Response payload is **exactly the
  requested length**, real data first, uninitialized/leftover buffer bytes padding the rest —
  use `STATUS`'s `bytes_waiting` to know how much of it is real, don't trust the full response
  length as "bytes received." Confirmed: requested 64, got back `ECHO:hello fujinet\n` (19
  real bytes) + 45 bytes of buffer garbage.
- **`NETCMD_CLOSE`**: zero params. → **ACK**.

This closes the two gaps below for the network-device path. **`FUJICMD_MOUNT_HOST`/
`MOUNT_IMAGE` (disk mounting via the Fuji control device, `0x70`) is still unverified** — no
live test attempted yet.

## Verified live (2026-08-27) — read-mode `NETCMD_OPEN` as an existence probe

Confirmed against a local `tnfsd` (`tnfsd/`) serving `tnfsd/share/`, driven by the same
Python SLIP/FujiBusPacket approach as above, over `fujinet-rs232`'s BOIP port. Purpose: can
a client check whether a remote file exists before opening it for write, without an
unverified command (`FUJICMD_OPEN_DIRECTORY` et al., still untested — see below)?

- **`NETCMD_OPEN` with `access_mode=$04` (read) ACKs if the target exists, NAKs if it doesn't**
  — confirmed both ways (`HELLO.TXT` present → ACK; `MISSING.TXT` absent → NAK). This is the
  same command already verified for write above, just the read access-mode value.
- **`NETCMD_CLOSE` ACKs cleanly after either outcome** — including right after a NAK'd open,
  where there is no open handle to close. Safe to send unconditionally.
- **No side effects on the following real open**: a full single-connection sequence —
  probe-open read (NAK, file absent) → close (ACK) → open write (ACK) → write (ACK) → close
  (ACK) → probe-open read again (now ACK, file exists) → close (ACK) — ran clean start to
  finish. Probing first does not disturb the write that follows it.

**Consequence**: an overwrite-confirmation check for a tool like `FUJIPUT.COM` doesn't need
`FUJICMD_OPEN_DIRECTORY`/`READ_DIR_ENTRY` at all (which remain unverified, below) — it can
open read-only first, ACK/NAK tells you existence, close, then open for real. This only
answers "does a file/URL exist" for backends where read-open has that meaning (TNFS, SD,
HTTP GET); it says nothing for a raw `TCP://` stream, which has no file-existence concept.

## Traced from source, then verified live (2026-08-30) — `NETCMD_MKDIR`/`RMDIR` payload shape

Traced directly from `lib/device/rs232/network.cpp` (`rs232Network::process_fs`,
`create_devicespec`) on GitHub — same code path handles `NET_MKDIR`, `NET_RMDIR`,
`NET_RENAME`, `NET_DELETE`, `NET_LOCK`, `NET_UNLOCK`, so this shape applies to all of them, not
just MKDIR:

- **Payload = the device-spec string, NUL-terminated, WITH the `Nx:` channel prefix** —
  identical convention to `NETCMD_OPEN`'s payload (`create_devicespec` calls the exact same
  `SYSTEM_BUS.transaction_get(devicespecBuf, ...)` read used by open). E.g. a create-folder
  call would send `b"N1:TNFS://host/newfolder\x00"` as the packet payload with command byte
  `NET_MKDIR` (`0x2A`).
- **Params: 0 or 1**, unlike OPEN's fixed 2 — `process_fs` reads `param(0)` as an access mode
  only `if packet.paramCount() > 0`, defaulting to `0` otherwise. Untested whether a real
  client needs to supply it; sending zero params is plausible.
- Each of these commands re-parses its own devicespec into a fresh protocol instance (closing
  any protocol left open by a prior `OPEN`) — they are not scoped to an already-open channel,
  so no prior `OPEN` is required before calling `MKDIR`.
- The actual directory creation is `fs->mkdir(url)` — routed through whichever
  `NetworkProtocolFS`-derived backend the URL scheme resolves to (TNFS, SD, etc; NOT valid for
  a raw `TCP://` stream, which isn't a filesystem protocol). Returns `FUJI_ERROR::NONE` on
  success → `transaction_success()`; anything else → `transaction_error()` (no further error
  detail beyond the generic ACK/NAK envelope from this code path alone).

**Confirmed live, same day, `CPM Tools/FUJIMKD.ASM`/`.COM`**: 0 params, NUL-terminated
`Nx:`-prefixed devicespec payload, exactly as traced above — no access-mode param needed.
Tested against local `tnfsd` (create → ACK; duplicate create → clean NAK; nested subdirectory
create → ACK, all confirmed at the actual filesystem level under `tnfsd/share/`, not just via
`FUJIDIR`) and against a real internet TNFS server, `tnfs.mitsaltair.com` (same create/
duplicate-NAK behavior, confirmed via `FUJIDIR` listing afterward). `FUJIMKD` sends a `CLOSE`
after the `MKDIR` request even though no persistent channel was opened — `rs232_close()`
gracefully no-ops when `protocol` is null, so this is safe either way and cleans up the
freshly-instantiated protocol object `process_fs` leaves behind.

**Deliberately not built**: `RMDIR`/`DELETE` CP/M tools — a scoped, user-requested safety
decision (not building destructive-by-default tools into this suite for now), unrelated to
protocol-readiness. See [[feedback_fujinet_no_delete_tools]] if picking this back up later.

## Remaining gap

**`FUJICMD_MOUNT_HOST` / `MOUNT_IMAGE` payload shape** — not traced or tested. Check
`lib/device/rs232/rs232Fuji.cpp` in firmware source, or replicate the empirical approach
above: script it against the running `fujinet-pc-RS232` build directly (host slots 1–8 are
already populated from `fnconfig.ini` — confirmed via a live `FUJICMD_READ_HOST_SLOTS`
call — so `MOUNT_HOST` likely just needs a host-slot index).

**`FUJINET.SYS`** (the real DOS driver) was never located in `fujinet-firmware` or an
obviously-named sibling repo — not required (the protocol has now been verified two ways:
read from source, and tested live) but would be useful cross-confirmation if it surfaces.

The prototype Python client that produced the verified results above was scratch work, not
saved in this repo — it's a small, easily-rebuilt SLIP/FujiBusPacket encoder/decoder
(~100 lines); see this file's packet-format section to reconstruct it if needed.
