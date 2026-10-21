# Adapting the tools to other serial hardware

The tools in this repository talk to the FujiNet through an Altair 88-2SIO, unit b, at ports
`12H`/`13H`. If your FujiNet connects through a different serial board, change the source and
assemble it again. This document tells you what to change, and gives a full example: a CompuPro
Interfacer 1 in an S-100 system with a Z80 CPU.

## How the tools reach the serial port

The tools read and write **I/O ports directly**. They do not go through the BDOS or the BIOS.
This is deliberate. The BDOS console calls reach only the `CON:` device, and no BDOS call reaches
a second serial line.

So **the source is the configuration file**. CP/M's `ASM.COM` has no `INCLUDE` directive, so
each `.ASM` file has its own copy of the port settings. Change every file that you use.

| File | Port equates | UART init block | Status polls |
|---|---|---|---|
| `FUJIGET.ASM` | yes | yes | `SENDPK`, `RPWAIT`, `AI1`, `AO1`, `ACIN` |
| `FUJIPUT.ASM` | yes | yes | `SENDPK`, `RPWAIT`, `AI1`, `AO1`, `ACIN` |
| `FUJIDIR.ASM` | yes | yes | `SENDPK`, `RPWAIT`, `AI1`, `AO1`, `ACIN` |
| `FUJITYPE.ASM` | yes | yes | `SENDPK`, `RPWAIT`, `AI1`, `AO1`, `ACIN` |
| `wget/WGET.ASM` | yes | yes | `SENDPK`, `RPWAIT`, `AI1`, `AO1`, `ACIN` |
| `cpm-tnfsd/TNFSD.ASM` | yes | yes | `SENDPK`, `RPWAIT`, `AI1`, `AO1`, `ACIN` |
| `testing/NC.ASM` | yes | yes | `AO1`, `ACIN` |

## Before you start: facts about your serial board

Get these facts from the manual for your serial board. The BIOS source for your machine is also
a good source: its console and `RDR:`/`PUN:` routines use the same ports and bits.

1. The address of the **data** port and the address of the **status** port.
2. The status bit that means "a received byte is ready", and the bit that means "the
   transmitter can take a byte".
3. The **polarity** of each bit: does a set bit or a clear bit mean "ready"?
4. How the board sets its word format and baud rate: by software, or by jumpers and switches.
5. The clock speed of your CPU.

