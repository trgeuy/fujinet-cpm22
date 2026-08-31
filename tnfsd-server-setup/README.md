# Running your own TNFS server, anonymous-FTP style

This is a step-by-step for standing up a `tnfsd` server with the classic anonymous-FTP layout:
one or more **read-only** folders for content you want to share, and an **incoming** folder
that's genuinely **write-only** — clients can drop files in, but can't list what's there or read
anything back, including their own upload. Tested on a Raspberry Pi (Raspberry Pi OS / Debian
"trixie", armhf) talking to real CP/M over `FUJIGET`/`FUJIPUT`/`FUJIDIR`/`FUJIMKD` through
`fujinet-rs232`'s BOIP bridge.

Not included in the packaged release — like `altairsim/` and `testing/`, this is only useful if
you're actually setting up a server. Get it straight from the repo:
<https://github.com/trgeuy/fujinet-cpm22/tree/main/tnfsd-server-setup>.

## Why this needs real Unix permissions, not a `tnfsd` setting

`tnfsd` has no config file and no per-directory access-control concept at all — its entire
command line is `tnfsd [-a] [-r] [-u UID] [-g GID] [-p PORT] <root_path>` (confirmed straight
from its `getopt` string in `main.c`). `-r` is global read-only for the whole tree; there's
nothing finer-grained built in.

What makes a mixed layout possible anyway: `tnfsd` runs as one ordinary, unprivileged user (not
root) and does plain POSIX file operations on behalf of every remote client under that one
identity. The kernel checks permission bits against the process's effective UID no matter what
it "owns," so if you strip permission bits from `tnfsd`'s own files, you genuinely restrict what
`tnfsd` itself can do — even for directories it created and owns. That's the whole trick.

## 1. Build and install `tnfsd`

Following <https://github.com/FujiNetWIFI/fujinet-firmware/wiki/Setting-up-a-TNFS-Server>'s
"Advanced" Raspberry Pi steps, with two build dependencies the wiki doesn't mention:

```
sudo apt-get install -y git xa65 xxd
git clone https://github.com/FujiNetWIFI/tnfsd.git
cd tnfsd/src
make OS=LINUX DEBUG=Y
sudo cp ../bin/tnfsd /usr/local/sbin
sudo useradd -m tnfs
sudo mkdir -p /tnfs
sudo chown tnfs:tnfs /tnfs
```

- **`xa65`** (the 6502 cross-assembler) and **`xxd`** are needed to build the Atari boot-sector
  header (`atari_bootsector.h`) that's compiled into `tnfsd` even on non-Atari builds. Neither
  is installed by default on Raspberry Pi OS.
