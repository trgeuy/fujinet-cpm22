;-----------------------------------------------------------------------
; WGET.COM v1.0 -- fetch a file through FujiNet's N: network device,
; prompting for the URL instead of taking it on the command line.
;
;       WGET file.ext
;       URL: <typed at the prompt>          e.g.  TNFS://192.168.1.5/HELLO.TXT
;
; Same engine as FUJIGET (open for read on FujiNet's N: device, stream
; the bytes into a new CP/M file, close both sides) -- the only real
; difference is where the URL comes from.
;
; WHY: CP/M's CCP uppercases the entire command tail before any program
; ever sees it -- that's a CCP-level behavior, not something a program
; can opt out of. A URL typed on the FUJIGET command line therefore
; always arrives here-case-folded, which is harmless against TNFS (this
; project already works around it server-side, see tnfs-case-fix.sh) but
; silently breaks against any case-sensitive remote -- confirmed live
; against a real HTTPS server (deramp.com): the uppercased path 404'd,
; and FujiNet's HTTP backend didn't check the status code, so FUJIGET
; reported a clean "10 records received" for what was actually a 404
; error page, not the real file.
;
; BDOS function 10 (Read Console Buffer), unlike the CCP's own line
; parse, does NOT fold case -- it is a raw line-editing read with no
; case-conversion of its own. Prompting for the URL at runtime instead
; of parsing it from TAIL sidesteps the CCP entirely, so mixed-case
; URLs survive intact. Confirmed live: WGET against the same deramp.com
; path (this time typed in its real mixed-case form at the prompt)
; fetched the genuine file, byte-identical to a direct download.
;
; Everything else -- CKEXIST, the OPEN/READ/CLOSE loop, progress
; reporting, parent-probe error diagnosis, the RECVPK response timeout
; -- is FUJIGET.ASM's engine, unchanged. See that file's own header and
; Reference/fujinet/rs232-protocol.md for how all of that works.
;
; Assemble it INSIDE the machine:
;
;       ASM WGET                -> WGET.HEX
;       LOAD WGET                -> WGET.COM
;
;-----------------------------------------------------------------------
; AND BDOS CLOBBERS EVERY REGISTER (A,B,C,D,E,H,L -- only SP survives).
; Nothing may be left live in a register across CALL BDOS.
;-----------------------------------------------------------------------

        ORG     100H

;---- CP/M ---------------------------------------------------------------
BDOS    EQU     0005H
TAIL    EQU     0080H           ; the command tail: length, then the text

CONOUT  EQU     2               ; E = char
DIRIO   EQU     6               ; direct console I/O: E=0FFH polls input
PRSTR   EQU     9               ; DE = string, '$'-terminated
RDBUF   EQU     10              ; read console buffer (line, no case fold)

FCLOSE  EQU     16
FDELET  EQU     19
FWRITE  EQU     21              ; write sequential
FMAKE   EQU     22
FSETDMA EQU     26
RDCON   EQU     1               ; console input, echoed
SFIRST  EQU     17              ; search first -- read-only, doesn't touch the dir

CR      EQU     0DH
LF      EQU     0AH
CTRLC   EQU     03H
CPMEOF  EQU     1AH             ; ^Z -- pads the last, partial record

RECLEN  EQU     128             ; a CP/M record

;---- The 2SIO card, unit b -----------------------------------------------
SIOST   EQU     12H
SIODT   EQU     13H
SIORST  EQU     03H
SIOCTL  EQU     15H

;---- How long RECVPK waits for a reply before giving up -----------------
TOOUTR  EQU     10

;---- The FujiNet RS232 wire protocol (Reference/fujinet/rs232-protocol.md)
NETDEV  EQU     71H
CMDOPEN EQU     4FH
CMDCLOS EQU     43H
CMDREAD EQU     52H
CMDSTAT EQU     53H
ACKCMD  EQU     06H

ACCRD   EQU     04H             ; access mode: read only
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
NAMLEN  EQU     20              ; room for NAME, including the NUL

