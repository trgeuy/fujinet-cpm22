;-----------------------------------------------------------------------
; NC.COM v1.0 -- open a TCP connection through FujiNet, netcat-style.
;
;       NC <host> <port>                e.g.  NC 127.0.0.1 9000
;
; Bytes you type go to the connection; bytes the connection sends are
; printed. Ctrl-C closes the connection and exits.
;
; Talks to FujiNet's RS232 "Bus over IP" (BOIP) service, over the
; second unit of the console's own 88-2SIO card (sio0:b, port 12H/13H)
; -- see Reference/fujinet/rs232-protocol.md for the wire protocol this
; implements (SLIP-framed FujiBusPackets, reverse-engineered from the
; fujinet-firmware source and verified live against a running
; fujinet-pc-RS232 build). Assemble it INSIDE the machine:
;
;       ASM NC                  -> NC.HEX
;       LOAD NC                 -> NC.COM
;
;-----------------------------------------------------------------------
; THIS PROGRAM TALKS DIRECTLY TO THE 2SIO CARD, NOT TO BDOS.
;
; R.COM/W.COM/HDIR.COM (the Host Bridge tools) are pure BDOS calls,
; because CP/M's BDOS already understands DISKS. It has no idea what a
; second serial line is -- BDOS console I/O is wired to the ONE console
; device -- so there is no higher layer to defer to here. This program
; is the layer. If you move the 2SIO card, reassemble (the ports are
; EQUs at the top, same as every other card-specific tool in this
; project).
;
; AND BDOS CLOBBERS EVERY REGISTER (A,B,C,D,E,H,L -- only SP survives).
; Nothing may be left live in a register across CALL BDOS.
;-----------------------------------------------------------------------

        ORG     100H

;---- CP/M --------------------------------------------------------------
BDOS    EQU     0005H
TAIL    EQU     0080H           ; the command tail: length, then the text

CONOUT  EQU     2               ; E = char
DIRIO   EQU     6               ; direct console I/O: E=0FFH polls input
                                ; (A=0 if none ready), else E=the char to
                                ; output, raw, no wait, no translation
PRSTR   EQU     9               ; DE = string, '$'-terminated

CR      EQU     0DH
LF      EQU     0AH
CTRLC   EQU     03H

;---- The 2SIO card, unit b (see Reference/manual/ref/boards.md) --------
; sio0 base = 10H; unit a = 10H/11H (the console); unit b = 12H/13H.
SIOST   EQU     12H             ; status (IN) / control (OUT)
SIODT   EQU     13H             ; data, both ways
SIORST  EQU     03H             ; master reset (both counter-select bits)
SIOCTL  EQU     15H             ; /=16, no interrupts -- proven live against
                                ; FujiNet-PC-RS232's BOIP channel this session

;---- The FujiNet RS232 wire protocol (Reference/fujinet/rs232-protocol.md)
NETDEV  EQU     71H             ; the first network device slot
CMDOPEN EQU     4FH
CMDCLOS EQU     43H
CMDREAD EQU     52H
CMDWRIT EQU     57H
CMDSTAT EQU     53H
ACKCMD  EQU     06H

ACCRW   EQU     0CH             ; access mode: read/write
TRANONE EQU     00H             ; translation: none (binary)

SLPEND  EQU     0C0H            ; SLIP frame delimiter
SLPESC  EQU     0DBH            ; SLIP escape
SLPEEND EQU     0DCH            ; escaped 0C0H
SLPEESC EQU     0DDH            ; escaped 0DBH

RDMAX   EQU     80              ; largest READ this program ever asks for
RDMAX1  EQU     RDMAX+1

KAPASS  EQU     50              ; idle STATUS-only passes before a keepalive
                                 ; write (see MIDLE) -- confirmed-live idle-
                                 ; disconnect margin was ~15s at roughly
                                 ; 20-30ms/pass; this revisits every ~1-1.5s,
                                 ; well inside that margin

