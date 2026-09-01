;-----------------------------------------------------------------------
; FUJIPUT.COM v1.4 -- send a file through FujiNet's N: network device.
;
;       FUJIPUT file.ext N:<url> [B|T]     e.g.  FUJIPUT HELLO.TXT N1:TNFS://192.168.1.5/HELLO.TXT T
;
; Opens the CP/M file first (fail before anything remote is touched), then
; opens <url> for write on FujiNet's N: device and streams the file's
; records up. The mirror image of FUJIGET.COM -- see that file's header
; and Reference/pcget-pcput/README.md for the shared lineage.
;
;-----------------------------------------------------------------------
; B OR T, AND B IS THE DEFAULT -- exactly W.COM's reasoning (see its own
; header comment for the long version): CP/M keeps no byte count, so the
; last record is padded with ^Z, and coming back OUT those pad bytes are
; indistinguishable from real data. B (default) sends every byte of every
; record, exactly -- a .COM survives the trip, a text file arrives with
; up to 127 trailing ^Z. T stops at the first ^Z -- clean for text, but
; TRUNCATES a binary file that happens to contain a 1AH byte, which is
; why it is not the default.
;
; ORDER IS LOAD-BEARING, the mirror of FUJIGET's reasoning: opening the
; network side for write may CREATE OR TRUNCATE a remote file, so the
; CP/M source must be proven to exist first. Fail first, destroy nothing.
;
; Clobbering a CP/M file is a bad day for one person; clobbering a remote
; file is a bad day for everyone else who uses that server. So before the
; real (write) open, PROBE opens the same URL read-only first: NETCMD_OPEN
; in read mode ACKs iff the target already exists and NAKs if not (verified
; live 2026-08-27, Reference/fujinet/rs232-protocol.md). If it exists, ask
; "Replace? (Y/N)" before ever opening for write. This only means something
; for a target where "exists" is meaningful (TNFS, SD, HTTP) -- a raw
; TCP:// stream has no file to find, so the probe just NAKs there and
; nothing is asked, same as "not present".
;
; If the real write-mode OPEN fails anyway (the target wasn't found by
; the probe above, or the user said Replace and it failed regardless),
; FujiNet's NAK carries no error detail at all (confirmed from firmware
; source -- see Reference/fujinet/rs232-protocol.md and FUJIMKD.ASM's
; header for the full explanation). Instead, probe the PARENT directory
; (a directory-mode OPEN, WITH a trailing slash -- see the same
; reference for why a bare last segment is a wildcard pattern, not an
; exact check): if it exists, the failure is almost certainly a
; permission/read-only restriction; if the parent doesn't exist either,
; the path itself is bad. Same technique as FUJIMKD.ASM's DIAGN.
;-----------------------------------------------------------------------
; v1.3: RECVPK no longer waits forever for a reply. If FujiNet-PC never
; answers at all -- its own connect attempt to a dead/unreachable
; remote hanging, say -- the guest has no way to notice on its own
; (there is no interrupt-driven timeout, no BDOS timer call used
; anywhere in this program). RECVPK now gives up after a bounded
; busy-wait (TOOUTR below) and reports it directly rather than hanging.
; This budget is approximate and CPU-clock-speed-dependent, not a
; calibrated number of seconds -- see TOOUTR's own comment.
;-----------------------------------------------------------------------
; v1.4: a large transfer used to print nothing at all until the final
; "NNN records sent," leaving no sign of life for however long that
; took. Rather than a dot per 128-byte record (would scroll the screen
; on anything but a small file), CPLOOP now prints "Sent NNNN KB..." in
; place (a bare CR, no LF, so each update overwrites the last) once
; every 8 records = 1024 bytes -- see PROGCK/SAYPROG below. Same
; technique as FUJIGET.ASM v1.4; see that file for the fuller comment.
;-----------------------------------------------------------------------
; AND BDOS CLOBBERS EVERY REGISTER (A,B,C,D,E,H,L -- only SP survives).
;-----------------------------------------------------------------------
; Assemble it INSIDE the machine:
;
;       ASM FUJIPUT             -> FUJIPUT.HEX
;       LOAD FUJIPUT            -> FUJIPUT.COM
;-----------------------------------------------------------------------

        ORG     100H