;=======================================================================
; MAIN
;=======================================================================
START:  LXI     SP,STACK

        CALL    PARSE           ; tail -> NAME (the local filename)
        LDA     NAME
        ORA     A
        JZ      USAGE

        CALL    GETURL          ; prompt -> SPEC (the URL, case intact)
        LDA     SPEC
        ORA     A
        JZ      USAGE

        LXI     H,NAME
        CALL    MKFCB           ; NAME -> FCB (ours, not the CCP's at 5CH)

        CALL    CKEXIST         ; ask before clobbering an existing file

        MVI     A,SIORST        ; the ACIA out of reset...
        OUT     SIOST
        MVI     A,SIOCTL        ; ...and into a real operating mode
        OUT     SIOST

        CALL    SAYCONN

        CALL    MKOPEN
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        CPI     ACKCMD
        JNZ     EFAIL

        CALL    SAYOK

;---- Only now touch the CP/M file -- the network side is proven open ---
        LXI     D,FCB
        MVI     C,FDELET
        CALL    BDOS            ; 0FFH = there wasn't one, fine

        LXI     D,FCB
        MVI     C,FMAKE
        CALL    BDOS
        CPI     0FFH
        JZ      ENODIR          ; directory full

        LXI     D,BUF
        MVI     C,FSETDMA
        CALL    BDOS            ; where BDOS reads/writes each record

        XRA     A
        STA     RECPOS          ; nothing buffered yet
        LXI     H,0
        SHLD    RECS
        SHLD    KCNT            ; nothing reported to the user yet either

;-----------------------------------------------------------------------
; RLOOP -- poll for a Ctrl-C abort, then ask STATUS. If FujiNet has bytes
; waiting, READ up to however much room is left in the current 128-byte
; record and copy it in; when a record fills, write it. Connected=0 with
; nothing waiting is a clean end of file, not an error.
;-----------------------------------------------------------------------
RLOOP:  MVI     E,0FFH
        MVI     C,DIRIO
        CALL    BDOS
        ORA     A
        JZ      RPOLL
        CPI     CTRLC
        JZ      ABORT

RPOLL:  CALL    MKSTAT
        CALL    SENDPK
        CALL    RECVPK

        LDA     RXBUF+6         ; bytes_waiting, lo
        MOV     D,A
        LDA     RXBUF+7         ; bytes_waiting, hi
        ORA     D
        JNZ     RGOT            ; something waiting -- go read it

        LDA     RXBUF+8         ; connected
        ORA     A
        JNZ     RLOOP           ; still connected, nothing waiting yet
        JMP     RDONE           ; connected=0, nothing waiting: real EOF

;---- REQLEN = min(bytes_waiting, room left in the current record) -----
RGOT:   LDA     RECPOS
        MOV     C,A
        MVI     A,RECLEN
        SUB     C
        MOV     C,A             ; C = room left (1..128 -- RECPOS<128 always here)

        LDA     RXBUF+7         ; bw hi
        ORA     A
        JNZ     RQROOM          ; bw >= 256, certainly > room

        LDA     RXBUF+6         ; bw lo (bw is 0..255 since hi=0)
        CMP     C
        JC      RQBW            ; bw < room -- A already holds bw
        JMP     RQROOM          ; bw >= room -- use room

RQBW:   STA     REQLEN
        JMP     RQGO
RQROOM: MOV     A,C
        STA     REQLEN
RQGO:   XRA     A
        STA     REQLEN+1        ; hi byte always 0 -- REQLEN never exceeds 128

        CALL    MKREAD
        CALL    SENDPK
        CALL    RECVPK

;---- copy REQLEN bytes from RXBUF+6 into BUF+RECPOS --------------------
        LXI     H,BUF
        LDA     RECPOS
        MOV     E,A
        MVI     D,0
        DAD     D               ; HL = BUF+RECPOS
        LXI     D,RXBUF+6
        LDA     REQLEN
        MOV     B,A
RCPY:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        DCR     B
        JNZ     RCPY

        LDA     RECPOS
        MOV     C,A
        LDA     REQLEN
        ADD     C
        STA     RECPOS
        CPI     RECLEN
        JNZ     RLOOP           ; still partial -- go poll again
        CALL    RFLUSH
        CALL    PROGCK          ; every 8th record (1KB): update the user
        JMP     RLOOP

;-----------------------------------------------------------------------
; RDONE -- true EOF. Pad and flush any partial final record, close both
; sides, report how much arrived, and exit.
;-----------------------------------------------------------------------
RDONE:  LDA     RECPOS
        ORA     A
        JZ      RCLOSE          ; nothing partial pending

        LXI     H,BUF
        LDA     RECPOS
        MOV     E,A
        MVI     D,0
        DAD     D               ; HL = BUF+RECPOS, the first pad byte
        MVI     A,RECLEN
        SUB     E                ; A = 128-RECPOS = bytes to pad (E still holds RECPOS)
        MOV     B,A
        MVI     A,CPMEOF
RPAD:   MOV     M,A
        INX     H
        DCR     B
        JNZ     RPAD
        CALL    RFLUSH

RCLOSE: CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK

        LXI     D,FCB
        MVI     C,FCLOSE
        CALL    BDOS
        CPI     0FFH
        JZ      ECLOSE

        CALL    SAYDONE
        JMP     0

;-----------------------------------------------------------------------
; RFLUSH -- write the current record (full, or padded by the caller),
; then reset RECPOS and bump RECS. Does its own DE=FCB/BDOS call, so it
; must not be entered with anything live that needs to survive BDOS.
;-----------------------------------------------------------------------
RFLUSH: LXI     D,FCB
        MVI     C,FWRITE
        CALL    BDOS
        ORA     A
        JNZ     EWRITE
        XRA     A
        STA     RECPOS
        LHLD    RECS
        INX     H
        SHLD    RECS
        RET

;-----------------------------------------------------------------------
; PROGCK -- called after every completed record. RECS just advanced, so
; its low 3 bits are 0 exactly every 8th record (128*8 = 1024 bytes);
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
; SAYPROG -- "\rReceived NNNN KB..." with no trailing CR/LF, so the next
; call overwrites this line instead of scrolling. KCNT only grows during
; one run, so a shorter new number can never leave a stale digit behind
; from a longer old one.
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

ABORT:  CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK
        LXI     D,FCB
        MVI     C,FCLOSE
        CALL    BDOS
        CALL    SAYABRT
        JMP     0

;-----------------------------------------------------------------------
; EFAIL -- the real OPEN was NAK'd. Probe the PARENT directory to guess
; why: if it exists, the target almost certainly just isn't there; if
; the parent doesn't exist either, the path itself is bad. See FUJIGET's
; own header for why "not found" (not "denied") is the right default
; here, unlike FUJIPUT.
;-----------------------------------------------------------------------
EFAIL:  CALL    MKPRNT
        LDA     PVALID
        ORA     A
        JZ      DOSNF           ; couldn't even determine a parent -- default

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
        JZ      DOSNF           ; parent exists -- so the target just isn't there
        CALL    SAYBAD
        JMP     0

DOSNF:  CALL    SAYNFND
        JMP     0

ENODIR: CALL    MKCLOSE
        CALL    SENDPK
        CALL    RECVPK
        CALL    SAYNODIR
        JMP     0

ECLOSE: CALL    SAYECLOS
        JMP     0

EWRITE: CALL    SAYEWRIT
        JMP     0

;-----------------------------------------------------------------------
; CKEXIST -- if the destination CP/M file already exists, ask before
; continuing. SEARCH FIRST only reads the directory -- nothing is
; touched -- so this runs before the network side is even opened;
; declining costs nothing because nothing has happened yet.
;-----------------------------------------------------------------------
CKEXIST:LXI     D,FCB
        MVI     C,SFIRST
        CALL    BDOS
        CPI     0FFH
        RZ                      ; not found -- nothing to confirm

        LXI     D,MEXIST
        MVI     C,PRSTR
        CALL    BDOS
        LXI     H,NAME
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
        RZ                      ; yes -- proceed

        CALL    SAYSKIP
        JMP     0

;-----------------------------------------------------------------------
; GETURL -- prompt for the URL and read it with BDOS function 10 (Read
; Console Buffer), a raw line-editing read that does NOT fold case --
; unlike the CCP's own command-line parse, this is what lets a mixed-
; case URL survive intact. See this file's header for why that matters.
;
; LBUF's format is BDOS 10's own: byte 0 = max chars (set before the
; call), byte 1 = actual chars read (set by BDOS), byte 2.. = the
; characters themselves -- no CR, no NUL. Copied into SPEC and
; NUL-terminated here so the rest of the program (MKOPEN, MKPRNT, ...)
; can treat SPEC exactly like FUJIGET's tail-parsed one.
;-----------------------------------------------------------------------
GETURL: LXI     D,MURL
        MVI     C,PRSTR
        CALL    BDOS

        LXI     D,LBUF
        MVI     C,RDBUF
        CALL    BDOS

        LXI     D,MCRLF         ; BDOS 10 echoes the typed CR with no LF
        MVI     C,PRSTR
        CALL    BDOS

        LDA     LBUF+1          ; actual character count
        MOV     C,A
        LXI     H,LBUF+2
        LXI     D,SPEC
GU1:    MOV     A,C
        ORA     A
        JZ      GUDONE
        MOV     A,M
        STAX    D
        INX     H
        INX     D
        DCR     C
        JMP     GU1
GUDONE: XRA     A
        STAX    D
        RET

;=======================================================================
; BUILDING PACKETS -- see Reference/fujinet/rs232-protocol.md for the
; layout; identical shape to CPM Tools/NC.ASM's MKxxx routines.
;=======================================================================

MKOPEN: LXI     H,TXBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDOPEN
        INX     H
        INX     H
        INX     H
        INX     H               ; off2 -> off5
        MVI     M,2             ; descr: two 1-byte params
        INX     H
        MVI     M,ACCRD
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
; parent probe and default to "not found").
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
; SENDING AND RECEIVING -- SLIP framing over the raw ACIA (verbatim from
; CPM Tools/NC.ASM)
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
; THE COMMAND TAIL -- one token only (the local filename). See FUJIGET's
; own header on why this is hand-rolled, not the CCP's FCB parse.
;=======================================================================
PARSE:  LXI     H,TAIL
        MOV     B,M
        INX     H
        CALL    SKIPSP
        LXI     D,NAME
        MVI     C,NAMLEN
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
; THE FCB -- build one from the NUL-terminated name at HL. Verbatim from
; CPM Tools/R.ASM's MKFCB/LEGAL: handles an optional drive prefix, folds
; to 8.3, drops characters CP/M cannot store rather than refusing.
;=======================================================================
MKFCB:  PUSH    H

        LXI     H,FCB
        MVI     B,36
