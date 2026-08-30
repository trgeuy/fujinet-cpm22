;-----------------------------------------------------------------------
; FUJIMKD.COM v1.2 -- create a directory through FujiNet's N: network
; device.
;
;       FUJIMKD N:<url>        e.g.  FUJIMKD N1:TNFS://192.168.1.5/NEWDIR
;
; Probes <url> first (a directory-mode OPEN, same mechanism FUJIDIR
; uses): if it's already there, asks "Create anyway? (Y/N)" before
; trying, same shape as FUJIGET/FUJIPUT's overwrite check. Sends a
; NETCMD_MKDIR ($2A) request and reports one of three outcomes:
;   - "directory created."
;   - "denied" -- MKDIR failed, but the PARENT directory checks out
;     (so this is almost certainly a permission/read-only restriction).
;   - "parent path does not exist" -- MKDIR failed, and the parent
;     isn't there either, so the path itself is bad.
;-----------------------------------------------------------------------
; FujiNet's MKDIR reply carries NO error detail at all -- confirmed
; from fujinet-firmware source (lib/bus/rs232/rs232.cpp,
; transaction_error(): a bare NAK, zero payload, for this whole command
; family). There is no GET_ERROR for RS232 (that command only exists on
; the AdamNet backend) and process_fs() never sets the STATUS error
; byte either. So "denied" vs. "parent path does not exist" above is an
; inference from a second probe against the parent directory, not
; something FujiNet actually told us -- the best this protocol allows.
;-----------------------------------------------------------------------
; Traced from fujinet-firmware source (lib/device/rs232/network.cpp,
; rs232Network::process_fs()) and verified live -- see
; Reference/fujinet/rs232-protocol.md's MKDIR section. No persistent
; channel is created by MKDIR itself (process_fs calls fs->mkdir()
; directly, not fs->open()) -- the existence probe is the only real
; OPEN this program performs.
;-----------------------------------------------------------------------
; v1.2: RECVPK no longer waits forever for a reply. If FujiNet-PC never
; answers at all -- its own connect attempt to a dead/unreachable
; remote hanging, say -- the guest has no way to notice on its own
; (there is no interrupt-driven timeout, no BDOS timer call used
; anywhere in this program). RECVPK now gives up after a bounded
; busy-wait (TOOUTR below) and reports it directly rather than hanging.
; This budget is approximate and CPU-clock-speed-dependent, not a
; calibrated number of seconds -- see TOOUTR's own comment.
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
RDCON   EQU     1               ; console input, echoed

CR      EQU     0DH
LF      EQU     0AH

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

;---- The FujiNet RS232 wire protocol (Reference/fujinet/rs232-protocol.md)
NETDEV  EQU     71H
CMDOPEN EQU     4FH
CMDMKD  EQU     2AH             ; NETCMD_MKDIR
CMDCLOS EQU     43H
ACKCMD  EQU     06H

ACCDIR  EQU     06H             ; access mode: DIRECTORY -- the probe's
                                ; existence check, same as FUJIDIR's
DIRFRAW EQU     83H             ; "translation" byte repurposed as
                                ; format: DIR_FORMAT::RAW

SLPEND  EQU     0C0H
SLPESC  EQU     0DBH
SLPEEND EQU     0DCH
SLPEESC EQU     0DDH

SPECLEN EQU     100             ; room for SPEC/PARENT, including the NUL

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

;---- Does it already exist? (directory-mode OPEN as an existence probe.
; MUST probe with a trailing '/' -- a bare last segment is treated as a
; wildcard PATTERN against the parent, which ACKs whenever the parent
; is merely non-empty, regardless of whether anything actually matches.)
        CALL    MKPRBS          ; SPEC -> PROBESPC, with a trailing '/'
        LXI     H,PROBESPC
        SHLD    SRCPTR
        CALL    MKOPEN
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        CPI     ACKCMD
        JNZ     TRYMKD          ; NAK -- not there, go straight to creating it

        CALL    MKCLOSE         ; release the probe-open channel first
        CALL    SENDPK
        CALL    RECVPK

        CALL    ASKEXS          ; "already exists. Create anyway? (Y/N)"
        JNZ     DOCANC          ; anything but Y -- stop, nothing attempted

