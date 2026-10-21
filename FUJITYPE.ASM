;-----------------------------------------------------------------------
; FUJITYPE.COM v1.0 -- print a text file on FujiNet's printer.
;
;       FUJITYPE file.ext               e.g.  FUJITYPE NOTES.TXT
;
; The paper copy of TYPE: FUJITYPE NOTES.TXT prints the text that
; TYPE NOTES.TXT shows. It reads the CP/M file up to the first ^Z and
; sends it to FujiNet's printer device (40H) with PRINTER_WRITE (57H).
; The printer has no OPEN, CLOSE or URL: each WRITE adds its text to the
; current document, and FujiNet's web page gives the document at /print.
; See docs/rs232-protocol.md, "the printer
; device", and the RS-232 FujiNet User's Manual, chapter 11.
;
;-----------------------------------------------------------------------
; ONE PRINTED LINE IN EACH WRITE -- the work-around for fujinet-firmware
; issue #2043. The PDF printers (Epson 80 and the others) start a new
; page only between two WRITE packets, never inside one, so a packet of
; several lines can print below the bottom of the page. FUJITYPE keeps
; the line it is building in LINE and sends it when the line ends: at
; LF, or at FF (a new page). A line has room for LINMAX bytes; a line
; that is longer (only possible with many BS or CR in it) is sent in
; parts. Each WRITE stays well under the firmware's 255-byte limit.
;
; A LINE LONGER THAN 80 CHARACTERS GOES ON TO THE NEXT LINE. When an
; 81st character comes, FUJITYPE first ends the printed line with CR LF
; and sends it, then puts the character at column 1 of the next one. No
; character is dropped. A line of exactly 80 characters gets no extra
; blank line, because the split happens only when one more comes.
;
; THE COLUMN IS THE ONE TYPE KEEPS. TYPE prints through the BDOS, which
; expands a TAB to the next column of 8 (1, 9, 17, ...). FUJITYPE does
; the same, so a printout has the layout of the screen and its column
; count is right. CR sets the column back to 1, BS takes one off, and a
; control character or a byte above 7EH goes to the printer as it is,
; with no column.
;
; AND BDOS CLOBBERS EVERY REGISTER (A,B,C,D,E,H,L -- only SP survives).
;-----------------------------------------------------------------------
; Assemble it INSIDE the machine:
;
;       ASM FUJITYPE            -> FUJITYPE.HEX
;       LOAD FUJITYPE           -> FUJITYPE.COM
;-----------------------------------------------------------------------

        ORG     100H

;---- CP/M ---------------------------------------------------------------
BDOS    EQU     0005H
TAIL    EQU     0080H
TFCB    EQU     005CH           ; the CCP's own parse of the file name

CONOUT  EQU     2
DIRIO   EQU     6
PRSTR   EQU     9

FOPEN   EQU     15
FREAD   EQU     20              ; read sequential
FSETDMA EQU     26

BS      EQU     08H
TAB     EQU     09H
LF      EQU     0AH
FF      EQU     0CH
CR      EQU     0DH
CTRLC   EQU     03H
CPMEOF  EQU     1AH             ; ^Z

RECLEN  EQU     128

;---- The 2SIO card, unit b ---------------------------------------------
SIOST   EQU     12H
SIODT   EQU     13H
SIORST  EQU     03H
SIOCTL  EQU     15H

;---- How long RECVPK waits for a reply before giving up -----------------
; TOOUTR outer passes, each a full 16-bit busy-wait -- roughly 15-20
; real seconds on a stock 2MHz Altair, but this is a rough CPU-cycle
; count, not a calibrated timer: it scales with actual clock speed
; (faster hardware times out sooner, slower hardware later). Raise or
; lower it per your hardware if the default feels wrong.
TOOUTR  EQU     10

;---- The FujiNet RS232 wire protocol (docs/rs232-protocol.md)
PRTDEV  EQU     40H             ; the printer
CMDWRIT EQU     57H             ; PRINTER_WRITE: no params, payload = text
ACKCMD  EQU     06H

SLPEND  EQU     0C0H
SLPESC  EQU     0DBH
SLPEEND EQU     0DCH
SLPEESC EQU     0DDH