The serial line to the FujiNet must use **8 data bits, no parity, 1 stop bit**. The FujiNet
protocol sends binary data, so bit 7 must get through. A 7-bit setting (for example 7E1 or
7N2) passes ASCII text but corrupts the protocol. The baud rate of the board must match the
baud rate of the FujiNet. For the adapter side, see
[`fujinet-rs232/`](../fujinet-rs232/README.md#4-set-the-serial-baud-rate-from-the-web-ui).

## 1. The port addresses

Near the top of each `.ASM` file, after the CP/M equates:

```asm
;---- The 2SIO card, unit b ---------------------------------------------
SIOST   EQU     12H             ; status (IN) / control (OUT)
SIODT   EQU     13H             ; data, both ways
SIORST  EQU     03H
SIOCTL  EQU     15H
```

`SIOST` is the status port and `SIODT` is the data port. The defaults are the second unit of an
88-2SIO at base port `10H`: unit `a` is `10H`/`11H` (the console), unit `b` is `12H`/`13H` (the
FujiNet). The rest of each file uses only these names, not the numbers.

**Set each name from your board's manual. Do not assume an order.** On a 2SIO, the status port
is the base address and the data port is base + 1. Some boards use the opposite order. The
CompuPro Interfacer 1 puts **data** at the base address and **status** at base + 1.

If your board is another 6850-based board, the port addresses are the only change. For any
other UART, also do sections 2 and 3.

## 2. The status-register bits

Three small routines in each tool poll `SIOST` and test one bit before they move a byte:

```asm
AO1:    IN      SIOST           ; wait for transmit-ready before OUT SIODT
        ANI     02H
        JZ      AO1

ACIN:   IN      SIOST           ; wait for data-ready before IN SIODT
        ANI     01H
        JZ      ACIN
```

The other sites test the same data-ready bit:

- `RPWAIT`: waits for the first byte of a reply, with a long timeout.
- `AI1` (in `ACINT`): waits for each next byte of a reply, with a short timeout.
- `SENDPK`: before it sends a packet, reads and drops any byte already waiting.

These three came with FUJIGET v1.7, FUJIPUT v1.5, FUJIDIR v1.7, WGET v1.3 and TNFSD v0.5
(2026-10-13; `RPWAIT` was in the client tools before). `ACIN` is no longer called in these
files, but it is still there: change it too. `NC.ASM` has only `AO1` and `ACIN`. See the table
above for which routines each file has.

`ANI 01H` tests bit 0: the 6850's RDRF flag (receive data register full). `ANI 02H` tests bit 1:
the 6850's TDRE flag (transmit data register empty). These bit positions belong to the 6850
chip.

If your board uses a different UART, find its two ready bits in its datasheet. Change the mask at
every `IN SIOST` site in the table above. Do not leave the 6850 masks on a different UART. The
program then polls the wrong bit: it waits forever, or it reads a byte that is not there.

**Check the polarity too.** The 6850 is active-high: a set bit means "ready", so the code jumps
back with `JZ`. Some UARTs are active-low. For example, the COM2502 on the MITS 88-SIO shows
"ready" with a **clear** bit. On a chip like that, swap the jump after the mask at every site
as well: `JZ` becomes `JNZ`, and `JNZ` becomes `JZ`. (`AO1` and `ACIN` jump back with `JZ`;
`RPWAIT` and `AI1` jump out with `JNZ`; `SENDPK` jumps on with `JZ`.)

## 3. The UART initialization

A few lines into `START:`, before the program uses the port:

```asm
        MVI     A,SIORST        ; the ACIA out of reset...
        OUT     SIOST
        MVI     A,SIOCTL        ; ...and into a real operating mode
        OUT     SIOST
```

These four lines are for the **6850 ACIA** only. On a 6850, the program sets the clock divide,
the word format, and the RTS and interrupt bits. `03H` is the master reset. `15H` (`00010101`)
selects divide-by-16, 8N1, and no interrupts.

**If your board sets its format with jumpers or switches, or uses a different chip, delete these
four lines.** Do not write 6850 control bytes to a port that is not a 6850. On another board,
the same bytes can do something else. The worked example below shows a case.

If your board is a 6850 at a different baud rate or word format, change `15H` instead. The two
low bits select the clock divide. The next three bits select the word format. The top three bits
control RTS and the two interrupt-enable bits. A 6850 datasheet has the full table.

## 4. The response-timeout budget

`TOOUTR`, near the port equates, sets how long a tool waits for a reply. When the time runs out,
the tool reports `destination server not responding`. `TOOUTR` counts busy-wait loops, not real
time, so the wait gets shorter on a faster CPU. On a 2 MHz 8080 it is about 15 to 20 seconds.
Change it only if the wait is wrong for your machine.

## 5. Assemble the changed files

Use CP/M's own assembler on the CP/M machine, or on an emulator such as `altairsim`:

```
ASM FUJIGET
LOAD FUJIGET
```

`ASM` must show no error lines. `LOAD` must show `FIRST ADDRESS 0100`, not `0000`. Before you
copy an `.ASM` file to CP/M, check its line endings. The files in this repository already use
CR LF. Do not convert them a second time: doubled CR characters make `ASM` drop lines and still
show no error.

## 6. Get the first tool onto the machine

After FUJIGET works, use it to get the other tools over the network. To get FUJIGET itself onto a
machine with no file-transfer program, type its `.HEX` file into PIP through the console:

1. On the CP/M machine, start PIP with the console as the source:

   ```
   PIP B:FUJIGET.HEX=CON:
   ```

2. From your terminal program, send the `.HEX` file as plain text, with its CR LF line endings.
   Do not send the Ctrl-Z characters at the end of the file.
3. Pace the characters if your console drops them. On the example machine below, 20 ms after each
   character and 100 ms after each line worked.
4. Send one Ctrl-Z. PIP closes the file and returns to the `A>` prompt.
5. Make the `.COM` file:

   ```
   LOAD B:FUJIGET
   ```

PIP echoes each character that it receives. Compare the echo with what you sent, to find a
dropped character at once. `LOAD` also checks the checksum of every record. A bad record gives
a `LOAD` error, not a damaged `.COM` file.

---

## Worked example: CompuPro Interfacer 1

This example is a 1982 S-100 system: a Digicomp Pascal-100 boardset (Z80 CPU at about 3 to
3.5 MHz), CP/M 2.2, and two 8" floppy drives. A CompuPro Interfacer 1 has two serial channels.
Channel A is the console. A modem used channel B before, so the cables and the RS-232 wiring of
channel B were known good. The FujiNet RS232 adapter now connects to channel B at 19200 baud.

### The facts about the board

The Interfacer 1 uses an S1602-family UART (the AY-5-1013 type), not a 6850. The board manual
and the machine's own CBIOS gave these facts:

| Fact | Interfacer 1, channel B | 88-2SIO, unit b |
|---|---|---|
| Data port | `02H` (base address) | `13H` (base + 1) |
| Status port | `03H` (base + 1) | `12H` (base address) |
| "Received byte ready" bit | bit 1 (DAV), `02H` | bit 0 (RDRF), `01H` |
| "Transmitter ready" bit | bit 0 (TBMT), `01H` | bit 1 (TDRE), `02H` |
| Polarity | active-high | active-high |
| Word format | traces on the board, set at power-up | software (`SIOCTL`) |
| Baud rate | DIP switch S1 (positions 5 to 8 for channel B) | jumpers |

The two ready bits are in **swapped positions** compared with the 6850. Both chips are
active-high, so the `JZ` instructions stay the same.

### The changes

These are the only changes, in each of the four tool files:

```diff
-SIOST   EQU     12H
-SIODT   EQU     13H
+SIOST   EQU     03H
+SIODT   EQU     02H

-        MVI     A,SIORST        ; the ACIA out of reset...
-        OUT     SIOST
-        MVI     A,SIOCTL        ; ...and into a real operating mode
-        OUT     SIOST

 RPWAIT: IN      SIOST
-        ANI     01H
+        ANI     02H

 AO1:    IN      SIOST
-        ANI     02H
+        ANI     01H

 ACIN:   IN      SIOST
-        ANI     01H
+        ANI     02H
```

**Why the init lines must go.** On the Interfacer 1, an `OUT` to the status address writes the
**control** port. Each bit that you write as 1 flips one power-up setting. The 6850 bytes
(`03H`, then `15H`) would flip the receive-interrupt enable, the DTR line, and the number of
stop bits. To return to the power-up settings, write `00H`. The board manual's own test
program does this.

### What we did

1. Made the changes in copies of the four `.ASM` files and assembled them in `altairsim`.
2. Checked each `.COM` file: every `IN` and `OUT` uses port `02H` or `03H`, and no 6850 init is
   left. Each file is the same size as the 2SIO build.
3. Set S1 positions 5 to 8 to OFF (19200 baud). Set the FujiNet to 19200 in its web UI, then
   restarted the FujiNet.
4. Typed `FUJIGET.HEX` into PIP through the console (section 6 above). `LOAD` gave the same
   addresses and record count as the emulator build.
5. Used FUJIGET to get the other three tools from a TNFS server.

### The results

| Tool | Test | Result |
|---|---|---|
| FUJIGET | A 26-byte text file from a TNFS server | byte-exact |
| FUJIGET | Three `.COM` files from a TNFS server | correct record counts |
| FUJIDIR | A full directory listing from a TNFS server | correct |
| FUJIPUT | A 5900-byte text file, text mode, to a TNFS server | byte-exact |
| WGET | A file with a mixed-case name from an HTTP server | byte-exact, case kept |

`TNFSD.ASM` and `testing/NC.ASM` need the same changes. They were not tested on this board.

### Problems we found

- **The FujiNet ignored us at first.** The web UI showed 19200, but the adapter did not answer
  until it was restarted. The tool reported `destination server not responding`. The status port
  showed no received byte and no framing error.
- **A 7-bit check is worth one minute.** A working console does not prove 8 data bits. We used
  DDT to send the bytes `01H`, `81H` and `83H` out of channel A. The terminal showed exactly
  those three bytes, so the channel uses 8 data bits. With 7 data bits, at least one byte
  changes.