- **If a build ever fails partway through the `xxd -i atari_bootsector.bin >
  atari_bootsector.h` step** (e.g. because `xxd` wasn't installed yet at that point), shell
  redirection still creates an **empty** `atari_bootsector.h`. A later `make` run will see that
  empty file as "up to date" relative to its inputs and won't regenerate it — you'll get
  confusing `'atari_bootsector_bin_len' undeclared` errors out of `atari.c` that have nothing to
  do with your actual problem. Fix: `rm atari_bootsector.h atari_bootsector.bin *.o` and rebuild
  from clean.

Create the systemd unit at `/etc/systemd/system/tnfsd.service`:

```ini
[Unit]
Description=TNFS Server
After=remote-fs.target
After=syslog.target

[Service]
UMask=0444
User=tnfs
Group=tnfs
ExecStart=/usr/local/sbin/tnfsd /tnfs

[Install]
WantedBy=multi-user.target
```

`UMask=0444` is explained below — it's not optional if you want a real write-only folder. Note
there's **no `-r` flag** here: a global read-only flag would block writes everywhere, including
the incoming folder, so this layout uses real filesystem permissions instead of `tnfsd`'s own
read-only switch.

```
sudo systemctl daemon-reload
sudo systemctl enable tnfsd
sudo systemctl start tnfsd
```

## 2. Lay out the directory tree

```
sudo mkdir -p /tnfs/INCOMING /tnfs/PUB
sudo chown -R tnfs:tnfs /tnfs
sudo chmod 555 /tnfs
sudo chmod 333 /tnfs/INCOMING
sudo chmod 555 /tnfs/PUB
```

Result:

| Path             | Mode | Meaning                                                      |
|------------------|------|---------------------------------------------------------------|
| `/tnfs`          | 0555 | listable index (shows `INCOMING/`, `PUB/`), not writable      |
| `/tnfs/INCOMING` | 0333 | write + traverse only — **unlisted**                          |
| `/tnfs/PUB`      | 0555 | read + list only — **no write**                                |

Add as many `PUB`-style read-only folders as you want, all the same way. Content management
(populating a read-only folder, sweeping `INCOMING` periodically) happens by SSHing into the box
directly with `sudo` — `tnfsd` itself is *never* able to write into `PUB` or read out of
`INCOMING`, by design, no matter what any client requests. That's also the only way to actually
retrieve what lands in `INCOMING` — nothing on the TNFS side can read it back, on purpose.

## 3. The gotcha: directory permissions alone aren't enough for write-only

A directory's **read** bit governs *listing* (`readdir`); its **execute** bit governs
*traversal* — opening a file inside by a name you already know. These are independent. A
`0333` directory (no read bit anywhere) blocks `FUJIDIR`, but **a client who already knows an
exact filename can still open and read it**, because that only needs execute on the directory,
not read.

Confirmed live: with `INCOMING/` at `0333` but a freshly-uploaded file left at `tnfsd`'s default
creation mode, `FUJIDIR N1:TNFS://host/INCOMING/` correctly failed, but `FUJIGET
N1:TNFS://host/INCOMING/<exact filename>` **succeeded** — the file itself (created world-
readable by `tnfsd`) was the leak, not the directory.

`tnfsd` requests mode `0777` when it creates a file or directory; that gets masked by the
*process's own* umask before landing on disk. A typical systemd default umask (`0022`) leaves
new files at `0755` — fully readable. Setting **`UMask=0444`** in the service's `[Service]`
section (see the unit file above) strips the read bit from everything `tnfsd` creates, in every
permission class, while leaving whatever write/execute bits it actually requested intact — so a
subdirectory `tnfsd` creates stays traversable, but nothing it creates is ever readable by
anyone, including `tnfsd` itself on a later request. This is what actually makes `INCOMING`
write-only rather than merely unlisted. Verified: before the `UMask` fix, an upload landed
`-rwxr-xr-x`; the identical content uploaded after the fix landed `-wx-wx-wx`, and the follow-up
`FUJIGET` on it correctly failed.

## 4. A CP/M-side gotcha that will bite you before you even get here

**This altairsim CP/M build (and possibly others) uppercases the entire command-line tail
before any `.COM` program — including all four FujiNet tools — ever sees it.** Confirmed by
reading `FUJIDIR.ASM`'s own command-tail parser: it copies bytes verbatim, no case-folding
instructions anywhere in the source. The raw keystroke echo on screen preserves whatever case
you actually typed; the uppercasing happens between that echo and the program reading its
command tail, at the CCP level.

**Practical consequence: name every folder and file you want reachable from CP/M in
UPPERCASE.** `pub`/`incoming` (lowercase) are permanently unreachable from this CP/M
environment no matter what case you type at the prompt — `FUJIDIR N1:TNFS://host/pub/` and
`FUJIDIR N1:TNFS://host/PUB/` both get uppercased to the same request before they leave the
guest. This was invisible for a long time in this project because every prior target (DNS
hostnames, dotted IP addresses, macOS's case-insensitive filesystem, retro-convention all-caps
filenames) happened to be case-insensitive-safe. A lowercase Linux directory name is the first
thing that actually exposes it.

## 5. A diagnostic-wording quirk worth knowing about

Under this layout, `FUJIGET` against a file inside `INCOMING/` fails with:

```
FUJIGET: failed -- parent path does not exist.
```

— not "denied." `FUJIGET`'s error-reporting tries a parent-directory probe to distinguish *why*
a request failed (FujiNet's own NAK carries no error detail at all — see
`docs/rs232-protocol.md`), and that probe *also* fails here, because the parent (`INCOMING/`)
is itself unlistable. The tool falls back to "parent doesn't exist," which is misleading taken
literally — the read is still correctly blocked, the wording just isn't the real reason.

## 6. Quick verification checklist

Once your `tnfsd` is up with this layout, from CP/M:

```
FUJIDIR N1:TNFS://<host>/            -> lists INCOMING/ and PUB/
FUJIDIR N1:TNFS://<host>/PUB/        -> lists whatever you've put there
FUJIGET N1:TNFS://<host>/PUB/<file> local.txt   -> succeeds
FUJIPUT local.txt N1:TNFS://<host>/PUB/x.txt    -> denied
FUJIMKD N1:TNFS://<host>/PUB/x/                 -> denied
FUJIPUT local.txt N1:TNFS://<host>/INCOMING/x.txt -> succeeds
FUJIDIR N1:TNFS://<host>/INCOMING/              -> fails (unlisted)
FUJIGET N1:TNFS://<host>/INCOMING/x.txt out.txt -> fails (unreadable)
```

If the last two unexpectedly *succeed*, double-check `UMask=` is actually in the systemd unit's
`[Service]` section and that the service was restarted after adding it — a plain directory-
permission-only setup (no `UMask`) will still let a client read back a file it just uploaded, or
any file whose exact name it can guess.