PWIDTH  EQU     80              ; characters on one printed line
LINMAX  EQU     128             ; bytes in LINE (one WRITE's payload)
RXSIZE  EQU     32              ; RXBUF: a printer ACK carries no data
NAMLEN  EQU     20              ; room for the file name, as typed

;=======================================================================
; MAIN
;=======================================================================
START:  LXI     SP,STACK

        LDA     TFCB+1          ; no file name -- the usage message
        CPI     ' '
        JZ      USAGE

        LXI     H,TFCB+1        ; the CCP makes a * into ?s -- refuse
        MVI     B,11            ; both: TYPE prints one file, and so
WILD1:  MOV     A,M             ; do we
        CPI     '?'
        JZ      EWILD
        INX     H
        DCR     B
        JNZ     WILD1

        CALL    INIFCB          ; the CCP's FCB at 5CH -> ours
        CALL    PARSE           ; the name as typed -> NAME, for messages

        LXI     D,FCB
        MVI     C,FOPEN
        CALL    BDOS
        CPI     0FFH
        JZ      ENOCPM

        XRA     A
        STA     FCB+32          ; BDOS OPEN does not promise to clear cr

        LXI     D,BUF
        MVI     C,FSETDMA
        CALL    BDOS            ; where BDOS puts each record it reads

        MVI     A,SIORST
        OUT     SIOST
        MVI     A,SIOCTL
        OUT     SIOST

        CALL    SAYSTRT

        XRA     A
        STA     COL
        STA     LLEN
        LXI     H,0
        SHLD    LINES

;-----------------------------------------------------------------------
; RDLOOP -- poll for a Ctrl-C abort, read one CP/M record, and give each
; byte up to the first ^Z to PUTCH. The end of the file ends it too.
;-----------------------------------------------------------------------
RDLOOP: MVI     E,0FFH
        MVI     C,DIRIO
        CALL    BDOS
        ORA     A
        JZ      RDGO
        CPI     CTRLC
        JZ      ABORT

RDGO:   LXI     D,FCB
        MVI     C,FREAD
        CALL    BDOS
        ORA     A
        JNZ     PDONE           ; 1 = EOF; anything else is also an end

        LXI     H,BUF
        MVI     B,RECLEN
RD1:    MOV     A,M
        CPI     CPMEOF
        JZ      PDONE           ; the end of the text
        PUSH    H
        PUSH    B
        CALL    PUTCH
        POP     B
        POP     H
        INX     H
        DCR     B
        JNZ     RD1
        JMP     RDLOOP

;-----------------------------------------------------------------------
; PDONE -- send what is left of the last line (a file need not end with
; CR LF), and report.
;-----------------------------------------------------------------------
PDONE:  CALL    FLUSH
        LHLD    LINES
        MOV     A,H
        ORA     L
        JZ      EEMPTY
        CALL    SAYDONE
        JMP     0

ABORT:  LXI     D,MABRT
        MVI     C,PRSTR
        CALL    BDOS
        JMP     FATAL

EEMPTY: LXI     D,MEMPTY
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

ENOCPM: LXI     D,MNOCPM
        MVI     C,PRSTR
        CALL    BDOS
        LXI     H,NAME
        CALL    PSTR
        LXI     D,MCRLF
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

EWILD:  LXI     D,MWILD
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

;=======================================================================
; THE PRINTED LINE -- see this file's header for the rules.
;=======================================================================

;-----------------------------------------------------------------------
; PUTCH -- one byte of the file, in A.
;-----------------------------------------------------------------------
PUTCH:  CPI     TAB
        JZ      PTAB
        CPI     CR
        JZ      PCR
        CPI     LF
        JZ      PEND
        CPI     FF
        JZ      PEND
        CPI     BS
        JZ      PBS
        CPI     ' '
        JC      ADDB            ; another control byte: no column
        CPI     7FH
        JNC     ADDB            ; DEL or bit 7 set: no column
                                ; else a printable character: fall in

;-----------------------------------------------------------------------
; PPRINT -- a character that takes a column. If the line is full, end it
; first: CR LF, send it, and start the next one at column 1.
;-----------------------------------------------------------------------
PPRINT: MOV     C,A
        LDA     COL
        CPI     PWIDTH
        JC      PP1
        PUSH    B
        MVI     A,CR
        CALL    ADDB
        MVI     A,LF
        CALL    ADDB
        CALL    FLUSH
        POP     B
        XRA     A
PP1:    INR     A
        STA     COL
        MOV     A,C
        JMP     ADDB

;-----------------------------------------------------------------------
; PTAB -- spaces up to the next column of 8, the way the BDOS does it.
;-----------------------------------------------------------------------
PTAB:   MVI     A,' '
        CALL    PPRINT
        LDA     COL
        ANI     07H
        JNZ     PTAB
        RET

PCR:    MOV     C,A
        XRA     A
        STA     COL
        MOV     A,C
        JMP     ADDB

PBS:    MOV     C,A
        LDA     COL
        ORA     A
        JZ      PBS1
        DCR     A
        STA     COL
PBS1:   MOV     A,C
        JMP     ADDB

;---- LF or FF: the end of a printed line -- send it ---------------------
PEND:   CALL    ADDB
        JMP     FLUSH

;-----------------------------------------------------------------------
; ADDB -- put A at the end of LINE. A full LINE is sent at once.
;-----------------------------------------------------------------------
ADDB:   MOV     C,A
        LDA     LLEN
        MOV     E,A
        MVI     D,0
        LXI     H,LINE
        DAD     D
        MOV     M,C
        INR     A
        STA     LLEN
        CPI     LINMAX
        RNZ
        JMP     FLUSH

;-----------------------------------------------------------------------
; FLUSH -- send LINE in one WRITE, if it has anything in it, and check
; the reply. A NAK stops the program.
;-----------------------------------------------------------------------
FLUSH:  LDA     LLEN
        ORA     A
        RZ
        CALL    MKWRITE
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        CPI     ACKCMD
        JNZ     EPNAK
        XRA     A
        STA     LLEN
        LHLD    LINES
        INX     H
        SHLD    LINES
        MOV     A,L             ; every 8th line: update the user
        ANI     07H
        RNZ
        JMP     SAYPROG

EPNAK:  LXI     D,MPNAK
        MVI     C,PRSTR
        CALL    BDOS
        JMP     FATAL

;-----------------------------------------------------------------------
; SAYPROG -- "\rPrinted NNNN lines..." with no trailing CR/LF, so the
; next call overwrites this line instead of scrolling. LINES only grows,
; so a shorter new number never leaves a stale digit behind.
;-----------------------------------------------------------------------
SAYPROG:MVI     E,CR
        MVI     C,CONOUT
        CALL    BDOS
        LXI     D,MPROGP
        MVI     C,PRSTR
        CALL    BDOS
        LHLD    LINES
        CALL    PRDEC
        LXI     D,MPROGS
        MVI     C,PRSTR
        JMP     BDOS

;=======================================================================
; BUILDING PACKETS -- see docs/rs232-protocol.md
;=======================================================================

;-----------------------------------------------------------------------
; MKWRITE -- a PRINTER_WRITE of LINE's LLEN bytes: descriptor 0 (no
; params), the text as the payload.
;-----------------------------------------------------------------------
MKWRITE:LXI     H,TXBUF
        MVI     M,PRTDEV
        INX     H
        MVI     M,CMDWRIT
        INX     H
        INX     H
        INX     H
        INX     H
        MVI     M,0             ; descr: no params
        INX     H
        LXI     D,LINE
        LDA     LLEN
        MOV     B,A
