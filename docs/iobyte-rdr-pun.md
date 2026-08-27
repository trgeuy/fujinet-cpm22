# IOBYTE, RDR:/PUN:, and sio0 unit b

`NC.COM`, `FUJIGET.COM`, `FUJIPUT.COM`, and `FUJIDIR.COM` all talk directly to `sio0` unit b's
ports (`12H`/`13H`), with no BDOS or BIOS indirection. CP/M does have a standard indirection
mechanism for a second serial-style device — `IOBYTE`, plus the `RDR:`/`PUN:` logical devices
and BDOS functions 3/4 — and on this project's own CP/M disk (`CPM22-8MB-56K.DSK`, boot banner
"56K CP/M 2.2b v1.0 For Altair 8Mb Virtual Drive"), **it genuinely reaches unit b**. This is
documented here in case anyone wants to build on it; it was investigated but deliberately not
adopted in the four tools above (see "Why this wasn't adopted" below).

## What was found

The BIOS on this disk implements the classic CP/M 2.2 generic IOBYTE dispatcher: `RDR:`'s and
`PUN:`'s BIOS jump-table entries each call a shared routine that reads `IOBYTE` (address
`0003H`), extracts the relevant 2-bit field, and uses it to index a 4-entry address table
(`TTY:`/`PTR:`/`UR1:`/`UR2:` for `RDR:`; `TTY:`/`PTP:`/`UP1:`/`UP2:` for `PUN:`) that lives
inline in the BIOS right after the dispatch call. Found by disassembling the live BIOS
(`mem_dump`/`disasm` on the running guest — BIOS base `0xC400`, found via the standard trick of
reading the `JMP WBOOT` at address `0001H`) and decoding each of the 8 target addresses:

| Logical device | Physical port |
|---|---|
| `RDR:`=`TTY:` | port `0x01` |
| `RDR:`=`PTR:` (power-on default) | port `0x11` (`sio0` unit **a** — the console) |
| `RDR:`=`UR1:` | port `0x07` |
| **`RDR:`=`UR2:`** | **port `0x13` — `sio0` unit b's data register** |
| `PUN:`=`TTY:` | port `0x00` |
| `PUN:`=`PTP:` (power-on default) | port `0x10`/`0x11` (unit a) |
| `PUN:`=`UP1:` | port `0x06`/`0x07` |
| **`PUN:`=`UP2:`** | **port `0x12`/`0x13` — `sio0` unit b**, polling the same TDRE bit (`IN 12H`/`ANI 02H`) `NC.ASM`'s own `ACOUT` checks |

**Confirmed live**, not just by reading the disassembly: with `sio0:b` temporarily pointed at
throwaway test sockets instead of `fujinet-pc-RS232`,

- `STAT RDR:=UR2:` then plain `PIP CON:=RDR:` printed a test string pushed in from the host
  side over unit b.
- `STAT PUN:=UP2:` then `PIP PUN:=CON:` sent typed text that arrived intact (after PIP's usual
  leader NULs) on a capture socket listening where unit b was pointed.

So, in principle: `BDOS` function 3 (`READER`, `C=3`) and function 4 (`PUNCH`, `C=4`) — plain
blocking single-byte calls — could replace `ACIN`/`ACOUT` directly in all four tools, once
`IOBYTE`'s `RDR:`/`PUN:` fields are set to `UR2:`/`UP2:` (either by running `STAT` first, or by
having the program poke `0003H` itself at startup).

## Why this wasn't adopted

This only works because *this specific BIOS* wires `UR2:`/`UP2:` to unit b — that is a property
of this one disk image, not a CP/M-wide guarantee. Real historical BIOSes very often left
`UR1:`/`UR2:` as stubs (paper-tape hardware was rare), and whatever BIOS the project's real
physical FujiNet RS232 adapter ends up running under is not yet known. Switching to `IOBYTE`/
BDOS now would trade one hardware assumption (fixed ports) for another (this BIOS's specific
`IOBYTE` wiring) without knowing whether the real target shares it. The decision, for now: keep
the direct port I/O, keep the two hardware-specific pieces (port equates, ACIA init) clearly
marked and easy to find and edit per program — see the main `FujiNet-CPM-Tools/README.md`'s
"Adapting to different hardware" section — and revisit `IOBYTE` if/when the real hardware's own
BIOS turns out to support it too.