;---- CP/M ---------------------------------------------------------------
BDOS    EQU     0005H
TAIL    EQU     0080H
TFCB    EQU     005CH           ; the CCP's own parse -- see W.ASM's INIFCB
                                ; comment for why it's safe to use here: our
                                ; FIRST argument is an 8.3 CP/M name, so the
                                ; CCP's own parse is exactly right for it.

CONOUT  EQU     2
DIRIO   EQU     6
PRSTR   EQU     9

FOPEN   EQU     15
FREAD   EQU     20              ; read sequential
FSETDMA EQU     26
RDCON   EQU     1               ; console input, echoed

CR      EQU     0DH
LF      EQU     0AH
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

;---- The FujiNet RS232 wire protocol (Reference/fujinet/rs232-protocol.md)
NETDEV  EQU     71H
CMDOPEN EQU     4FH
CMDCLOS EQU     43H
CMDWRIT EQU     57H
ACKCMD  EQU     06H

ACCWR   EQU     08H             ; access mode: write only
ACCRD   EQU     04H             ; access mode: read only (the probe)
TRANONE EQU     00H             ; translation: none (binary)

ACCDIR  EQU     06H             ; access mode: DIRECTORY -- the parent-
                                ; directory diagnostic probe, post-failure
DIRFRAW EQU     83H             ; "translation" byte repurposed as format:
                                ; DIR_FORMAT::RAW

SLPEND  EQU     0C0H
SLPESC  EQU     0DBH
SLPEEND EQU     0DCH
SLPEESC EQU     0DDH

SPECLEN EQU     100             ; room for SPEC, including the NUL
JUNKLEN EQU     20              ; room to park the (unused) filename token

;=======================================================================
; MAIN
;=======================================================================
START:  LXI     SP,STACK

        CALL    INIFCB          ; the CCP's FCB at 5CH -> ours
        CALL    PARSE           ; tail's 2nd/3rd words -> SPEC, MODE
        LDA     SPEC
        ORA     A
        JZ      USAGE

;---- Open the CP/M file FIRST -- the network side is untouched so far --
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

        CALL    SAYCONN

;---- Probe read-only first: does the remote target already exist? -----
        CALL    MKPROBE
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        CPI     ACKCMD
        JNZ     PABSENT         ; NAK -- nothing there, nothing to confirm

        CALL    MKCLOSE         ; close the probe before asking
        CALL    SENDPK
        CALL    RECVPK
        CALL    CKREPLACE       ; asks Y/N; exits the program if declined

PABSENT:
        CALL    MKOPEN
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        CPI     ACKCMD
        JNZ     EFAIL

        CALL    SAYOK

        LXI     H,0
        SHLD    RECS
        SHLD    KCNT            ; nothing reported to the user yet either
        XRA     A
        STA     LASTFLG

;-----------------------------------------------------------------------
; CPLOOP -- poll for a Ctrl-C abort, read one CP/M record, work out how
; much of it is real (all 128 in B mode; up to the first ^Z in T mode,
; which also ends the transfer), and write that much.
;-----------------------------------------------------------------------
CPLOOP: MVI     E,0FFH
        MVI     C,DIRIO
        CALL    BDOS
        ORA     A
        JZ      CPGO
        CPI     CTRLC
        JZ      ABORT

CPGO:   LXI     D,FCB
        MVI     C,FREAD
        CALL    BDOS
        ORA     A
        JNZ     PDONE           ; 1 = EOF; anything else is also an end

        LHLD    RECS            ; count it now -- T mode may stop partway
        INX     H               ; through this very record, and it was
        SHLD    RECS            ; still read
        CALL    PROGCK          ; every 8th record (1KB): update the user

        LDA     MODE
        CPI     'T'
        JZ      CPSCAN

        MVI     A,RECLEN        ; binary: the whole record, always
        STA     WLEN
        XRA     A
        STA     WLEN+1
        JMP     CPSEND