MKW1:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        DCR     B
        JNZ     MKW1
        LXI     D,TXBUF
        JMP     SETLEN

;-----------------------------------------------------------------------
; SETLEN -- HL = one past the last byte written, DE = TXBUF's start.
;-----------------------------------------------------------------------
SETLEN: MOV     A,L
        SUB     E
        MOV     C,A
        MOV     A,H
        SBB     D
        MOV     B,A
        MOV     A,C
        STA     TXBUF+2
        MOV     A,B
        STA     TXBUF+3
        XRA     A
        STA     TXBUF+4
        LXI     H,TXBUF
        CALL    CKSUM
        STA     TXBUF+4
        RET

CKSUM:  MVI     D,0
CK1:    MOV     A,B
        ORA     C
        JZ      CK9
        MOV     A,D
        ADD     M
        JNC     CK2
        INR     A
CK2:    MOV     D,A
        INX     H
        DCX     B
        JMP     CK1
CK9:    MOV     A,D
        RET

;=======================================================================
; SENDING AND RECEIVING -- SLIP framing (verbatim from FUJIPUT.ASM)
;=======================================================================
SENDPK: IN      SIOST           ; drop any stale byte first (a late
        ANI     01H             ; reply would be read as the answer to
        JZ      SPGO            ; this command -- manual 5.5)
        IN      SIODT
        JMP     SENDPK