;=======================================================================
; MAIN
;=======================================================================
START:  LXI     SP,STACK
        XRA     A
        STA     IDLECT          ; RAM isn't guaranteed to power up zeroed

        CALL    PARSE           ; command tail -> HOST, PORT
        LDA     HOST
        ORA     A
        JZ      USAGE
        LDA     PORT
        ORA     A
        JZ      USAGE

        MVI     A,SIORST        ; the ACIA out of reset...
        OUT     SIOST
        MVI     A,SIOCTL        ; ...and into a real operating mode
        OUT     SIOST

        CALL    BUILDSP         ; SPEC = "N1:TCP://host:port/",0
        CALL    SAYCONN

        CALL    MKOPEN
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        CPI     ACKCMD
        JNZ     EFAIL

        CALL    SAYOK

        MVI     A,CR            ; nudge: fujinet-firmware's fnTcpClient has a
        STA     WCHAR           ; confirmed upstream bug (recv(MSG_PEEK) == 0
        CALL    MKWRITE         ; misread as "closed" on a connection that's
        CALL    SENDPK          ; open but has never exchanged real data) --
        CALL    RECVPK          ; get a line across before MLOOP can ever idle
        MVI     A,LF            ; on a STATUS-only poll, working around it
        STA     WCHAR           ; rather than waiting on a fujinet-firmware
        CALL    MKWRITE         ; fix. CRLF (not just CR) because a bare CR
        CALL    SENDPK          ; drew no reply from tcpbin.com -- it's
        CALL    RECVPK          ; line-buffered, unlike fujinet's own BOIP
                                 ; test loopback, which echoes any single byte
                                 ; immediately.

;-----------------------------------------------------------------------
; MLOOP -- the interactive body. Every pass: check for a keystroke to
; send, then ask FujiNet for STATUS and, if it has bytes for us, READ
; and print them. No pacing delay -- this is a local loopback link and
; the host CPU is fast; see Reference/manual/serial.md on giving a
; machine "its real crystal" if this is ever run against a slow WAN link
; instead.
;-----------------------------------------------------------------------
MLOOP:  MVI     E,0FFH
        MVI     C,DIRIO
        CALL    BDOS
        ORA     A
        JZ      MNOKEY
        CPI     CTRLC
        JZ      MCLOSE
        STA     WCHAR
        CALL    MKWRITE
        CALL    SENDPK
        CALL    RECVPK          ; the WRITE's ACK -- not checked; a dropped
                                 ; connection shows up as connected=0 below
        XRA     A
        STA     IDLECT          ; real traffic just went out -- not idle

MNOKEY: CALL    MKSTAT
        CALL    SENDPK
        CALL    RECVPK

        LDA     RXBUF+8         ; "connected"
        ORA     A
        JZ      MDISC

        LDA     RXBUF+6         ; bytes_waiting, lo
        MOV     D,A
        LDA     RXBUF+7         ; bytes_waiting, hi
        ORA     D
        JZ      MIDLE           ; nothing waiting -- count the idle pass

        LDA     RXBUF+7
        ORA     A
        JNZ     MCLAMP          ; hi byte set -> certainly > RDMAX
        LDA     RXBUF+6
        CPI     RDMAX1
        JNC     MCLAMP          ; bw >= RDMAX+1 -> clamp
        STA     REQLEN          ; else A (bw lo) is already <= RDMAX
        XRA     A
        STA     REQLEN+1
        JMP     MDOREAD
MCLAMP: MVI     A,RDMAX
        STA     REQLEN
        XRA     A
        STA     REQLEN+1

MDOREAD:
        CALL    MKREAD
        CALL    SENDPK
        CALL    RECVPK
        XRA     A
        STA     IDLECT          ; real traffic just came in -- not idle

        LXI     H,RXBUF+6
        LDA     REQLEN          ; REQLEN's hi byte is always 0 (RDMAX<256)
        MOV     B,A
MPRINT: MOV     A,B
        ORA     A
        JZ      MLOOP
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
        JMP     MPRINT

;-----------------------------------------------------------------------
; MIDLE -- a STATUS pass came back with nothing waiting. Count it, and
; every KAPASS-th consecutive idle pass, write a keepalive LF instead of
; going straight around again. Works around the same upstream fnTcpClient
; bug the post-OPEN nudge does (see there) -- confirmed live that bug can
; still eventually misfire an idle-but-live connection after ~15s of pure
; STATUS polling even once real data has already flowed both ways once;
; KAPASS is sized to revisit well inside that margin.
;-----------------------------------------------------------------------
MIDLE:  LDA     IDLECT
        INR     A
        STA     IDLECT
        CPI     KAPASS
        JC      MLOOP           ; not yet -- go around again
        XRA     A
        STA     IDLECT
        MVI     A,LF
        STA     WCHAR
        CALL    MKWRITE
        CALL    SENDPK
        CALL    RECVPK
        JMP     MLOOP

