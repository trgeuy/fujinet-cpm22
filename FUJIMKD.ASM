;-----------------------------------------------------------------------
; FUJIMKD.COM v1.0 -- create a directory through FujiNet's N: network
; device.
;
;       FUJIMKD N:<url>        e.g.  FUJIMKD N1:TNFS://192.168.1.5/NEWDIR
;
; Sends a single NETCMD_MKDIR ($2A) request against <url> and reports
; ACK (created) or NAK (failed -- already exists, bad path, read-only
; server, etc; FujiNet's ACK/NAK envelope carries no further detail).
;-----------------------------------------------------------------------
; Traced from fujinet-firmware source (lib/device/rs232/network.cpp,
; rs232Network::process_fs()), not yet live-tested when first written --
; see Reference/fujinet/rs232-protocol.md's "Traced from source" section.
; MKDIR shares its wire shape with RENAME/DELETE/LOCK/UNLOCK/RMDIR: the
; payload is the SAME NUL-terminated Nx:-prefixed devicespec string
; FUJIDIR/FUJIGET's OPEN already sends, just under a different command
; byte and with 0 params instead of OPEN's 2 -- no persistent channel is
; created (process_fs calls fs->mkdir() directly, not fs->open()), so
; this is the simplest of the FujiNet suite tools: one request, one
; reply, no STATUS/READ loop, no FCB/file I/O at all.
;-----------------------------------------------------------------------
; AND BDOS CLOBBERS EVERY REGISTER (A,B,C,D,E,H,L -- only SP survives).
;-----------------------------------------------------------------------
; Assemble it INSIDE the machine:
;
;       ASM FUJIMKD             -> FUJIMKD.HEX
;       LOAD FUJIMKD            -> FUJIMKD.COM
;-----------------------------------------------------------------------

        ORG     100H

;---- CP/M ---------------------------------------------------------------
BDOS    EQU     0005H
TAIL    EQU     0080H

CONOUT  EQU     2
PRSTR   EQU     9

CR      EQU     0DH
LF      EQU     0AH

;---- The 2SIO card, unit b ---------------------------------------------
SIOST   EQU     12H
SIODT   EQU     13H
SIORST  EQU     03H
SIOCTL  EQU     15H

;---- The FujiNet RS232 wire protocol (Reference/fujinet/rs232-protocol.md)
NETDEV  EQU     71H
CMDMKD  EQU     2AH             ; NETCMD_MKDIR
CMDCLOS EQU     43H
ACKCMD  EQU     06H

SLPEND  EQU     0C0H
SLPESC  EQU     0DBH
SLPEEND EQU     0DCH
SLPEESC EQU     0DDH

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

        CALL    MKMKD
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        STA     RESULT          ; save before CLOSE's own reply overwrites RXBUF

        CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK

        LDA     RESULT
        CPI     ACKCMD
        JNZ     MFAILJ

        CALL    SAYOK
        JMP     0

MFAILJ: CALL    SAYFAIL
        JMP     0

;=======================================================================
; BUILDING PACKETS -- see Reference/fujinet/rs232-protocol.md; identical
; shape to CPM Tools/FUJIDIR.ASM's/FUJIGET.ASM's MKxxx routines. MKMKD
; is MKOPEN's URL-copy loop with a 0-param header (MKCLOSE's shape)
; instead of OPEN's two access/translation param bytes.
;=======================================================================

MKMKD:  LXI     H,TXBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDMKD
        INX     H
        INX     H
        INX     H
        INX     H
        MVI     M,0             ; descr: no params, just the devicespec payload
        INX     H
        LXI     D,SPEC
MKM1:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        ORA     A
        JNZ     MKM1
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
; TOKEN bounded by a room count, same as FUJIDIR.ASM's (HDIR.ASM's shape).
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

SAYOK:  LXI     D,MOK
        MVI     C,PRSTR
        JMP     BDOS

SAYFAIL:LXI     D,MFAIL
        MVI     C,PRSTR
        JMP     BDOS

USAGE:  LXI     D,MUSAGE
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

;=======================================================================
; DATA
;=======================================================================
MCONN:  DB      'FUJIMKD: creating $'
MCRLF:  DB      CR,LF,'$'
MOK:    DB      CR,LF,'FUJIMKD: directory created.',CR,LF,'$'
MFAIL:  DB      CR,LF,'FUJIMKD: failed (may already exist, or path'
        DB      ' invalid).',CR,LF,'$'

MUSAGE: DB      CR,LF,'FUJIMKD v1.0 -- create a directory through'
        DB      ' FujiNet''s N: network device.',CR,LF,CR,LF
        DB      '   FUJIMKD N:<url>',CR,LF,CR,LF
        DB      'Example',CR,LF
        DB      '   FUJIMKD N1:TNFS://tnfs.mitsaltair.com/NEWDIR'
        DB      CR,LF,'$'

;---- Variables ---------------------------------------------------------
SPEC:   DS      SPECLEN
RESULT: DS      1

TXBUF:  DS      200
RXBUF:  DS      200

        DS      64              ; stack
STACK   EQU     $

        END     START