SPGO:   LDA     TXBUF+2
        MOV     C,A
        LDA     TXBUF+3
        MOV     B,A
        LXI     H,TXBUF
        MVI     A,SLPEND
        CALL    ACOUT
SP1:    MOV     A,B
        ORA     C
        JZ      SP9
        MOV     A,M
        CPI     SLPEND
        JZ      SPQEND
        CPI     SLPESC
        JZ      SPQESC
        CALL    ACOUT
        JMP     SPADV
SPQEND: MVI     A,SLPESC
        CALL    ACOUT
        MVI     A,SLPEEND
        CALL    ACOUT
        JMP     SPADV
SPQESC: MVI     A,SLPESC
        CALL    ACOUT
        MVI     A,SLPEESC
        CALL    ACOUT
SPADV:  INX     H
        DCX     B
        JMP     SP1
SP9:    MVI     A,SLPEND
        JMP     ACOUT

;-----------------------------------------------------------------------
; RECVPK -- waits for the reply's leading SLPEND sync byte with a
; bounded busy-wait (TOOUTR outer passes x a full 16-bit inner
; countdown): if nothing at all comes back, print MNORE and quit rather
; than hang forever. A disabled printer is the usual cause: it sends no
; reply, not even a NAK (manual 5.3).
;
; The rest of the reply is read with ACINT, which gives up after about
; 1.5 s with no byte (2 MHz). RECVPK also stops at RXSIZE bytes, and
; checks what came: at least the 6-byte header, a length field equal to
; the bytes received, and the checksum (manual 4.3, 4.4). Any fault:
; MBADR and out through FATAL. RXLEN = the reply's length.
;-----------------------------------------------------------------------
RECVPK: MVI     A,TOOUTR
        STA     TOCNT
RPSYNC: LXI     B,0
RPWAIT: IN      SIOST
        ANI     01H
        JNZ     RPGOTB
        DCX     B
        MOV     A,B
        ORA     C
        JNZ     RPWAIT
        LDA     TOCNT
        DCR     A
        STA     TOCNT
        JNZ     RPSYNC
        LXI     D,MNORE         ; gave up -- no reply at all
        MVI     C,PRSTR
        CALL    BDOS
        JMP     FATAL

RPGOTB: IN      SIODT
        CPI     SLPEND
        JNZ     RPSYNC          ; noise, not the sync byte -- keep waiting
        LXI     H,RXBUF
        LXI     B,0
RP1:    CALL    ACINT
        JC      RPBAD           ; the reply stopped part-way
        CPI     SLPEND
        JZ      RP9
        CPI     SLPESC
        JNZ     RP3
        CALL    ACINT
        JC      RPBAD
        CPI     SLPEEND
        JZ      RPQEND
        CPI     SLPEESC
        JNZ     RPBAD           ; ESC + anything else: a broken frame
        MVI     A,SLPESC
        JMP     RP3
RPQEND: MVI     A,SLPEND
RP3:    MOV     D,A             ; room left in RXBUF?
        MOV     A,C
        SUI     RXSIZE AND 0FFH
        MOV     A,B
        SBI     RXSIZE SHR 8
        JNC     RPBAD           ; BC >= RXSIZE: too long
        MOV     M,D
        INX     H
        INX     B
        JMP     RP1