MDISC:  CALL    SAYDISC
        JMP     0

MCLOSE: CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK
        CALL    SAYCLSD
        JMP     0

EFAIL:  CALL    SAYFAIL
        JMP     0

;=======================================================================
; BUILDING PACKETS
;
; Each MKxxx fills TXBUF from offset 0 and finishes by calling SETLEN,
; which computes the header's length field from how far HL has moved,
; zeroes and then fills the checksum byte. See
; Reference/fujinet/rs232-protocol.md for the exact layout this mirrors:
;
;   off0  device      off3  length hi     off6+  params, then payload
;   off1  command      off4  checksum
;   off2  length lo    off5  descr (first descriptor byte)
;=======================================================================

MKOPEN: LXI     H,TXBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDOPEN
        INX     H
        INX     H
        INX     H
        INX     H               ; off2 -> off5 (skip length,length,checksum)
        MVI     M,2             ; descr: two 1-byte params
        INX     H
        MVI     M,ACCRW
        INX     H
        MVI     M,TRANONE
        INX     H               ; -> off8: payload starts here
        LXI     D,SPEC
MKO1:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        ORA     A
        JNZ     MKO1            ; copy through and including the NUL
        LXI     D,TXBUF
        JMP     SETLEN          ; tail call

MKWRITE:LXI     H,TXBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDWRIT
        INX     H
        INX     H
        INX     H
        INX     H
        MVI     M,5             ; descr: one 2-byte param
        INX     H
        MVI     M,1             ; length lo = 1
        INX     H
        MVI     M,0             ; length hi = 0
        INX     H
        LDA     WCHAR
        MOV     M,A             ; the one byte of payload
        INX     H
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
        MVI     M,0             ; descr: zero params
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
; Stores length = HL-DE at TXBUF+2/3, then computes and stores the
; checksum at TXBUF+4.
;-----------------------------------------------------------------------
SETLEN: MOV     A,L
        SUB     E
        MOV     C,A             ; C = length lo
        MOV     A,H
        SBB     D
        MOV     B,A             ; B = length hi
        MOV     A,C
        STA     TXBUF+2
        MOV     A,B
        STA     TXBUF+3
        XRA     A
        STA     TXBUF+4         ; zero the checksum byte before summing
        LXI     H,TXBUF
        CALL    CKSUM           ; HL,BC as above -> checksum in A
        STA     TXBUF+4
        RET

;-----------------------------------------------------------------------
; CKSUM -- HL = buffer, BC = length. Returns the checksum in A.
; chk=0; for each byte: chk+=byte, folding any carry back in -- an ADD
; plus a conditional INR is exactly that fold on an 8080.
;-----------------------------------------------------------------------
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
; SENDING AND RECEIVING -- SLIP framing over the raw ACIA
;=======================================================================

;-----------------------------------------------------------------------
; SENDPK -- SLIP-frame and transmit TXBUF, using the length already
; stored at TXBUF+2/3.
;-----------------------------------------------------------------------
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
        JMP     ACOUT           ; tail call

;-----------------------------------------------------------------------
; RECVPK -- read one SLIP frame into RXBUF, decoding as it goes.
; Returns BC = the decoded length (the same header+params+payload count
; SETLEN would have computed on the sending side).
;-----------------------------------------------------------------------
RECVPK: CALL    ACIN
        CPI     SLPEND
        JNZ     RECVPK          ; discard anything before the opening 0C0H
        LXI     H,RXBUF
        LXI     B,0
RP1:    CALL    ACIN
        CPI     SLPEND
        JZ      RP9             ; the closing delimiter -- done
        CPI     SLPESC
        JNZ     RP3
        CALL    ACIN
        CPI     SLPEEND
        JZ      RPQEND
        MVI     A,SLPESC        ; anything else after ESC: treat as 0DBH
        JMP     RP3
RPQEND: MVI     A,SLPEND
RP3:    MOV     M,A
        INX     H
        INX     B
        JMP     RP1
RP9:    RET

;-----------------------------------------------------------------------
; ACOUT -- send the byte in A, waiting for TDRE.
; ACIN  -- receive a byte into A, waiting for RDRF.
;-----------------------------------------------------------------------
ACOUT:  PUSH    PSW
AO1:    IN      SIOST
        ANI     02H             ; TDRE
        JZ      AO1
        POP     PSW
        OUT     SIODT
        RET