MF0:    MVI     M,0
        INX     H
        DCR     B
        JNZ     MF0

        LXI     H,FCB+1
        MVI     B,11
MF1:    MVI     M,' '
        INX     H
        DCR     B
        JNZ     MF1

        POP     H

        MOV     A,M
        ORA     A
        RZ
        INX     H
        MOV     A,M
        CPI     ':'
        JNZ     MF2
        DCX     H
        MOV     A,M
        SUI     'A'-1
        STA     FCB
        INX     H
        INX     H
        JMP     MF3
MF2:    DCX     H

MF3:    LXI     D,FCB+1
        MVI     B,8
MF4:    MOV     A,M
        ORA     A
        JZ      MF9
        CPI     '.'
        JZ      MF5
        CALL    LEGAL
        JC      MF4N
        MOV     C,A
        MOV     A,B
        ORA     A
        JZ      MF4N
        MOV     A,C
        STAX    D
        INX     D
        DCR     B
MF4N:   INX     H
        JMP     MF4

MF5:    INX     H
        LXI     D,FCB+9
        MVI     B,3
MF6:    MOV     A,M
        ORA     A
        RZ
        CALL    LEGAL
        JC      MF6N
        MOV     C,A
        MOV     A,B
        ORA     A
        JZ      MF6N
        MOV     A,C
        STAX    D
        INX     D
        DCR     B