;---- text mode: find the first ^Z in this record, if any ---------------
CPSCAN: LXI     H,BUF
        MVI     B,RECLEN
        MVI     C,0
CPS1:   MOV     A,M
        CPI     CPMEOF
        JZ      CPSFND
        INX     H
        INR     C
        DCR     B
        JNZ     CPS1

        MVI     A,RECLEN        ; no ^Z here -- send it whole, keep going
        STA     WLEN
        XRA     A
        STA     WLEN+1
        JMP     CPSEND

CPSFND: MOV     A,C             ; C = how many real bytes precede the ^Z
        STA     WLEN
        XRA     A
        STA     WLEN+1
        MVI     A,1
        STA     LASTFLG         ; this is the last thing we send, ^Z or not

CPSEND: LDA     WLEN
        ORA     A
        JZ      CPCHK           ; nothing to send this round (^Z was byte 0)

        CALL    MKWRITE
        CALL    SENDPK
        CALL    RECVPK          ; the WRITE's ACK -- not checked, same as
                                ; NC.ASM's MLOOP: a dropped link shows up
                                ; some other way, and this keeps the loop
                                ; simple for what is otherwise a one-shot
                                ; bulk transfer

CPCHK:  LDA     LASTFLG
        ORA     A
        JNZ     PDONE
        JMP     CPLOOP

;-----------------------------------------------------------------------
; PDONE -- close both sides, report how much went, and exit.
;-----------------------------------------------------------------------
PDONE:  CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK
        CALL    SAYDONE
        JMP     0

ABORT:  CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK
        CALL    SAYABRT
        JMP     0

;-----------------------------------------------------------------------
; EFAIL -- the real write-mode OPEN was NAK'd. Probe the PARENT
; directory to guess why: if it exists, this is almost certainly
; permission/read-only; if the parent doesn't exist either, the path
; itself is bad. See this file's header for why it's only a guess.
;-----------------------------------------------------------------------
EFAIL:  CALL    MKPRNT
        LDA     PVALID
        ORA     A
        JZ      DOSDEN          ; couldn't even determine a parent -- default

        LXI     H,PARENT
        SHLD    SRCPTR
        CALL    MKDPROB
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

ENOCPM: CALL    SAYNOCPM
        JMP     0

;-----------------------------------------------------------------------
; CKREPLACE -- the probe already found the remote target existing, and
; its connection is already closed. Ask before opening it again for
; write. Falls through (RET) if the user says yes; exits the whole
; program without ever opening for write if not.
;-----------------------------------------------------------------------
CKREPLACE:
        LXI     D,MEXIST
        MVI     C,PRSTR
        CALL    BDOS
        LXI     H,SPEC
        CALL    PSTR
        LXI     D,MEXIST2
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
        RZ                      ; yes -- proceed to the real open

        CALL    SAYSKIP
        JMP     0

;-----------------------------------------------------------------------
; PROGCK -- called after every record read. RECS just advanced, so its
; low 3 bits are 0 exactly every 8th record (128*8 = 1024 bytes);
; anything else, return immediately without touching KCNT or the screen.
; On a hit, bump KCNT (the running KB count) and print it in place.
;-----------------------------------------------------------------------
PROGCK: LHLD    RECS
        MOV     A,L
        ANI     07H
        RNZ
        LHLD    KCNT
        INX     H
        SHLD    KCNT
        JMP     SAYPROG

