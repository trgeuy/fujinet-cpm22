;-----------------------------------------------------------------------
; FUJIDIR.COM v1.1 -- list a directory through FujiNet's N: network device.
;
;       FUJIDIR N:<url>         e.g.  FUJIDIR N1:TNFS://192.168.1.5/
;
; Opens <url> in FujiNet's DIRECTORY access mode (not read/write -- see
; below) and prints what comes back: one name per line, files padded out
; to a size column on the right (bytes, or K/M for larger ones -- see
; DIRFLONG below), directories marked with a trailing '/' and no size
; (FujiNet's LONG format always attaches one, even to directories, where
; it's a meaningless placeholder -- this program buffers each line and
; drops everything from the first '/' onward before printing it, since
; a real filename never contains one; see LBYTE/LFLUSH below).
;
;-----------------------------------------------------------------------
; THIS IS NOT THE FUJI-DEVICE HOST-SLOT BROWSER (OPEN_DIRECTORY/
; READ_DIR_ENTRY/CLOSE_DIRECTORY, $F7/$F6/$F5), which needs a host
; pre-mounted via CONFIG and was the frontier this project flagged as
; unresolved. The ORDINARY N: OPEN ($4F) dispatches to a directory
; listing when the ACCESS MODE byte is DIRECTORY ($06), and the
; TRANSLATION byte doubles as a listing FORMAT selector then (dirFormat_t
; in fujinet-firmware's FS.h). v1.0 sent $83 (RAW: names only, no size);
; v1.1 sends $80 (LONG) instead -- still plain CRLF-terminated text, one
; entry per line, so this program's read loop didn't need to change at
; all, only the format byte's value. See docs/rs232-protocol.md for the
; wire details this and FUJIGET.ASM/FUJIPUT.ASM share.
;-----------------------------------------------------------------------
; AND BDOS CLOBBERS EVERY REGISTER (A,B,C,D,E,H,L -- only SP survives).
;-----------------------------------------------------------------------
; Assemble it INSIDE the machine:
;
;       ASM FUJIDIR             -> FUJIDIR.HEX
;       LOAD FUJIDIR            -> FUJIDIR.COM
;-----------------------------------------------------------------------

        ORG     100H

;---- CP/M ---------------------------------------------------------------
BDOS    EQU     0005H
TAIL    EQU     0080H

CONOUT  EQU     2
DIRIO   EQU     6
PRSTR   EQU     9

CR      EQU     0DH
LF      EQU     0AH
CTRLC   EQU     03H

;---- The 2SIO card, unit b ---------------------------------------------
SIOST   EQU     12H
SIODT   EQU     13H
SIORST  EQU     03H
SIOCTL  EQU     15H

;---- The FujiNet RS232 wire protocol (Reference/fujinet/rs232-protocol.md)
NETDEV  EQU     71H
CMDOPEN EQU     4FH
CMDCLOS EQU     43H
CMDREAD EQU     52H
CMDSTAT EQU     53H
ACKCMD  EQU     06H

ACCDIR  EQU     06H             ; access mode: DIRECTORY, not read or write
DIRFLONG EQU    80H             ; "translation" byte, repurposed as format:
                                ; DIR_FORMAT::LONG -- name + '/' on
                                ; directories, right-justified size,
                                ; CRLF-separated (see header above)

SLPEND  EQU     0C0H
SLPESC  EQU     0DBH
SLPEEND EQU     0DCH
SLPEESC EQU     0DDH

RDMAX   EQU     128             ; largest READ this program ever asks for
SPECLEN EQU     100             ; room for SPEC, including the NUL

;=======================================================================
; MAIN
;=======================================================================
START:  LXI     SP,STACK

        CALL    PARSE           ; tail -> SPEC (the url)
        LDA     SPEC
        ORA     A
        JZ      USAGE

        MVI     A,SIORST
        OUT     SIOST
        MVI     A,SIOCTL
        OUT     SIOST

        CALL    SAYCONN

        CALL    MKOPEN
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        CPI     ACKCMD
        JNZ     EFAIL

        XRA     A
        STA     ANYOUT          ; nothing printed yet
        STA     LINELEN         ; line buffer starts empty

;-----------------------------------------------------------------------
; DLOOP -- poll for a Ctrl-C abort, then ask STATUS. If FujiNet has bytes
; waiting, READ up to RDMAX and hand each byte to LBYTE, which buffers a
; line at a time and prints it once complete (see LBYTE/LFLUSH below).
; connected=0 with nothing waiting is a clean end of the listing.
;-----------------------------------------------------------------------
DLOOP:  MVI     E,0FFH
        MVI     C,DIRIO
        CALL    BDOS
        ORA     A
        JZ      DPOLL
        CPI     CTRLC
        JZ      ABORT

DPOLL:  CALL    MKSTAT
        CALL    SENDPK
        CALL    RECVPK

        LDA     RXBUF+6         ; bytes_waiting, lo
        MOV     D,A
        LDA     RXBUF+7         ; bytes_waiting, hi
        ORA     D
        JNZ     DGOT

        LDA     RXBUF+8         ; connected
        ORA     A
        JNZ     DLOOP           ; still open, nothing waiting yet
        JMP     DDONE           ; connected=0, nothing waiting: the listing is over

;---- REQLEN = min(bytes_waiting, RDMAX) --------------------------------
DGOT:   LDA     RXBUF+7
        ORA     A
        JNZ     DQMAX           ; bw >= 256, certainly > RDMAX

        LDA     RXBUF+6
        CPI     RDMAX+1
        JNC     DQMAX           ; bw >= RDMAX+1 -> clamp
        STA     REQLEN          ; else A (bw lo) is already <= RDMAX
        XRA     A
        STA     REQLEN+1
        JMP     DGO
DQMAX:  MVI     A,RDMAX
        STA     REQLEN
        XRA     A
        STA     REQLEN+1

DGO:    CALL    MKREAD
        CALL    SENDPK
        CALL    RECVPK

        MVI     A,1
        STA     ANYOUT

        LXI     H,RXBUF+6
        LDA     REQLEN          ; REQLEN's hi byte is always 0 (RDMAX<256)
        MOV     B,A
DPRINT: MOV     A,B
        ORA     A
        JZ      DLOOP
        MOV     A,M
        PUSH    H
        PUSH    B
        CALL    LBYTE
        POP     B
        POP     H
        INX     H
        DCR     B
        JMP     DPRINT

;-----------------------------------------------------------------------
; DDONE -- close, note if nothing at all came back, and exit. Flush any
; partial line LBYTE is still holding (only possible if the connection
; ended mid-line, which shouldn't happen against a well-behaved server,
; but nothing sent would otherwise be silently lost).
;-----------------------------------------------------------------------
DDONE:  LDA     LINELEN
        ORA     A
        CNZ     LFLUSH

        CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK

        LDA     ANYOUT
        ORA     A
        JNZ     EXIT0
        CALL    SAYNONE

EXIT0:  JMP     0

ABORT:  LDA     LINELEN
        ORA     A
        CNZ     LFLUSH

        CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK
        CALL    SAYABRT
        JMP     0

EFAIL:  CALL    SAYFAIL
        JMP     0

;=======================================================================
; LINE BUFFERING -- LBYTE appends one byte to LINEBUF; on LF (end of a
; LONG-format entry) it calls LFLUSH to print the completed line and
; resets LINELEN for the next one. LFLUSH scans for a '/' -- a real
; filename never contains one, so its presence means this line is a
; directory -- and if found, prints only through the '/' plus our own
; CR,LF, discarding the padding+size that followed. No '/' found means
; an ordinary file line: print it unchanged, size column and all.
;=======================================================================
LBYTE:  MOV     C,A             ; save the incoming byte
        LXI     H,LINEBUF
        LDA     LINELEN
        MOV     E,A
        MVI     D,0
        DAD     D               ; HL = LINEBUF + LINELEN
        MOV     M,C
        INR     A
        STA     LINELEN
        MOV     A,C
        CPI     LF
        RNZ                     ; not end-of-line yet
        CALL    LFLUSH
        XRA     A
        STA     LINELEN
        RET

LFLUSH: LXI     H,LINEBUF
        LDA     LINELEN
        STA     LFTOT
        MOV     B,A
        MVI     C,0
LFSCAN: MOV     A,B
        ORA     A
        JZ      LFFULL          ; scanned it all, no '/' -- a file line
        MOV     A,M
        INR     C
        CPI     '/'
        JZ      LFDIR
        INX     H
        DCR     B
        JMP     LFSCAN

LFDIR:  MOV     B,C             ; C = bytes from LINEBUF through the '/'
        CALL    PRNBUF
        MVI     E,CR
        MVI     C,DIRIO
        CALL    BDOS
        MVI     E,LF
        MVI     C,DIRIO
        JMP     BDOS

LFFULL: LDA     LFTOT
        MOV     B,A
        JMP     PRNBUF

;---- PRNBUF -- print B bytes starting at LINEBUF ----------------------
PRNBUF: LXI     H,LINEBUF
PRNB1:  MOV     A,B
        ORA     A
        RZ
        MOV     A,M
        MOV     E,A
        MVI     C,DIRIO
        PUSH    H
        PUSH    B
        CALL    BDOS
        POP     B
        POP     H
        INX     H
        DCR     B
        JMP     PRNB1

;=======================================================================
; BUILDING PACKETS -- see Reference/fujinet/rs232-protocol.md; identical
; shape to CPM Tools/NC.ASM's/FUJIGET.ASM's MKxxx routines.
;=======================================================================

MKOPEN: LXI     H,TXBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDOPEN
        INX     H
        INX     H
        INX     H
        INX     H
        MVI     M,2             ; descr: two 1-byte params
        INX     H
        MVI     M,ACCDIR
        INX     H
        MVI     M,DIRFLONG
        INX     H
        LXI     D,SPEC
MKO1:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        ORA     A
        JNZ     MKO1
        LXI     D,TXBUF
        JMP     SETLEN

MKREAD: LXI     H,TXBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDREAD
        INX     H
        INX     H
        INX     H
        INX     H
        MVI     M,5             ; descr: one 2-byte param
        INX     H
        LDA     REQLEN
        MOV     M,A
        INX     H
        LDA     REQLEN+1
        MOV     M,A
        INX     H
        LXI     D,TXBUF
        JMP     SETLEN

MKSTAT: LXI     H,TXBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDSTAT
        INX     H
        INX     H
        INX     H
        INX     H
        MVI     M,0
        INX     H
        LXI     D,TXBUF
        JMP     SETLEN

MKCLOSE:LXI     H,TXBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDCLOS
        INX     H
        INX     H
        INX     H
        INX     H
        MVI     M,0
        INX     H
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
; SENDING AND RECEIVING -- SLIP framing (verbatim from CPM Tools/NC.ASM)
;=======================================================================
SENDPK: LDA     TXBUF+2
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

RECVPK: CALL    ACIN
        CPI     SLPEND
        JNZ     RECVPK
        LXI     H,RXBUF
        LXI     B,0
RP1:    CALL    ACIN
        CPI     SLPEND
        JZ      RP9
        CPI     SLPESC
        JNZ     RP3
        CALL    ACIN
        CPI     SLPEEND
        JZ      RPQEND
        MVI     A,SLPESC
        JMP     RP3
RPQEND: MVI     A,SLPEND
RP3:    MOV     M,A
        INX     H
        INX     B
        JMP     RP1
RP9:    RET

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
; THE COMMAND TAIL -- one word, hand-parsed (a URL is not an 8.3 name).
; TOKEN bounded by a room count, same as FUJIGET.ASM's (HDIR.ASM's shape).
;=======================================================================
PARSE:  LXI     H,TAIL
        MOV     B,M
        INX     H
        CALL    SKIPSP
        LXI     D,SPEC
        MVI     C,SPECLEN
        CALL    TOKEN
        RET

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

