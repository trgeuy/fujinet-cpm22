;-----------------------------------------------------------------------
; FUJIDIR.COM v1.5 -- list a directory through FujiNet's N: network device.
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
; v1.2: the OPEN target is now always probed WITH a trailing slash
; (PROBESPC, built by MKPRBS), never the bare typed SPEC. Without one, a
; bare last path segment is a WILDCARD PATTERN filtering a listing of
; the PARENT, not an exact-path open -- confirmed live, see Reference/
; fujinet/rs232-protocol.md's "DIRECTORY-mode OPEN is a wildcard-pattern
; list" section. This was a real, pre-existing bug (v1.0/v1.1 both had
; it): "FUJIDIR N1:TNFS://host/SUBDIR" with no trailing slash could ACK
; and list the PARENT's matching entries instead of SUBDIR's contents,
; or even instead of cleanly failing, whenever the parent happened to
; be non-empty.
;
; Also v1.2: if the real OPEN still fails after that fix, FujiNet's NAK
; carries no error detail at all (confirmed from firmware source -- see
; Reference/fujinet/rs232-protocol.md for the full explanation). Instead,
; probe the PARENT directory (same MKOPEN, pointed at PARENT instead of
; PROBESPC -- MKPRNT already guarantees PARENT ends in '/'): if it exists,
; the target almost certainly just isn't there (reported as "not found,"
; not "denied" -- unlike FUJIPUT, there's no "we're about to
; create something new" expectation for a listing); if the parent
; doesn't exist either, the path itself is bad.
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
; v1.4: the size column had no unit label at all -- a plain number could
; be mistaken for bytes, K, or anything else, and the server's own LONG
; format actually mixes plain byte counts (small files) with K/M-suffixed
; ones (larger files) with nothing distinguishing the two. Printed one
; line explaining this once, right before the listing starts.
;-----------------------------------------------------------------------
; v1.5: that explanation printed before EVERY listing, which got old
; fast once you knew it. Moved into the usage message (bare FUJIDIR, no
; args) instead -- said once, not on every run.
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

        CALL    MKPRBS          ; SPEC -> PROBESPC, with a trailing '/'
        LXI     H,PROBESPC
        SHLD    SRCPTR
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

;-----------------------------------------------------------------------
; EFAIL -- the real OPEN was NAK'd. Probe the PARENT directory to guess
; why: if it exists, the target almost certainly just isn't there; if
; the parent doesn't exist either, the path itself is bad. See this
; file's header for why "not found" (not "denied") is the right default
; here.
;-----------------------------------------------------------------------
EFAIL:  CALL    MKPRNT
        LDA     PVALID
        ORA     A
        JZ      DOSNF           ; couldn't even determine a parent -- default

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
        JZ      DOSNF           ; parent exists -- so the target just isn't there
        CALL    SAYBAD
        JMP     0

DOSNF:  CALL    SAYNFND
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

;-----------------------------------------------------------------------
; MKOPEN -- a directory-mode OPEN against whatever SRCPTR points at:
; PROBESPC for the real listing target, or PARENT for the post-failure
; diagnostic probe (see EFAIL above). Both are guaranteed to end in
; '/' by their respective builders (MKPRBS/MKPRNT below) -- see this
; file's header for why that trailing slash is mandatory.
;-----------------------------------------------------------------------
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
        MVI     M,DIRFLONG
        INX     H
MKO1:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        ORA     A
        JNZ     MKO1
        LXI     D,TXBUF
        JMP     SETLEN

;-----------------------------------------------------------------------
; MKPRBS -- copy SPEC into PROBESPC, appending a trailing '/' if SPEC
; doesn't already end in one. See this file's header for why.
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
MNORE:  DB      CR,LF,'FUJIDIR: destination server not'
        DB      ' responding.',CR,LF,'$'
MCRLF:  DB      CR,LF,'$'
MNFND:  DB      CR,LF,'FUJIDIR: not found on that remote'
        DB      ' server.',CR,LF,'$'
MBADP:  DB      CR,LF,'FUJIDIR: failed -- parent path does not'
        DB      ' exist.',CR,LF,'$'
MABRT:  DB      CR,LF,'FUJIDIR: aborted.',CR,LF,'$'
MNONE:  DB      'FUJIDIR: nothing matches.',CR,LF,'$'

MUSAGE: DB      CR,LF,'FUJIDIR v1.5 -- list a directory through FujiNet''s'
        DB      ' N: network device.',CR,LF,CR,LF
        DB      '   FUJIDIR N:<url>',CR,LF,CR,LF
        DB      'Example',CR,LF
        DB      '   FUJIDIR N1:TNFS://192.168.1.5/',CR,LF,CR,LF
        DB      'Sizes are shown as bytes, or K/M for larger'
        DB      ' files (from the server).',CR,LF,'$'

;---- Variables ---------------------------------------------------------
SPEC:     DS    SPECLEN
PARENT:   DS    SPECLEN
PROBESPC: DS    SPECLEN
SRCPTR:   DS    2
PVALID:   DS    1
TOCNT:  DS      1
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