RP9:    MOV     A,B             ; an END with nothing before it: that
        ORA     C               ; was an opening END -- keep reading
        JZ      RP1
        MOV     H,B
        MOV     L,C
        SHLD    RXLEN
        MOV     A,C             ; at least the 6-byte header?
        SUI     6
        MOV     A,B
        SBI     0
        JC      RPBAD
        LDA     RXBUF+2         ; the length field = bytes received?
        CMP     C
        JNZ     RPBAD
        LDA     RXBUF+3
        CMP     B
        JNZ     RPBAD
        LDA     RXBUF+4         ; the checksum, taken with byte 4 = 0
        STA     RXCK
        XRA     A
        STA     RXBUF+4
        LXI     H,RXBUF
        CALL    CKSUM           ; BC = RXLEN still
        MOV     B,A
        LDA     RXCK
        STA     RXBUF+4
        CMP     B
        RZ
RPBAD:  LXI     D,MBADR
        MVI     C,PRSTR
        CALL    BDOS
        JMP     FATAL

;-----------------------------------------------------------------------
; ACINT -- ACIN with a time limit: CY set if no byte came within a full
; 16-bit countdown (about 1.5 s at 2 MHz). Keeps B, C, H, L.
;-----------------------------------------------------------------------
ACINT:  LXI     D,0
AI1:    IN      SIOST
        ANI     01H
        JNZ     AI2
        DCX     D
        MOV     A,D
        ORA     E
        JNZ     AI1
        STC
        RET
AI2:    IN      SIODT
        ORA     A               ; CY=0
        RET

;-----------------------------------------------------------------------
; FATAL -- printing stopped part-way. Say how much of it got to the
; printer, and exit. A printer WRITE is not safe to send again (manual
; 5.4: the text would print twice), so FUJITYPE does not retry.
;-----------------------------------------------------------------------
FATAL:  LHLD    LINES
        MOV     A,H
        ORA     L
        LXI     D,MNONE         ; "Nothing was printed."
        JZ      FAT1
        LXI     D,MPART         ; "The printout is incomplete."
FAT1:   MVI     C,PRSTR
        CALL    BDOS
        JMP     0

ACOUT:  PUSH    PSW
AO1:    IN      SIOST
        ANI     02H
        JZ      AO1
        POP     PSW
        OUT     SIODT
        RET

ACIN:   IN      SIOST
        ANI     01H
        JZ      ACIN
        IN      SIODT
        RET

;=======================================================================
; THE CP/M FCB -- INIFCB copied from W.ASM: the CCP's FCB at 5CH -> ours.
; We copy rather than use it in place for exactly W.ASM's stated reason
; (the CCP's second FCB at 6CH overlaps the first's tail).
;=======================================================================
INIFCB: LXI     H,FCB
        MVI     B,36
IF0:    MVI     M,0
        INX     H
        DCR     B
        JNZ     IF0

        LXI     H,TFCB
        LXI     D,FCB
        MVI     B,12
IF1:    MOV     A,M
        STAX    D
        INX     H
        INX     D
        DCR     B
        JNZ     IF1
        RET

;=======================================================================
; THE COMMAND TAIL -- the first word, as typed, into NAME. The FCB
; already holds the parsed name; NAME is only for the messages.
;=======================================================================
PARSE:  LXI     H,TAIL
        MOV     B,M
        INX     H
        CALL    SKIPSP
        LXI     D,NAME
        MVI     C,NAMLEN
        JMP     TOKEN

SKIPSP: MOV     A,B
        ORA     A
        RZ
        MOV     A,M
        CPI     ' '
        RNZ
        INX     H
        DCR     B
        JMP     SKIPSP

TOKEN:  MOV     A,C
        CPI     1
        JZ      TOKEND
        MOV     A,B
        ORA     A
        JZ      TOKEND
        MOV     A,M
        CPI     ' '
        JZ      TOKEND
        STAX    D
        INX     H
        INX     D
        DCR     B
        DCR     C
        JMP     TOKEN
TOKEND: XRA     A
        STAX    D
        RET

;=======================================================================
; TALKING TO THE USER
;=======================================================================
PSTR:   MOV     A,M
        ORA     A
        RZ
        PUSH    H
        MOV     E,A
        MVI     C,CONOUT
        CALL    BDOS
        POP     H
        INX     H
        JMP     PSTR

SAYSTRT:LXI     D,MSTRT
        MVI     C,PRSTR
        CALL    BDOS
        LXI     H,NAME
        CALL    PSTR
        LXI     D,MCRLF
        MVI     C,PRSTR
        JMP     BDOS