MF6N:   INX     H
        JMP     MF6

MF9:    RET

;-----------------------------------------------------------------------
; LEGAL -- CY set if A is a character CP/M cannot put in a filename.
;-----------------------------------------------------------------------
LEGAL:  PUSH    H
        MOV     C,A
        LXI     H,ILLCHR
LG1:    MOV     A,M
        ORA     A
        JZ      LGOK
        CMP     C
        JZ      LGBAD
        INX     H
        JMP     LG1
LGOK:   MOV     A,C
        POP     H
        ORA     A
        RET
LGBAD:  MOV     A,C
        POP     H
        STC
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

SAYNFND:LXI     D,MNFND
        MVI     C,PRSTR
        JMP     BDOS

SAYBAD: LXI     D,MBADP
        MVI     C,PRSTR
        JMP     BDOS

SAYABRT:LXI     D,MABRT
        MVI     C,PRSTR
        JMP     BDOS

SAYNODIR:
        LXI     D,MNODIR
        MVI     C,PRSTR
        JMP     BDOS

SAYECLOS:
        LXI     D,MECLOS
        MVI     C,PRSTR
        JMP     BDOS

SAYEWRIT:
        LXI     D,MEWRIT
        MVI     C,PRSTR
        JMP     BDOS

SAYSKIP:LXI     D,MSKIP
        MVI     C,PRSTR
        JMP     BDOS