SAYCONN:LXI     D,MCONN
        MVI     C,PRSTR
        CALL    BDOS
        LXI     H,SPEC
        CALL    PSTR
        LXI     D,MCRLF
        MVI     C,PRSTR
        JMP     BDOS

SAYFAIL:LXI     D,MFAIL
        MVI     C,PRSTR
        JMP     BDOS

SAYABRT:LXI     D,MABRT
        MVI     C,PRSTR
        JMP     BDOS

SAYNONE:LXI     D,MNONE
        MVI     C,PRSTR
        JMP     BDOS

USAGE:  LXI     D,MUSAGE
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

;=======================================================================
; DATA
;=======================================================================
MCONN:  DB      'FUJIDIR: listing $'
MCRLF:  DB      CR,LF,'$'
MFAIL:  DB      CR,LF,'FUJIDIR: open failed.',CR,LF,'$'
MABRT:  DB      CR,LF,'FUJIDIR: aborted.',CR,LF,'$'
MNONE:  DB      'FUJIDIR: nothing matches.',CR,LF,'$'

MUSAGE: DB      CR,LF,'FUJIDIR v1.1 -- list a directory through FujiNet''s'
        DB      ' N: network device.',CR,LF,CR,LF
        DB      '   FUJIDIR N:<url>',CR,LF,CR,LF
        DB      'Example',CR,LF
        DB      '   FUJIDIR N1:TNFS://192.168.1.5/',CR,LF,'$'

;---- Variables ---------------------------------------------------------
SPEC:   DS      SPECLEN
REQLEN: DS      2
ANYOUT: DS      1
LINELEN:DS      1
LFTOT:  DS      1

TXBUF:  DS      200
RXBUF:  DS      200
LINEBUF:DS      200             ; one LONG-format entry (well under 40
                                ; bytes) never comes close to filling this

        DS      64              ; stack
STACK   EQU     $

        END     START
