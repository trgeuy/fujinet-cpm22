# WGET — fetch a file through FujiNet's N: device, URL prompted at runtime

```
WGET file.ext
URL: <typed or pasted here>
```

Pass **only the local target filename** on the command line. `WGET` then prints a
`URL: ` prompt and reads the URL there — do not put the URL on the command line, that's
the whole point (see "Why prompt instead of a command-line argument" below).

Example — a real, case-sensitive HTTPS path, the case this tool exists for:

```
A0>WGET MEMTEST.ASM
URL: N1:HTTPS://deramp.com/downloads/altair/software/utilities/other/MEMTEST.ASM
WGET: opening N1:HTTPS://deramp.com/downloads/altair/software/utilities/other/MEMTEST.ASM
Open OK. Receiving...

30 records received.
```

Typed at `FUJIGET`'s command line instead, the CCP would uppercase that whole path before
`FUJIGET` ever saw it, 404'ing against deramp.com's case-sensitive server — see below for why
that's not just a cosmetic difference.

Same `Nx:` channel prefix and full scheme as [`FUJIGET`](../README.md) — `TNFS://`,
`HTTP://`, `HTTPS://`, `TCP://`, and whatever else FujiNet's `N:` device understands.
Once the URL is typed in, everything else is `FUJIGET`'s own engine unchanged: the
overwrite check, the OPEN/READ/CLOSE loop, in-place `Received NNNN KB...` progress, and
the parent-probe diagnosis on failure. See the main README and
[`Reference/fujinet/rs232-protocol.md`](../docs/rs232-protocol.md) for how all of that
works.

## Why prompt instead of a command-line argument

CP/M's CCP uppercases the entire command tail before any program — `WGET` included —
ever sees it. That's a CCP-level behavior; a program has no way to opt out of it for
text typed on the command line. Harmless against TNFS (this project already works
around it server-side — see `tnfsd-server-setup/tnfs-case-fix.sh`), but it silently
breaks against any **case-sensitive** remote.

Confirmed live against a real HTTPS server (deramp.com): `FUJIGET N1:HTTPS://
deramp.com/downloads/altair/software/utilities/other/MEMTEST.ASM` arrived at FujiNet
as `N1:HTTPS://DERAMP.COM/DOWNLOADS/.../MEMTEST.ASM` — all-uppercase, since that's
what the CCP handed the program. That path doesn't exist on deramp.com's
case-sensitive server, so it 404'd — and FujiNet's HTTP backend doesn't check the
HTTP status code before handing back whatever body came with the response, so
`FUJIGET` reported a perfectly normal "10 records received" for what was actually a
1237-byte 404 error page, not the real 3721-byte file. No error, just silently wrong
data.

BDOS function 10 (Read Console Buffer) — what `WGET` uses to read the URL — is a raw
line-editing read with no case-conversion of its own; it's not the CCP's parser and
never sees the command line at all. Prompting for the URL at runtime instead of typing
it as an argument sidesteps the CCP entirely, so a mixed-case URL survives intact.
Confirmed live: the same deramp.com path, typed at `WGET`'s prompt in its real
mixed-case form, fetched the genuine file — verified byte-identical to a direct
download.

**Known caveat, inherited from FUJIGET, not fixed by this tool:** `WGET` fixes the
*case-folding* problem, but FujiNet's HTTP backend still doesn't check the HTTP status
code on a plain GET. A `404`, `403`, or any other non-2xx response still gets streamed
back and saved as if it were the real file, with no error reported. Worth checking
what actually arrived (size, a quick `TYPE`) rather than trusting "records received"
alone, especially against a URL you haven't fetched before.

## Getting the URL: copy it from a browser, don't retype it

The easiest way to get a URL into the prompt with its case intact is to never type it
by hand at all: browse to the file, right-click it (or the link to it), choose **Copy
Link** (or **Copy Link Address**), and paste that at the `URL: ` prompt — prefixed with
`N1:` (or whichever channel FujiNet is on). This is also just less error-prone than
transcribing a long URL by eye, independent of the case issue.

## Why there's no directory-listing counterpart

FujiNet's HTTP backend doesn't implement directory-mode `OPEN` the way it does for
TNFS — confirmed live: pointing `FUJIDIR` at a plain HTTP server (`FUJIDIR
N1:HTTP://host:8080/`) fails cleanly with `parent path does not exist`, the same
response you'd get probing a URL scheme that has no directory concept at all (like a
raw `TCP://` stream). There's nothing on the other end to list, so a `WGETDIR` would
have nothing to talk to. If FujiNet ever adds real HTTP directory listing, this is
the place that gap would get filled.

## Getting it onto your CP/M disk

Same as the main three tools — see the main README's "Get the tools onto your CP/M
disk" section. `WGET.HEX` (Intel hex) and `WGET.COM` (ready to run) are both here,
alongside `WGET.ASM` (source, CRLF line endings, assembles with CP/M's own
`ASM`/`LOAD`, no cross-assembler).

## Status

Built and verified against the emulated `fujinet-pc-RS232` build on macOS, HTTP and
HTTPS only — real hardware, and other schemes (TNFS, TCP), inherit `FUJIGET`'s own
existing testing but haven't been separately re-verified through `WGET`'s prompt path.
Not part of the packaged release zip — like `altairsim/`, `tnfsd-server-setup/`, and
`fujinet-rs232/`, this is repo-only; get it straight from here.
