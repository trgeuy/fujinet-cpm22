# WGET: fetch a file through FujiNet's N: device, with the URL prompted at runtime

```
WGET file.ext
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
case-sensitive server, so the request failed with an HTTP 404 error. FujiNet's HTTP
backend does not check the HTTP status code before it returns the response body.
So `FUJIGET` reported a normal "10 records received" for what was really a
1237-byte 404 error page, not the real 3721-byte file. The result: no error
message, just silently wrong data.

`WGET` uses BDOS function 10, Read Console Buffer, to read the URL. This is a raw
line-editing read with no case conversion of its own. It is not the CCP's parser,
and it never sees the command line at all. Prompting for the URL at runtime,
instead of taking it as an argument, sidesteps the CCP entirely. A mixed-case URL
survives intact. The team confirmed this live: they typed the same deramp.com path
at `WGET`'s prompt, in its real mixed-case form, and it fetched the real file. They
verified the file was byte-identical to a direct download.

**Known caveat, inherited from FUJIGET, not fixed by this tool:** `WGET` fixes the
*case-folding* problem. But FujiNet's HTTP backend still does not check the HTTP
status code on a plain GET. A `404`, `403`, or any other non-2xx response still
streams back and saves as if it were the real file, with no error reported. Check
what actually arrived: check the size, or run a quick `TYPE`. Do not trust "records
received" alone, especially against a URL you have not fetched before.

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
on macOS, for HTTP and HTTPS only. Real hardware, and other schemes (TNFS, TCP),
inherit `FUJIGET`'s own existing testing. But the team has not separately
re-verified them through `WGET`'s prompt path. `WGET` is not part of the packaged
release zip. Like `altairsim/`, `tnfsd-server-setup/`, and `fujinet-rs232/`, it is
repo-only: get it straight from here.

---

## What changed

Full Simplified-Technical-English-style rewrite, not a light pass. Every fact,
number, filename, command, code block, and link from the original is preserved
exactly. Nothing was added or dropped.

**Rule 2 (sentence limits).** The original runs long, comma-chained sentences
covering several ideas at once (the CCP-uppercasing explanation, the deramp.com
walkthrough, the directory-listing paragraph). Each was split into short,
single-idea sentences, almost all under 20 words.

**Rule 10 (em dashes).** Every em dash in the original was removed and replaced
with a period or colon, depending on what it was doing in that sentence. None
remain.

**Rule 4 (active voice).** Passive or agentless constructions ("is a raw
line-editing read," "confirmed live") were kept only where "the team" is the true,
useful subject; added "the team" as the actor in several sentences that described
a test someone actually ran (e.g. "The team confirmed this live against a real
HTTPS server").

**Rule 9 (word substitution).** *genuine* → *real* (both occurrences); *doesn't*,
*don't*, *hasn't*, *haven't*, *that's*, *there's*, *isn't*, *you'd*, *you've* all
expanded to their full forms.

**Left alone.** Every code block, command example, file name, and the exact
uppercased/mixed-case URL strings that are the whole point of the document are
reproduced byte-for-byte. `case-folding` is kept as the project's own established
term for the bug class, not touched. Section headings are unchanged.