;-----------------------------------------------------------------------
; SAYPROG -- "\rSent NNNN KB..." with no trailing CR/LF, so the next call
; overwrites this line instead of scrolling. KCNT only grows during one
; run, so a shorter new number can never leave a stale digit behind from
; a longer old one.
;-----------------------------------------------------------------------
SAYPROG:MVI     E,CR
        MVI     C,CONOUT
        CALL    BDOS
        LXI     D,MPROGP
        MVI     C,PRSTR
        CALL    BDOS
        LHLD    KCNT
        CALL    PRDEC
        LXI     D,MPROGS
        MVI     C,PRSTR
        JMP     BDOS

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
        MVI     M,ACCWR
        INX     H
        MVI     M,TRANONE
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

;-----------------------------------------------------------------------
; MKPROBE -- exactly MKOPEN, but read-only: the overwrite-existence
; check. Never touches the remote target, only asks whether it's there.
;-----------------------------------------------------------------------
MKPROBE:LXI     H,TXBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDOPEN
        INX     H
        INX     H
        INX     H
        INX     H
        MVI     M,2             ; descr: two 1-byte params
        INX     H
        MVI     M,ACCRD
        INX     H
        MVI     M,TRANONE
        INX     H
        LXI     D,SPEC
MKP1:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        ORA     A
        JNZ     MKP1
        LXI     D,TXBUF
        JMP     SETLEN

;-----------------------------------------------------------------------
; MKDPROB -- a directory-mode OPEN against whatever SRCPTR points at
; (always PARENT here, which MKPRNT already guarantees ends in '/') --
; the post-failure diagnostic probe. See Reference/fujinet/rs232-
; protocol.md for why the trailing slash is mandatory.
;-----------------------------------------------------------------------
MKDPROB:LHLD    SRCPTR
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
MKD1:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        ORA     A
        JNZ     MKD1
        LXI     D,TXBUF
        JMP     SETLEN

;-----------------------------------------------------------------------
; MKPRNT -- build PARENT (NUL-terminated) as the parent directory of
; SPEC's path: strip one trailing '/' if present, then everything up to
; and including the previous '/'. PVALID is set to 1 if a boundary was
; found (PARENT is ready to use), 0 if not (caller should skip the
; parent probe and default to "denied"). Identical to FUJIMKD.ASM's.
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
; MKWRITE -- build a WRITE for WLEN bytes, copied from BUF. WLEN is
; 0..128, so its high byte is always 0 and B alone is enough to count.
;-----------------------------------------------------------------------
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
        LDA     WLEN
        MOV     M,A
        INX     H
        LDA     WLEN+1
        MOV     M,A
        INX     H
        LXI     D,BUF
        LDA     WLEN
        MOV     B,A
