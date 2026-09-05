# Running your own TNFS server, anonymous-FTP style

A step-by-step for standing up a TNFS server with the classic anonymous-FTP layout: a
**read-only** `pub` for content you want to share, and an **incoming** drop box that's genuinely
**write-only** — clients can drop files in, but can't list what's there or read anything back,
including their own upload. Tested on a Raspberry Pi (Raspberry Pi OS / Debian "trixie", armhf)
talking to real CP/M over `FUJIGET`/`FUJIPUT`/`FUJIDIR` through `fujinet-rs232`'s BOIP bridge.

Not included in the packaged release — like `altairsim/` and `testing/`, this is only useful if
you're actually setting up a server. Get it straight from the repo:
<https://github.com/trgeuy/fujinet-cpm22/tree/main/tnfsd-server-setup>.

**This guide covers [de-tnfsd](https://github.com/deltecent/de-tnfsd)**, a purpose-built daemon
for exactly this read-only/write-only split. An earlier version of this guide covered stock
`tnfsd` plus a hand-rolled Unix-permissions layout (`UMask=0444`, `chmod 0333`/`0555`) to fake the
same thing — de-tnfsd replaces all of that with a fixed capability table enforced in the daemon
itself, so none of the permission-bit tricks below are needed for the *policy* anymore. If you're
still running stock `tnfsd`, see this file's git history for the old approach.

## Why de-tnfsd instead of stock tnfsd

Stock `tnfsd` has no config file and no per-directory access-control concept at all — its whole
command line is `tnfsd [-a] [-r] [-u UID] [-g GID] [-p PORT] <root_path>`, and `-r` is a single
global read-only switch. Getting a mixed read-only/write-only layout out of it means relying on
real Unix permission bits and a carefully chosen `UMask=`, which works but is easy to get subtly
wrong (see the old gotcha below).

de-tnfsd instead ships the split as part of the protocol handling itself: `pub` and `incoming` are
fixed, non-configurable zone names, and every request is checked against a capability table
*before* any filesystem syscall happens:

| Zone        | LOOKUP | LIST | READ | CREATE |
|-------------|--------|------|------|--------|
| `/`         | yes    | synthetic (lists `pub`, `incoming` only) | no | no |
| `/pub`      | yes    | yes  | yes  | no     |
| `/incoming` | no     | no   | no   | yes    |

Set `incoming` to `0777` on disk and a client still can't list it, stat a name in it, read a byte
out of it, or overwrite anything in it — those are refused by the table, not by the filesystem.
Making `pub` world-writable doesn't make it writable over TNFS either. Filesystem permissions
still matter (see "Filling pub" below), but only for *who on the host* can manage the content —
never for what a TNFS client can do.

## 1. Build and install

de-tnfsd is POSIX C11 with no external dependencies — no `xa65`/`xxd` Atari-bootsector build step
to fight with, unlike stock `tnfsd`.

**As of this writing, build from our fork's `deploy` branch, not upstream directly** —
`deltecent/de-tnfsd` has merged our `O_TRUNC`-on-write-open and never-hand-out-handle-0 fixes
(both required for real FujiNet firmware clients to upload at all — see below), but the
case-insensitive zone-name match CP/M needs is still under review upstream as
[deltecent/de-tnfsd#2](https://github.com/deltecent/de-tnfsd/pull/2). Once that lands, switch to
upstream directly.

```
git clone -b deploy https://github.com/trgeuy/de-tnfsd.git
cd de-tnfsd
make check                 # build and run the three test suites
sudo ./install.sh          # /usr/local, /srv/tnfs, port 16384 by default
```

`install.sh` does the whole first-time setup: builds, creates the `tnfs` system user, creates
`<root>/pub` and `<root>/incoming` with sane default modes, installs the binary, and installs and
starts the systemd unit. `sudo ./install.sh --prefix /opt/tnfs --root /data/tnfs --port 16385`
overrides the defaults; `--dry-run` prints every command without changing anything; re-running is
safe. The generated unit does **not** set `User=` or `UMask=` — the daemon chroots to `<root>` as
root, then drops privilege to `tnfs` itself, so none of the old stock-`tnfsd` unit tuning applies
here.

## 2. Namespace and zone layout

```
<root>/
    pub/         anonymous read-only, recursive
    incoming/    anonymous drop box: create new files only
```

**`pub` and `incoming` are fixed, lowercase, non-configurable names directly under the server
root.** The root itself is synthetic — a listing of `/` always returns exactly these two entries,
regardless of anything else on disk under root. This is the one fact this whole guide exists to
hammer home: **do not rename these two directories, and nothing that touches them should ever
uppercase them** — see the case-fix section below for why this bit us in production.

`incoming` is flat: no subdirectories, `MKDIR` refused everywhere. The daemon refuses to start at
all if `pub` or `incoming` is missing, either is a symlink, they resolve to the same directory, or
`incoming` isn't writable by the daemon's own uid.

## 3. Filling `pub` and draining `incoming`

The daemon needs to be able to read `pub` and create files in `incoming`; it checks both at
startup. Beyond that, filesystem permissions are only about who on the *host* can manage content —
never about what a TNFS client can do.

**`pub`** — the daemon serves it as its own uid (`tnfs`), so a file it can't open gets listed but
then fails on fetch with a server-looking error. A setgid `pub` owned by the daemon's group makes
this automatic for anyone who needs to add content:

```
sudo chown -R tnfs:tnfs /srv/tnfs/pub
sudo find /srv/tnfs/pub -type d -exec chmod 2775 {} +
sudo find /srv/tnfs/pub -type f -exec chmod 0664 {} +
sudo usermod -aG tnfs <operator>
```

Setgid matters because `pub` is recursive — new subdirectories inherit group `tnfs` automatically
instead of your own primary group, so the tree stays readable as you extend it. Check your `umask`
before blaming the daemon if a newly added file isn't fetchable: `002`/`022` both work, `077`
produces `0600` files `tnfs` can't read.

**`incoming`** — draining it is deliberately out of scope for the daemon; it should be a separate
process/uid. Uploads land `0660`, owned by `tnfs:tnfs`, so the intended arrangement is a drain
group:

```
sudo chown tnfs:tnfs /srv/tnfs/incoming
sudo chmod 2770      /srv/tnfs/incoming
sudo usermod -aG tnfs <operator>
```

None of this is load-bearing for the TNFS-visible policy — only for who on the host can read what
lands there. The daemon's own upload log (source IP, name, size, duration, outcome) is your
visibility into `incoming` over the network, since no TNFS client can ever list it.

## 4. The CP/M-side gotcha: everything you type gets uppercased first

**This altairsim CP/M build (and possibly others) uppercases the entire command-line tail before
any `.COM` program — including all four FujiNet tools — ever sees it.** Confirmed by reading
`FUJIDIR.ASM`'s own command-tail parser: it copies bytes verbatim, no case-folding anywhere in the
source. There is no way to override this from the CP/M side — `FUJIDIR N1:TNFS://host/pub/` and
`FUJIDIR N1:TNFS://host/PUB/` both leave the guest as the same uppercased request.

This interacts badly with de-tnfsd's fixed `pub`/`incoming` names, which — as of this writing,
before [PR #2](https://github.com/deltecent/de-tnfsd/pull/2) lands upstream — are matched
case-sensitively against the exact lowercase strings `"pub"`/`"incoming"`. **Without our fork's
case-fold patch, a CP/M client cannot reach either zone at all** — `/PUB` and `/INCOMING` both
resolve to "no such zone" before the daemon even looks at the filesystem. Our fork's `deploy`
branch (see §1) carries this patch already. One known gap in it: it fixes zone resolution for
`OPENDIR`/`OPEN`-style path lookups but not a direct `MOUNT /PUB` — this doesn't affect
`FUJIGET`/`FUJIPUT`/`FUJIDIR`, which always mount `/` and resolve zones via the path on each
subsequent request (confirmed live: every real session in the daemon's log mounts `zone=/`, never
a specific zone).

**This case-fold only affects the two zone *names* — never rename `pub`/`incoming` themselves to
match.** They must stay exactly lowercase on disk for the daemon's own zone matching to find them,
independent of whatever a CP/M client requests. This is the opposite of the old stock-`tnfsd`
advice (which said to name everything reachable from CP/M in UPPERCASE, because the directory name
*was* the served path) — that advice **only ever applied to leaf content**, and always mattered
more once de-tnfsd's own zone-name case-fold is what handles the top level.

### Leaf content inside `pub` still needs to be uppercase on disk

Once a CP/M client is inside a resolved zone, filenames are looked up on disk exactly as typed —
still uppercased by the CCP, still an exact-case filesystem lookup on Linux. Anything reaching
`pub` through `FUJIPUT` is already safe, since the CCP uppercases the whole path before the tool
ever sees it. The actual risk is content added **directly on the server** — `scp`, `rsync`,
unpacking a `.tar.gz` — which routinely uses lowercase or mixed-case names that would otherwise be
silently unreachable from CP/M forever.

### Fixing it automatically: a cron job that enforces uppercase leaf names

This directory includes `tnfs-case-fix.sh` (walks the tree and uppercases lowercase/mixed-case
names) and `tnfs-case-fix.cron` (a `cron.d` entry running it every 15 minutes). Install:

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

**Two hazards this script has to avoid, both hit in production once already:**

1. **Never rename `pub`/`incoming` themselves.** An earlier version of this script walked from
   the server root with no depth floor, which under stock `tnfsd` was correct (the directory name
   was the served path) but under de-tnfsd renamed the live zone directories to `PUB`/`INCOMING`
   the first time it ran against the new root — breaking zone resolution outright, since de-tnfsd
   matches on the literal lowercase names. Fixed by starting the walk at `-mindepth 2`: everything
   *inside* `pub`/`incoming` (including nested subdirectories) still gets case-fixed; the two zone
   directories themselves are never touched.
2. **Never touch a file mid-upload.** de-tnfsd writes an in-progress upload to a dot-prefixed temp
   name (`.tmp-<random>`) inside `incoming` before linking it to its final name. `find` matches
   dotfiles by default, so without an exclusion, a cron tick landing during a slow upload could
   rename that temp file out from under the daemon's own finalize step. Fixed by excluding any
   name starting with `.`.

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
  folder, the script leaves both alone and logs `SKIP (target exists)` rather than guessing which
  one you meant to keep.
- **It's bottom-up** (`-depth`), so a directory rename never strands a path already queued for a
  file inside it.
- Runs as root via `cron.d` for simplicity; under de-tnfsd's `2775`/`tnfs`-group `pub` layout, a
  member of the `tnfs` group could run it too, but root avoids needing that group membership just
  for a maintenance cron.
- Confirmed live (2026-09-04): with the `-mindepth 2` and dotfile-exclusion fixes in place, a
  second run immediately after a fix produced no `RENAMED` lines for `pub`/`incoming` — idempotent
  against the zone directories, as intended.

## 5. A diagnostic-wording note (needs re-verification against a live CP/M client)

Under de-tnfsd, `OPENDIR`/`STAT`/`OPEN` against anything under `/incoming` are refused with a
uniform `EACCES` straight from the capability table (`LOOKUP`/`LIST` are both `no` for that zone) —
before any real filesystem call happens, and regardless of whether the exact name is known. This
is stricter than the old stock-`tnfsd` layout, where a `0333` directory blocked listing but still
let a client fetch a file by an exact known name; under de-tnfsd there's no equivalent gap.

The old guide documented `FUJIGET` failing against `INCOMING/` with `"failed -- parent path does
not exist"` rather than "denied" — a quirk of `FUJIGET`'s own parent-directory reachability probe
under stock `tnfsd`'s specific failure shape. **This hasn't been re-confirmed against de-tnfsd's
`EACCES`-from-capability-table response** — the underlying refusal reason has changed even though
the practical effect (read blocked) hasn't. Verify the actual wording your `FUJIGET` prints before
relying on it in your own documentation.

## 6. Quick verification checklist

Once your de-tnfsd is up with this layout, from CP/M:

```
FUJIDIR N1:TNFS://<host>/            -> lists pub/ and incoming/
FUJIDIR N1:TNFS://<host>/PUB/        -> lists whatever you've put there
FUJIGET N1:TNFS://<host>/PUB/<file> local.txt   -> succeeds
FUJIPUT local.txt N1:TNFS://<host>/PUB/x.txt    -> denied
FUJIPUT local.txt N1:TNFS://<host>/INCOMING/x.txt -> succeeds
FUJIDIR N1:TNFS://<host>/INCOMING/              -> fails (unlisted)
FUJIGET N1:TNFS://<host>/INCOMING/x.txt out.txt -> fails (unreadable)
```

If the first two unexpectedly fail with "not found"/zone errors, double-check you're running our
fork's `deploy` branch (§1) and not vanilla upstream — without the case-fold patch, CP/M's
uppercased `/PUB`/`/INCOMING` can't resolve to either zone at all.
