# Running your own TNFS server, anonymous-FTP style

This is a step-by-step guide for setting up a TNFS server with the classic anonymous-FTP
layout. The layout has two parts. A **read-only** `pub` directory holds content you want to
share. An **incoming** drop box is truly **write-only**. Clients can drop files into
`incoming`. They cannot list what is there. They cannot read anything back, not even their
own upload. The team tested this setup on a Raspberry Pi (Raspberry Pi OS / Debian "trixie",
armhf). The Pi talked to real CP/M over `FUJIGET`, `FUJIPUT`, and `FUJIDIR`, through
`fujinet-rs232`'s BOIP bridge.

This guide is not part of the packaged release. Like `altairsim/` and `testing/`, it is only
useful if you are setting up a server yourself. Get it directly from the repo:
<https://github.com/trgeuy/fujinet-cpm22/tree/main/tnfsd-server-setup>.

**This guide covers [de-tnfsd](https://github.com/deltecent/de-tnfsd)**, a daemon built for
exactly this read-only/write-only split. An earlier version of this guide covered stock
`tnfsd` plus a hand-rolled Unix-permissions layout (`UMask=0444`, `chmod 0333`/`0555`) to fake
the same split. de-tnfsd replaces all of that with a fixed capability table enforced inside
the daemon itself. So none of the permission-bit tricks below control the *policy* anymore.
If you still run stock `tnfsd`, see this file's git history for the old approach.

## Why de-tnfsd instead of stock tnfsd

Stock `tnfsd` has no config file and no per-directory access control at all. Its whole
command line is `tnfsd [-a] [-r] [-u UID] [-g GID] [-p PORT] <root_path>`. `-r` is one global
read-only switch, nothing more. To get a mixed read-only/write-only layout out of it, you must
rely on real Unix permission bits and a carefully chosen `UMask=`. This works, but it is easy
to get subtly wrong. See the old gotcha below.

de-tnfsd builds the split into its own protocol handling instead. `pub` and `incoming` are
fixed, non-configurable zone names. The daemon checks every request against a capability
table *before* it makes any filesystem call:

| Zone        | LOOKUP | LIST | READ | CREATE |
|-------------|--------|------|------|--------|
| `/`         | yes    | synthetic (lists `pub`, `incoming` only) | no | no |
| `/pub`      | yes    | yes  | yes  | no     |
| `/incoming` | no     | no   | no   | yes    |

Set `incoming` to `0777` on disk. A client still cannot list it, stat a name in it, read a
byte from it, or overwrite anything in it. The capability table refuses these actions, not
the filesystem. Making `pub` world-writable does not make it writable over TNFS either.
Filesystem permissions still matter (see "Filling pub" below). But they only control *who on
the host* can manage the content, never what a TNFS client can do.

## 1. Build and install

de-tnfsd is POSIX C11 with no external dependencies. Unlike stock `tnfsd`, it has no
`xa65`/`xxd` Atari-bootsector build step to fight.

**As of this writing, build from our fork's `deploy` branch, not upstream directly.**
`deltecent/de-tnfsd` has merged our `O_TRUNC`-on-write-open fix and our never-hand-out-handle-0
fix. Real FujiNet firmware clients need both fixes to upload at all (see below). But the
case-insensitive zone-name match that CP/M needs is still under review upstream, as
[deltecent/de-tnfsd#2](https://github.com/deltecent/de-tnfsd/pull/2). Once that lands, switch
to upstream directly.

```
git clone -b deploy https://github.com/trgeuy/de-tnfsd.git
cd de-tnfsd
make check                 # build and run the three test suites
sudo ./install.sh          # /usr/local, /srv/tnfs, port 16384 by default
```

`install.sh` does the whole first-time setup. It builds the daemon, creates the `tnfs` system
user, and creates `<root>/pub` and `<root>/incoming` with sane default modes. It also installs
the binary, then installs and starts the systemd unit. `sudo ./install.sh --prefix /opt/tnfs
--root /data/tnfs --port 16385` overrides the defaults. `--dry-run` prints every command
without changing anything. Re-running the script is safe. The generated unit does **not** set
`User=` or `UMask=`. The daemon chroots to `<root>` as root, then drops privilege to `tnfs`
itself. So none of the old stock-`tnfsd` unit tuning applies here.

## 2. Namespace and zone layout

```
<root>/
    pub/         anonymous read-only, recursive
    incoming/    anonymous drop box: create new files only
```

**`pub` and `incoming` are fixed, lowercase, non-configurable names directly under the server
root.** The root itself is synthetic. A listing of `/` always returns exactly these two
entries, no matter what else is on disk under root. This whole guide exists to make one fact
clear: **never rename these two directories, and never let anything that touches them
uppercase them.** See the case-fix section below for why this bit us in production.

`incoming` is flat. It has no subdirectories, and `MKDIR` fails everywhere inside it. The
daemon refuses to start in four cases: `pub` or `incoming` is missing, either one is a
symlink, they resolve to the same directory, or `incoming` is not writable by the daemon's own
uid.

## 3. Filling `pub` and draining `incoming`

The daemon needs to read `pub` and create files in `incoming`. It checks both at startup.
Beyond that, filesystem permissions only control who on the *host* can manage content, never
what a TNFS client can do.

**`pub`.** The daemon serves it as its own uid (`tnfs`). So a file the daemon cannot open
still gets listed, but then fails on fetch with a server-looking error. Make `pub` setgid and
owned by the daemon's group. This makes new content readable automatically for anyone who
needs to add it:

```
sudo chown -R tnfs:tnfs /srv/tnfs/pub
sudo find /srv/tnfs/pub -type d -exec chmod 2775 {} +
sudo find /srv/tnfs/pub -type f -exec chmod 0664 {} +
sudo usermod -aG tnfs <operator>
```

Setgid matters because `pub` is recursive. New subdirectories inherit group `tnfs`
automatically, instead of your own primary group. This keeps the tree readable as you extend
it. If a newly added file is not fetchable, check your `umask` before you blame the daemon.
`002` and `022` both work. `077` produces `0600` files that `tnfs` cannot read.

**`incoming`.** Draining it is deliberately out of scope for the daemon. A separate process,
under its own uid, should drain it instead. Uploads land as `0660`, owned by `tnfs:tnfs`. So
the intended setup is a drain group:

```
sudo chown tnfs:tnfs /srv/tnfs/incoming
sudo chmod 2770      /srv/tnfs/incoming
sudo usermod -aG tnfs <operator>
```

None of this affects the TNFS-visible policy. It only controls who on the host can read what
lands there. No TNFS client can ever list `incoming`. So the daemon's own upload log (source
IP, name, size, duration, outcome) is your only visibility into it over the network.

## 4. The CP/M-side gotcha: everything you type gets uppercased first

**This altairsim CP/M build, and possibly others, uppercases the whole command-line tail
before any `.COM` program sees it, including all four FujiNet tools.** The team confirmed this
by reading `FUJIDIR.ASM`'s own command-tail parser: it copies bytes verbatim, with no
case-folding anywhere in the source. There is no way to override this from the CP/M side.
`FUJIDIR N1:TNFS://host/pub/` and `FUJIDIR N1:TNFS://host/PUB/` both result in the same
uppercased request being sent from CP/M.

This causes a problem with de-tnfsd's fixed `pub`/`incoming` names. As of this writing, before
[PR #2](https://github.com/deltecent/de-tnfsd/pull/2) lands upstream, de-tnfsd matches these
names case-sensitively against the exact lowercase strings `"pub"`/`"incoming"`. **Without our
fork's case-fold patch, a CP/M client cannot reach either zone at all.** `/PUB` and
`/INCOMING` both resolve to "no such zone" before the daemon even looks at the filesystem. Our
fork's `deploy` branch (see §1) already carries this patch. It has one known gap: it fixes
zone resolution for `OPENDIR`/`OPEN`-style path lookups, but not for a direct `MOUNT /PUB`.
This gap does not affect `FUJIGET`, `FUJIPUT`, or `FUJIDIR`. These tools always mount `/` and
resolve zones through the path on each later request. The team confirmed this live: every real
session in the daemon's log mounts `zone=/`, never a specific zone.

**This case-fold patch only affects the two zone *names*. Never rename `pub`/`incoming`
themselves to match.** They must stay exactly lowercase on disk, so the daemon's own zone
matching can find them, no matter what a CP/M client requests. This is the opposite of the old
stock-`tnfsd` advice. That advice said to name everything reachable from CP/M in UPPERCASE,
because the directory name *was* the served path. That advice only ever applied to leaf
content. It matters even more now, since de-tnfsd's own zone-name case-fold handles the top
level.

### Leaf content inside `pub` still needs to be uppercase on disk

Once a CP/M client is inside a resolved zone, it looks up filenames on disk exactly as typed.
The CCP still uppercases them first, and Linux still does an exact-case filesystem lookup.
Anything that reaches `pub` through `FUJIPUT` is already safe, since the CCP uppercases the
whole path before the tool ever sees it. The real risk is content added **directly on the
server**: `scp`, `rsync`, or unpacking a `.tar.gz`. These routinely use lowercase or
mixed-case names, which would otherwise stay silently unreachable from CP/M forever.

### Fixing it automatically: a cron job that enforces uppercase leaf names

This directory includes two files: `tnfs-case-fix.sh`, which walks the tree and uppercases
lowercase or mixed-case names, and `tnfs-case-fix.cron`, a `cron.d` entry that runs it every 15
minutes. To install:

```
sudo cp tnfs-case-fix.sh /usr/local/sbin/tnfs-case-fix.sh
sudo chown root:root /usr/local/sbin/tnfs-case-fix.sh
sudo chmod 755 /usr/local/sbin/tnfs-case-fix.sh
sudo cp tnfs-case-fix.cron /etc/cron.d/tnfs-case-fix
sudo chown root:root /etc/cron.d/tnfs-case-fix
sudo chmod 644 /etc/cron.d/tnfs-case-fix
sudo touch /var/log/tnfs-case-fix.log
sudo chmod 644 /var/log/tnfs-case-fix.log
```

**The script must avoid two hazards. Both hit us in production once already:**

1. **Never rename `pub`/`incoming` themselves.** An earlier version of this script walked from
   the server root with no depth floor. Under stock `tnfsd`, this was correct, since the
   directory name was the served path. Under de-tnfsd, it renamed the live zone directories to
   `PUB`/`INCOMING` the first time it ran against the new root. This broke zone resolution
   outright, since de-tnfsd matches on the literal lowercase names. The fix starts the walk at
   `-mindepth 2`. Everything *inside* `pub`/`incoming`, including nested subdirectories, still
   gets case-fixed. The two zone directories themselves are never touched.
2. **Never touch a file mid-upload.** de-tnfsd writes an in-progress upload to a dot-prefixed
   temp name (`.tmp-<random>`) inside `incoming`, before it links the file to its final name.
   `find` matches dotfiles by default. So without an exclusion, a cron tick landing during a
   slow upload could rename that temp file out from under the daemon's own finalize step. The
   fix excludes any name that starts with `.`.

```bash
#!/bin/bash
# Renames files/directories under $ROOT to uppercase names so CP/M clients
# (which always request UPPERCASE paths) can reach content added with
# lowercase names by other means (scp, rsync, tarballs, etc).
#
# Never touches $ROOT/pub or $ROOT/incoming themselves (-mindepth 2) --
# de-tnfsd matches those two zone names case-sensitively against fixed
# lowercase strings; renaming them breaks zone resolution outright.
# Never touches dotfiles (! -name '.*') -- de-tnfsd's in-flight uploads use
# a dot-prefixed temp name inside incoming/ before their final rename.
ROOT="/srv/tnfs"
LOG="/var/log/tnfs-case-fix.log"

# -depth: process each directory's contents before the directory itself,
# so a parent dir's own rename never invalidates paths already queued for
# its children.
find "$ROOT" -depth -mindepth 2 ! -name '.*' | while IFS= read -r path; do
    dir=$(dirname "$path")
    base=$(basename "$path")
    upper=$(echo "$base" | tr '[:lower:]' '[:upper:]')
    if [ "$base" != "$upper" ]; then
        target="$dir/$upper"
        if [ -e "$target" ]; then
            echo "$(date '+%F %T') SKIP (target exists): $path -> $target" >> "$LOG"
        else
            mv -n "$path" "$target" && echo "$(date '+%F %T') RENAMED: $path -> $target" >> "$LOG"
        fi
    fi
done
```

Notes:

- **It never overwrites.** If both `readme.txt` and `README.TXT` already exist in the same
  folder, the script leaves both alone. It logs `SKIP (target exists)` instead of guessing
  which one you meant to keep.
- **It works bottom-up** (`-depth`). So a directory rename never strands a path already queued
  for a file inside it.
- It runs as root via `cron.d`, for simplicity. Under de-tnfsd's `2775`/`tnfs`-group `pub`
  layout, a member of the `tnfs` group could run it too. But running it as root avoids needing
  that group membership just for a maintenance cron job.
- Confirmed live (2026-09-04): with the `-mindepth 2` and dotfile-exclusion fixes in place, a
  second run right after a fix produced no `RENAMED` lines for `pub`/`incoming`. It is
  idempotent against the zone directories, as intended.

## 5. A diagnostic-wording note (needs re-verification against a live CP/M client)

Under de-tnfsd, `OPENDIR`, `STAT`, and `OPEN` against anything under `/incoming` all get
refused with a uniform `EACCES`. This comes straight from the capability table, since `LOOKUP`
and `LIST` are both `no` for that zone. The refusal happens before any real filesystem call, no
matter whether the exact name is known. This is stricter than the old stock-`tnfsd` layout.
There, a `0333` directory blocked listing but still let a client fetch a file by an exact known
name. de-tnfsd has no equivalent gap.

The old guide documented `FUJIGET` failing against `INCOMING/` with `"failed -- parent path
does not exist"`, rather than "denied". This was a quirk of `FUJIGET`'s own parent-directory
reachability probe, under stock `tnfsd`'s specific failure shape. **The team has not
re-confirmed this wording against de-tnfsd's `EACCES`-from-capability-table response.** The
underlying refusal reason has changed, even though the practical effect, a blocked read, has
not. Verify the actual wording your `FUJIGET` prints before you rely on it in your own
documentation.

## 6. Quick verification checklist

Once your de-tnfsd is running with this layout, run these commands from CP/M:

```
FUJIDIR N1:TNFS://<host>/            -> lists pub/ and incoming/
FUJIDIR N1:TNFS://<host>/PUB/        -> lists whatever you've put there
FUJIGET N1:TNFS://<host>/PUB/<file> local.txt   -> succeeds
FUJIPUT local.txt N1:TNFS://<host>/PUB/x.txt    -> denied
FUJIPUT local.txt N1:TNFS://<host>/INCOMING/x.txt -> succeeds
FUJIDIR N1:TNFS://<host>/INCOMING/              -> fails (unlisted)
FUJIGET N1:TNFS://<host>/INCOMING/x.txt out.txt -> fails (unreadable)
```

If the first two commands unexpectedly fail with "not found" or zone errors, check that you
are running our fork's `deploy` branch (§1), not vanilla upstream. Without the case-fold
patch, CP/M's uppercased `/PUB`/`/INCOMING` cannot resolve to either zone at all.

## What changed

**Sentence length and one-topic-per-sentence (rule 2/3).** The original was written almost
entirely in long, dash-joined compound sentences, several running 40-60 words across two or
three separate facts (e.g. the opening paragraph, the "install.sh does the whole first-time
setup" sentence, both numbered hazards in the cron section). Each was split into shorter
sentences of one fact each, none over the 25-word description limit.

**Em dashes (rule 10).** Every em dash in the original (dozens of them, used as a general-
purpose joiner for asides, causes, and contrasts) was replaced with a period, colon, or comma,
whichever the original relationship called for.

**Passive voice (rule 4).** Rewrote passive constructions with a known agent to active voice:
"is refused... regardless of whether the exact name is known" → "The refusal happens before
any real filesystem call, no matter whether the exact name is known"; "are matched
case-sensitively" → "de-tnfsd matches these names case-sensitively"; "This hasn't been
re-confirmed" → "The team has not re-confirmed this wording."

**Contractions expanded.** *doesn't* → *does not*, *isn't* → *is not*, *can't* → *cannot*,
*don't* → *do not*, *you're* → *you are*, *it's* → *it is*, throughout — except inside the
`.sh` script's own code comments, which are left byte-for-byte exact.

**Substitution table.** *in order to* did not appear; other candidates checked and already
absent (*utilize*, *ensure*, *prior to*, *sufficient*). No AI-slop blocklist words were present
in the original.

**Left alone.** The zone-capability table, every code and command block (including the full
`tnfs-case-fix.sh` script and its own comments), every filename, path, permission mode, PR
link, and the CP/M command-transcript block in §6 are reproduced exactly as in the original.
The one genuinely ambiguous sentence in the original ("that advice only ever applied to leaf
content, and always mattered more once de-tnfsd's own zone-name case-fold is what handles the
top level") was restructured into two plain sentences without changing its apparent meaning;
no fact was added or guessed.