MKW1:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        DCR     B
        JNZ     MKW1
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
; THE COMMAND TAIL
;
; Our first word is an 8.3 filename -- already in FCB via INIFCB, so we
; just need to skip over it here. The second word is the URL (hand-
; parsed, not the CCP's parse -- a URL is not an 8.3 name). The optional
; third word is the B|T switch, exactly W.ASM's PARSE/SETMOD/EBADSW idea,
; simplified since our switch always lives in a fixed third slot (W.COM's
; own second slot is ambiguous between a host name and a switch; ours
; is not, because our second slot is always the URL).
;=======================================================================
PARSE:  LXI     H,TAIL
        MOV     B,M
        INX     H

        CALL    SKIPSP
        LXI     D,JUNK
        MVI     C,JUNKLEN
        CALL    TOKEN           ; discard word 1 -- FCB already has it

        CALL    SKIPSP
        LXI     D,SPEC
        MVI     C,SPECLEN
        CALL    TOKEN           ; word 2 -> SPEC

        CALL    SKIPSP
        LXI     D,SWBUF
        MVI     C,3
        CALL    TOKEN           ; word 3 (optional) -> SWBUF

        MVI     A,'B'
        STA     MODE            ; default

        LDA     SWBUF
        ORA     A
        RZ                      ; no third word -- B stands

        LDA     SWBUF+1
        ORA     A
        JNZ     EBADSW          ; longer than one character

        LDA     SWBUF
        CPI     'B'
        RZ                      ; 'B' -- matches the default already set
        CPI     'T'
        JNZ     EBADSW

        MVI     A,'T'
        STA     MODE
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

SAYNORE:LXI     D,MNORE
        MVI     C,PRSTR
        JMP     BDOS

SAYDEN: LXI     D,MDENY
        MVI     C,PRSTR
        JMP     BDOS

SAYBAD: LXI     D,MBADP
        MVI     C,PRSTR
        JMP     BDOS

SAYABRT:LXI     D,MABRT
        MVI     C,PRSTR
        JMP     BDOS

SAYNOCPM:
        LXI     D,MNOCPM
        MVI     C,PRSTR
        JMP     BDOS

SAYSKIP:LXI     D,MSKIP
        MVI     C,PRSTR
        JMP     BDOS

;-----------------------------------------------------------------------
; SAYDONE -- "NNN records sent." PRDEC/DIV10 copied from HDIR.ASM.
;-----------------------------------------------------------------------
SAYDONE:LXI     D,MCRLF
        MVI     C,PRSTR
        CALL    BDOS
        LHLD    RECS
        CALL    PRDEC
        LXI     D,MRECS
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

EBADSW: LXI     D,MEBADSW
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

;=======================================================================
; DATA
;=======================================================================
MCONN:  DB      'FUJIPUT: opening $'
MCRLF:  DB      CR,LF,'$'
MOK:    DB      'Open OK. Sending...',CR,LF,'$'
MNORE:  DB      CR,LF,'FUJIPUT: destination server not'
        DB      ' responding.',CR,LF,'$'
MDENY:  DB      CR,LF,'FUJIPUT: denied (permission or server'
        DB      ' restriction).',CR,LF,'$'
MBADP:  DB      CR,LF,'FUJIPUT: failed -- parent path does not'
        DB      ' exist.',CR,LF,'$'
MABRT:  DB      CR,LF,'FUJIPUT: aborted.',CR,LF,'$'
MNOCPM: DB      CR,LF,'FUJIPUT: no such CP/M file.',CR,LF,'$'
MRECS:  DB      ' records sent.',CR,LF,'$'
MEXIST: DB      CR,LF,'FUJIPUT: $'
MEXIST2:DB      ' exists on the remote. Replace? (Y/N) $'
MSKIP:  DB      CR,LF,'FUJIPUT: not sent.',CR,LF,'$'
MEBADSW:DB      CR,LF,'FUJIPUT: the switch is B (every byte, the default) or'
        DB      ' T (stop at the first ^Z).',CR,LF,'$'
MPROGP: DB      'Sent $'
MPROGS: DB      ' KB...$'

MUSAGE: DB      CR,LF,'FUJIPUT v1.4 -- send a file through FujiNet''s'
        DB      ' N: network device.',CR,LF,CR,LF
        DB      '   FUJIPUT file.ext N:<url> [B|T]',CR,LF,CR,LF
        DB      'Example',CR,LF
        DB      '   FUJIPUT HELLO.TXT N1:TNFS://192.168.1.5/HELLO.TXT T',CR,LF,CR,LF
        DB      'B (the default) sends every byte of every record, so a .COM'
        DB      ' survives',CR,LF
        DB      'the trip. T stops at the first ^Z, which cleans up text but'
        DB      ' TRUNCATES',CR,LF
        DB      'anything binary.',CR,LF,'$'

;---- Variables ---------------------------------------------------------
SPEC:     DS    SPECLEN
PARENT:   DS    SPECLEN
SRCPTR:   DS    2
PVALID:   DS    1
TOCNT:  DS      1
JUNK:   DS      JUNKLEN
SWBUF:  DS      3
MODE:   DS      1
FCB:    DS      36
BUF:    DS      RECLEN
RECS:   DS      2
KCNT:   DS      2
WLEN:   DS      2
LASTFLG:DS      1

TXBUF:  DS      200
RXBUF:  DS      200
NUMEND: DS      1

        DS      64              ; stack
STACK   EQU     $

        END     START