;-----------------------------------------------------------------------
; SAYDONE -- "NNN lines printed." PRDEC/DIV10 copied from HDIR.ASM.
;-----------------------------------------------------------------------
SAYDONE:MVI     E,CR
        MVI     C,CONOUT
        CALL    BDOS
        LHLD    LINES
        CALL    PRDEC
        LXI     D,MLINES
        MVI     C,PRSTR
        JMP     BDOS

PRDEC:  LXI     D,NUMEND
        MVI     A,'$'
        STAX    D
PD1:    DCX     D
        CALL    DIV10
        ADI     '0'
        STAX    D
        MOV     A,H
        ORA     L
        JNZ     PD1
        MVI     C,PRSTR
        JMP     BDOS

DIV10:  PUSH    B
        LXI     B,0
DV1:    MOV     A,H
        ORA     A
        JNZ     DV2
        MOV     A,L
        CPI     10
        JC      DV3
DV2:    MOV     A,L
        SUI     10
        MOV     L,A
        MOV     A,H
        SBI     0
        MOV     H,A
        INX     B
        JMP     DV1
DV3:    MOV     A,L
        MOV     H,B
        MOV     L,C
        POP     B
        RET

USAGE:  LXI     D,MUSAGE
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

;=======================================================================
; DATA
;=======================================================================
MSTRT:  DB      'FUJITYPE: printing $'
MCRLF:  DB      CR,LF,'$'
MNORE:  DB      CR,LF,'FUJITYPE: the printer is not responding. Check that'
        DB      ' FujiNet is on,',CR,LF
        DB      'and that "Use as virtual printer" is Yes on its web'
        DB      ' page.',CR,LF,'$'
MBADR:  DB      CR,LF,'FUJITYPE: damaged or incomplete reply from'
        DB      ' FujiNet.',CR,LF,'$'
MPNAK:  DB      CR,LF,'FUJITYPE: the printer refused the data.',CR,LF,'$'
MABRT:  DB      CR,LF,'FUJITYPE: aborted.',CR,LF,'$'
MNONE:  DB      'Nothing was printed.',CR,LF,'$'
MPART:  DB      'The printout is incomplete.',CR,LF,'$'
MNOCPM: DB      CR,LF,'FUJITYPE: no such CP/M file: $'
MWILD:  DB      CR,LF,'FUJITYPE: give one file name, with no * or ?.'
        DB      CR,LF,'$'
MEMPTY: DB      CR,LF,'FUJITYPE: the file is empty. Nothing was'
        DB      ' printed.',CR,LF,'$'
MLINES: DB      ' lines printed. Get the printout from FujiNet''s web'
        DB      ' page, at /print.',CR,LF,'$'
MPROGP: DB      'Printed $'
MPROGS: DB      ' lines...$'

MUSAGE: DB      CR,LF,'FUJITYPE v1.0 -- print a text file on FujiNet''s'
        DB      ' printer.',CR,LF,CR,LF
        DB      '   FUJITYPE file.ext',CR,LF,CR,LF
        DB      'Example',CR,LF
        DB      '   FUJITYPE NOTES.TXT',CR,LF,CR,LF
        DB      'The printout has the text that TYPE shows. A line longer'
        DB      ' than 80',CR,LF
        DB      'characters goes on to the next printed line. Get the'
        DB      ' printout from',CR,LF
        DB      'FujiNet''s web page, at /print.',CR,LF,'$'

;---- Variables ---------------------------------------------------------
NAME:   DS      NAMLEN
TOCNT:  DS      1
FCB:    DS      36
BUF:    DS      RECLEN
COL:    DS      1               ; the column of the next character, 0..80
LLEN:   DS      1               ; the bytes in LINE
LINES:  DS      2               ; the WRITEs that the printer took
RXLEN:  DS      2               ; the last reply's length
RXCK:   DS      1               ; its checksum byte, while checking

LINE:   DS      LINMAX
TXBUF:  DS      LINMAX+8        ; a WRITE: 6-byte header + LINE
RXBUF:  DS      RXSIZE
        DS      5               ; PRDEC's digits
NUMEND: DS      1

        DS      64              ; stack
STACK   EQU     $

        END     START