;-----------------------------------------------------------------------
; SAYDONE -- "NNN records received." -- PRDEC/DIV10 copied from
; CPM Tools/HDIR.ASM.
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

;=======================================================================
; DATA
;=======================================================================
MCONN:  DB      'WGET: opening $'
MCRLF:  DB      CR,LF,'$'
MOK:    DB      'Open OK. Receiving...',CR,LF,'$'
MNORE:  DB      CR,LF,'WGET: destination server not'
        DB      ' responding.',CR,LF,'$'
MNFND:  DB      CR,LF,'WGET: not found on that remote'
        DB      ' server.',CR,LF,'$'
MBADP:  DB      CR,LF,'WGET: failed -- parent path does not'
        DB      ' exist.',CR,LF,'$'
MABRT:  DB      CR,LF,'WGET: aborted.',CR,LF,'$'
MNODIR: DB      CR,LF,'WGET: can''t make file (directory full).',CR,LF,'$'
MECLOS: DB      CR,LF,'WGET: error closing file.',CR,LF,'$'
MEWRIT: DB      CR,LF,'WGET: error writing file.',CR,LF,'$'
MRECS:  DB      ' records received.',CR,LF,'$'
MEXIST: DB      CR,LF,'WGET: $'
MEXIST2:DB      ' exists. Replace? (Y/N) $'
MSKIP:  DB      CR,LF,'WGET: not replaced.',CR,LF,'$'
MPROGP: DB      'Received $'
MPROGS: DB      ' KB...$'
MURL:   DB      'URL: $'

MUSAGE: DB      CR,LF,'WGET v1.0 -- fetch a file through FujiNet''s'
        DB      ' N: network device, prompting for the URL so its'
        DB      ' case survives the CCP.',CR,LF,CR,LF
        DB      '   WGET file.ext',CR,LF
        DB      '   URL: <typed at the prompt, case preserved>',CR,LF,CR,LF
        DB      'Example',CR,LF
        DB      '   WGET HELLO.TXT',CR,LF
        DB      '   URL: TNFS://192.168.1.5/HELLO.TXT',CR,LF,'$'

; ILLCHR -- verbatim from R.ASM. The ';' MUST be its own numeric byte, not
; inside the string: ASM.COM strips the comment before it parses quotes,
; so a semicolon inside one truncates the line and it dies with a syntax
; error (R.ASM's own comment on this, learned the hard way there).
ILLCHR: DB      '<>.,'
        DB      3BH             ; ';'
        DB      ':=?*[]|'
        DB      5CH,2FH,0

;---- Variables ---------------------------------------------------------
SPEC:     DS    SPECLEN
PARENT:   DS    SPECLEN
SRCPTR:   DS    2
PVALID:   DS    1
TOCNT:  DS      1
NAME:   DS      NAMLEN
FCB:    DS      36              ; ours, not the CCP's at 5CH
BUF:    DS      RECLEN
RECPOS: DS      1
RECS:   DS      2
KCNT:   DS      2
REQLEN: DS      2

LBUF:   DB      SPECLEN-2       ; max chars BDOS 10 may store (its own header
                                ; byte 0 -- MUST be preset by the caller,
                                ; unlike byte 1, which BDOS fills in itself)
        DB      0               ; actual count typed -- filled in by BDOS
        DS      SPECLEN-2       ; room for the typed characters

TXBUF:  DS      200
RXBUF:  DS      200
NUMEND: DS      1

        DS      64              ; stack
STACK   EQU     $

        END     START