ACIN:   IN      SIOST
        ANI     01H             ; RDRF
        JZ      ACIN
        IN      SIODT
        RET

;=======================================================================
; THE COMMAND TAIL AND THE DEVICE SPEC
;=======================================================================

;-----------------------------------------------------------------------
; PARSE -- pull HOST and PORT out of the command tail at 0080H.
; Same shape as R.ASM's PARSE/TOKEN/SKIPSP -- see there for why this is
; hand-rolled rather than the CCP's own FCB parse.
;-----------------------------------------------------------------------
PARSE:  LXI     H,TAIL
        MOV     B,M
        INX     H
        CALL    SKIPSP
        LXI     D,HOST
        CALL    TOKEN
        CALL    SKIPSP
        LXI     D,PORT
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

TOKEN:  MOV     A,B
        ORA     A
        JZ      TOKEND
        MOV     A,M
        CPI     ' '
        JZ      TOKEND
        STAX    D
        INX     H
        INX     D
        DCR     B
        JMP     TOKEN
TOKEND: XRA     A
        STAX    D
        RET

;-----------------------------------------------------------------------
; BUILDSP -- SPEC = "N1:TCP://" + HOST + ":" + PORT + "/" + NUL.
; The Nx: prefix is carried in the payload even though the packet's own
; device byte already selects the channel -- confirmed live; see
; Reference/fujinet/rs232-protocol.md, "Verified live".
;-----------------------------------------------------------------------
BUILDSP:LXI     D,SPEC
        LXI     H,PFXSTR
        CALL    CATSTR
        LXI     H,HOST
        CALL    CATSTR
        LXI     H,COLSTR
        CALL    CATSTR
        LXI     H,PORT
        CALL    CATSTR
        LXI     H,SLSTR
        CALL    CATSTR
        RET

; CATSTR -- append the NUL-terminated string at HL onto the one being
; built at DE (DE is left pointing at the new NUL, ready for the next
; call -- a running cursor, not reset between calls).
CATSTR: MOV     A,M
        ORA     A
        JZ      CS9
        STAX    D
        INX     H
        INX     D
        JMP     CATSTR
CS9:    XRA     A
        STAX    D
        RET

;=======================================================================
; TALKING TO THE USER
;=======================================================================

; PSTR -- print the NUL-terminated string at HL, one BDOS call at a
; time (so nothing needs to survive BDOS clobbering every register).
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

SAYDISC:LXI     D,MDISCM
        MVI     C,PRSTR
        JMP     BDOS

SAYCLSD:LXI     D,MCLSDM
        MVI     C,PRSTR
        JMP     BDOS

USAGE:  LXI     D,MUSAGE
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

;=======================================================================
; DATA
;=======================================================================
PFXSTR: DB      'N1:TCP://',0
COLSTR: DB      ':',0
SLSTR:  DB      '/',0

MCONN:  DB      'NC: connecting to $'
MCRLF:  DB      CR,LF,'$'
MOK:    DB      'Connected. Ctrl-C to close.',CR,LF,'$'
MFAIL:  DB      CR,LF,'NC: connection failed.',CR,LF,'$'
MDISCM: DB      CR,LF,'NC: connection closed by remote.',CR,LF,'$'
MCLSDM: DB      CR,LF,'NC: closed.',CR,LF,'$'

MUSAGE: DB      CR,LF,'NC v1.0 -- open a TCP connection through FujiNet.',CR,LF,CR,LF
        DB      '   NC <host> <port>',CR,LF,CR,LF
        DB      'Example',CR,LF
        DB      '   NC 127.0.0.1 9000',CR,LF,CR,LF
        DB      'Bytes typed go to the connection; bytes received are'
        DB      ' printed.',CR,LF
        DB      'Ctrl-C closes the connection and exits.',CR,LF,'$'

;---- Variables ---------------------------------------------------------
HOST:   DS      65              ; up to 64 characters + NUL
PORT:   DS      8
SPEC:   DS      96              ; "N1:TCP://" + HOST + ":" + PORT + "/" + 0
WCHAR:  DS      1
REQLEN: DS      2
IDLECT: DS      1               ; consecutive idle STATUS-only passes (MIDLE)

TXBUF:  DS      200
RXBUF:  DS      200

        DS      64              ; stack
STACK   EQU     $

        END     START