;---- Attempt the real MKDIR -------------------------------------------
TRYMKD: CALL    MKMKD
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        STA     RESULT          ; save before CLOSE's own reply overwrites RXBUF

        CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK

        LDA     RESULT
        CPI     ACKCMD
        JNZ     DIAGN

        CALL    SAYOK
        JMP     0

DOCANC: CALL    SAYCNC
        JMP     0

;-----------------------------------------------------------------------
; DIAGN -- MKDIR itself was NAK'd, and the probe above already ruled
; out "it's already there." Probe the PARENT directory instead: if it
; exists, MKDIR's failure is almost certainly permission/read-only; if
; the parent doesn't exist either, the path itself is bad.
;-----------------------------------------------------------------------
DIAGN:  CALL    MKPRNT
        LDA     PVALID
        ORA     A
        JZ      DOSDEN          ; couldn't even determine a parent -- default

        LXI     H,PARENT
        SHLD    SRCPTR
        CALL    MKOPEN
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1

        PUSH    PSW
        CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK
        POP     PSW

        CPI     ACKCMD
        JZ      DOSDEN          ; parent exists -- so it's permission/server-side
        CALL    SAYBAD
        JMP     0

DOSDEN: CALL    SAYDEN
        JMP     0

;=======================================================================
; BUILDING PACKETS -- see Reference/fujinet/rs232-protocol.md; identical
; shape to CPM Tools/FUJIDIR.ASM's/FUJIGET.ASM's MKxxx routines. MKOPEN
; embeds whichever string SRCPTR points at (SPEC for the existence
; probe, PARENT for the diagnostic probe) instead of always using SPEC.
;=======================================================================

MKOPEN: LHLD    SRCPTR
        XCHG                    ; DE = the string to embed
        LXI     H,TXBUF
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
        MVI     M,DIRFRAW
        INX     H
MKO1:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        ORA     A
        JNZ     MKO1
        LXI     D,TXBUF
        JMP     SETLEN

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
; MKPRBS -- copy SPEC into PROBESPC, appending a trailing '/' if SPEC
; doesn't already end in one. See the comment at the exists-probe call
; site above for why this matters.
;-----------------------------------------------------------------------
MKPRBS: LXI     H,SPEC
        LXI     D,PROBESPC
MKB1:   MOV     A,M
        ORA     A
        JZ      MKB2
        STAX    D
        INX     H
        INX     D
        JMP     MKB1
MKB2:   DCX     D               ; DE -> last copied character
        LDAX    D
        CPI     '/'
        JZ      MKB3
        INX     D
        MVI     A,'/'
        STAX    D
MKB3:   INX     D
        XRA     A
        STAX    D
        RET

;-----------------------------------------------------------------------
; MKPRNT -- build PARENT (NUL-terminated) as the parent directory of
; SPEC's path: strip one trailing '/' if present, then everything up to
; and including the previous '/'. PVALID is set to 1 if a boundary was
; found (PARENT is ready to use), 0 if not (caller should skip the
; parent probe and default to "denied").
;-----------------------------------------------------------------------
MKPRNT: MVI     B,0FFH          ; B = index of the second-to-last '/' seen
        MVI     C,0FFH          ; C = index of the last '/' seen
        MVI     E,0             ; E = running index into SPEC
        LXI     H,SPEC
MPSCAN: MOV     A,M
        ORA     A
        JZ      MPDONE
        CPI     '/'
        JNZ     MPNEXT
        MOV     B,C
        MOV     C,E
MPNEXT: INX     H
        INR     E
        JMP     MPSCAN

MPDONE: MOV     A,C
        CPI     0FFH
        JZ      MPNONE          ; no '/' anywhere -- no parent determinable
        DCR     E               ; E = index of the last real character
        MOV     A,E
        CMP     C
        JNZ     MPGOTB          ; last char isn't a '/' -- boundary = C
        MOV     A,B
        CPI     0FFH
        JZ      MPNONE          ; the only '/' was that trailing one
        MOV     C,A             ; boundary = the second-to-last '/' instead

MPGOTB: LXI     H,SPEC
        LXI     D,PARENT
        MOV     A,C
        INR     A               ; bytes to copy = boundary+1 (keep the '/')
        MOV     C,A
