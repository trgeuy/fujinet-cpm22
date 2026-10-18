# WGET: fetch a file through FujiNet's N: device, with the URL prompted at runtime

```
WGET file.ext [/O]
URL: <typed or pasted here>
```

Pass **only the local target filename** on the command line. `WGET` then prints a
`URL: ` prompt and reads the URL there. Do not put the URL on the command line: that
is the whole point (see "Why prompt instead of a command-line argument" below).

Example: a real, case-sensitive HTTPS path. This is the case this tool exists for.

```
A0>WGET MEMTEST.ASM
URL: N1:HTTPS://deramp.com/downloads/altair/software/utilities/other/MEMTEST.ASM
WGET: opening N1:HTTPS://deramp.com/downloads/altair/software/utilities/other/MEMTEST.ASM
Open OK. Receiving...

30 records received.
```

If you type the URL at `FUJIGET`'s command line instead, the CCP uppercases the
whole path before `FUJIGET` sees it. This causes an HTTP 404 error against
deramp.com's case-sensitive server. See below for why this is not just a cosmetic
difference.

`WGET` uses the same `Nx:` channel prefix and full scheme as
[`FUJIGET`](../README.md): `TNFS://`, `HTTP://`, `HTTPS://`, `TCP://`, and any other
scheme FujiNet's `N:` device supports. After you type the URL, `WGET` uses
`FUJIGET`'s own engine, unchanged. This engine does the overwrite check, the
OPEN/READ/CLOSE loop, the in-place `Received NNNN KB...` progress display, and the
parent-probe diagnosis on failure. See the main README and
[`Reference/fujinet/rs232-protocol.md`](../docs/rs232-protocol.md) for how this
works.

## Why prompt instead of a command-line argument

CP/M's CCP uppercases the entire command tail before any program sees it,
including `WGET`. This is CCP-level behavior. A program cannot opt out of it for
text typed on the command line. This is harmless against TNFS: this project
already works around it on the server side (see
`tnfsd-server-setup/tnfs-case-fix.sh`). But it silently breaks against any
**case-sensitive** remote.

The team confirmed this live against a real HTTPS server, deramp.com. They typed
`FUJIGET N1:HTTPS://deramp.com/downloads/altair/software/utilities/other/MEMTEST.ASM`.
This command arrived at FujiNet as
`N1:HTTPS://DERAMP.COM/DOWNLOADS/.../MEMTEST.ASM`, all uppercase, because that is
what the CCP handed to the program. That path does not exist on deramp.com's
case-sensitive server, so the request failed with an HTTP 404 error. The FUJIGET of
that time (v1.6 and older) did not read FujiNet's error code. So it reported a normal
"10 records received" for what was really a 1237-byte 404 error page, not the real
3721-byte file. The result: no error message, just silently wrong data. FUJIGET v1.7
and WGET v1.3 read the code and stop with `error 170 (not found)` (see below).

`WGET` uses BDOS function 10, Read Console Buffer, to read the URL. This is a raw
line-editing read with no case conversion of its own. It is not the CCP's parser,
and it never sees the command line at all. Prompting for the URL at runtime,
instead of taking it as an argument, sidesteps the CCP entirely. A mixed-case URL
survives intact. The team confirmed this live: they typed the same deramp.com path
at `WGET`'s prompt, in its real mixed-case form, and it fetched the real file. They
verified the file was byte-identical to a direct download.

**HTTP errors (v1.3).** FujiNet puts the HTTP result in its error code, and WGET
checks that code. A `404` stops WGET with `WGET: FujiNet reported error 170 (not
found). Nothing was saved.`; a `401` or `403` gives error 212; a `5xx` gives error 215
(server error). WGET writes to a temporary `.$$$` file and replaces the old file only
after a clean end, so a failed fetch leaves an existing file as it was. Older WGET
versions (v1.2 and before) did not check the code and saved the error page as the file.

## Replacing a file without asking: `/O` (v1.4)

If `file.ext` already exists, `WGET` asks `file.ext exists. Replace? (Y/N)` after it reads
the URL. Add `/O` after the filename to replace the file without that question:

```
WGET FUJIDIR.ASM /O
```

`/O` is meant for scripts. A script cannot know ahead of time whether the question will
come, so it cannot answer it. `/O` changes nothing else: the data still goes to the
temporary `.$$$` file first, so a failed fetch with `/O` still leaves the old file as it
was. `/O` must come after the filename. Anything else after the filename stops `WGET` with
`WGET: the only switch is /O (replace without asking).`

Use `EX.COM` to run such a script, not `SUBMIT` or `XSUB`. `SUBMIT` and `XSUB` uppercase
every line, so the URL lines lose their case. With `/O`, each fetch is two lines, the
command and the URL, whether or not the file is already on the disk:

```
WGET FUJIDIR.ASM /O
https://raw.githubusercontent.com/trgeuy/fujinet-cpm22/main/FUJIDIR.ASM
WGET FUJIGET.ASM /O
https://raw.githubusercontent.com/trgeuy/fujinet-cpm22/main/FUJIGET.ASM
WGET FUJIPUT.ASM /O
https://raw.githubusercontent.com/trgeuy/fujinet-cpm22/main/FUJIPUT.ASM
WGET WGET.ASM /O
https://raw.githubusercontent.com/trgeuy/fujinet-cpm22/main/wget/WGET.ASM
```

## Getting the URL: copy it from a browser, don't retype it

The easiest way to keep the URL's case intact is to never type it by hand. Browse
to the file. Right-click it, or the link to it. Choose **Copy Link** (or **Copy
Link Address**). Paste that at the `URL: ` prompt, prefixed with `N1:` (or
whichever channel FujiNet is on). This is also less error-prone than typing a long
URL by eye, apart from the case issue.

## Why there's no directory-listing counterpart

FujiNet's HTTP backend does not implement directory-mode `OPEN` the way it does
for TNFS. The team confirmed this live: pointing `FUJIDIR` at a plain HTTP server
(`FUJIDIR N1:HTTP://host:8080/`) fails cleanly with `parent path does not exist`.
This is the same response you get when you probe a URL scheme with no directory
concept at all, like a raw `TCP://` stream. There is nothing on the other end to
list, so a `WGETDIR` tool would have nothing to talk to. If FujiNet ever adds real
HTTP directory listing, this is where the gap gets filled.

## Getting it onto your CP/M disk

This works the same way as the main three tools. See the main README's "Get the
tools onto your CP/M disk" section. `WGET.HEX` (Intel hex) and `WGET.COM` (ready to
run) are both here. `WGET.ASM` (source, with CRLF line endings) is here too. It
assembles with CP/M's own `ASM`/`LOAD`; no cross-assembler is needed.

## Status

The team built and verified `WGET` against the emulated `fujinet-pc-RS232` build
on macOS, for HTTP and HTTPS. v1.3 was also tested on a real Altair 8800c with a
real FujiNet RS232 adapter (2026-10-13): a mixed-case HTTP path, byte-exact. v1.4's
`/O` was tested (2026-10-18) in `altairsim` with a real FujiNet adapter on its serial port,
over HTTPS: with and without `/O`, a new and an existing file, and a 404 with `/O`. Other
schemes (TNFS, TCP) inherit `FUJIGET`'s own testing, but were not re-verified
through `WGET`'s prompt path. `WGET` is not part of the packaged
release zip. Like `altairsim/`, `tnfsd-server-setup/`, and `fujinet-rs232/`, it is
repo-only: get it straight from here.