MPCPY:  MOV     A,C
        ORA     A
        JZ      MPTERM
        MOV     A,M
        STAX    D
        INX     H
        INX     D
        DCR     C
        JMP     MPCPY
MPTERM: XRA     A
        STAX    D
        MVI     A,1
        STA     PVALID
        RET

MPNONE: XRA     A
        STA     PVALID
        RET

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

;-----------------------------------------------------------------------
; RECVPK -- waits for the reply's leading SLPEND sync byte with a
; bounded busy-wait (TOOUTR outer passes x a full 16-bit inner
; countdown): if nothing at all comes back, print MNORE and quit rather
; than hang forever. Once the sync byte is seen, the rest of the packet
; is read with no further timeout -- a stall mid-packet, after real
; framing has started, is a different (and much rarer) failure than
; "no response at all," and out of scope here.
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
        CALL    SAYNORE         ; gave up -- no reply at all
        JMP     0

RPGOTB: IN      SIODT
        CPI     SLPEND
        JNZ     RPSYNC          ; noise, not the sync byte -- keep waiting
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

;-----------------------------------------------------------------------
; ASKEXS -- print "<url> already exists. Create anyway? (Y/N)", read a
; raw keystroke, fold to uppercase, always print a CRLF regardless of
; the answer (the exact bug FUJIGET/FUJIPUT v1.1 fixed for their own
; Replace? prompt), then return with Z set iff the answer was 'Y'.
;-----------------------------------------------------------------------
ASKEXS: LXI     D,MEXS1
        MVI     C,PRSTR
        CALL    BDOS
        LXI     H,SPEC
        CALL    PSTR
        LXI     D,MEXS2
        MVI     C,PRSTR
        CALL    BDOS

        MVI     C,RDCON
        CALL    BDOS
        ANI     5FH             ; fold lower-case to upper
        PUSH    PSW             ; save the answer -- MCRLF below clobbers A
        LXI     D,MCRLF
        MVI     C,PRSTR
        CALL    BDOS
        POP     PSW
        CPI     'Y'
        RET

SAYOK:  LXI     D,MOK
        MVI     C,PRSTR
        JMP     BDOS

SAYNORE:LXI     D,MNORE
        MVI     C,PRSTR
        JMP     BDOS

SAYCNC: LXI     D,MCANC
        MVI     C,PRSTR
        JMP     BDOS

SAYDEN: LXI     D,MDENY
        MVI     C,PRSTR
        JMP     BDOS

SAYBAD: LXI     D,MBADP
        MVI     C,PRSTR
        JMP     BDOS

USAGE:  LXI     D,MUSAGE
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

;=======================================================================
; DATA
;=======================================================================
MCRLF:  DB      CR,LF,'$'
MEXS1:  DB      'FUJIMKD: $'
MEXS2:  DB      ' already exists. Create anyway? (Y/N) $'
MCANC:  DB      CR,LF,'FUJIMKD: cancelled.',CR,LF,'$'
MOK:    DB      CR,LF,'FUJIMKD: directory created.',CR,LF,'$'
MNORE:  DB      CR,LF,'FUJIMKD: destination server not'
        DB      ' responding.',CR,LF,'$'
MDENY:  DB      CR,LF,'FUJIMKD: denied (permission or server'
        DB      ' restriction).',CR,LF,'$'
MBADP:  DB      CR,LF,'FUJIMKD: failed -- parent path does not'
        DB      ' exist.',CR,LF,'$'

MUSAGE: DB      CR,LF,'FUJIMKD v1.2 -- create a directory through'
        DB      ' FujiNet''s N: network device.',CR,LF,CR,LF
        DB      '   FUJIMKD N:<url>',CR,LF,CR,LF
        DB      'Example',CR,LF
        DB      '   FUJIMKD N1:TNFS://tnfs.mitsaltair.com/NEWDIR'
        DB      CR,LF,'$'

;---- Variables ---------------------------------------------------------
SPEC:     DS    SPECLEN
PARENT:   DS    SPECLEN
PROBESPC: DS    SPECLEN
SRCPTR:   DS    2
PVALID: DS      1
RESULT: DS      1
TOCNT:  DS      1

TXBUF:  DS      200
RXBUF:  DS      200

        DS      64              ; stack
STACK   EQU     $

        END     START
