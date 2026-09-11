# Running your own TNFS server, optimized for CP/M

Want to host your own TNFS server instead of relying on someone else's? See
[de-tnfsd](https://github.com/trgeuy/de-tnfsd), our fork of
[deltecent/de-tnfsd](https://github.com/deltecent/de-tnfsd). It splits the
served namespace into a read-only `pub/` and a write-only `incoming/` drop
box, the classic anonymous-FTP layout, enforced by the daemon itself rather
than by filesystem permission tricks. Our fork adds the pieces a CP/M client
needs: case-insensitive `pub`/`incoming` zone matching (CP/M's command
processor uppercases every path before any program sees it), and an optional
`contrib/tnfs-case-fix/` script that keeps leaf file names uppercase-reachable
and stages finished uploads in a `for-review/` directory for a human to
approve into `pub/`. See that repo's `README.md` for build, install, and
setup instructions.

This guide is not part of the packaged release. Like `altairsim/` and
`testing/`, it is only useful if you are setting up a server yourself. Get it
directly from the repo:
<https://github.com/trgeuy/fujinet-cpm22/tree/main/tnfsd-server-setup>.

The rest of this document covers only what is specific to CP/M and to this
repo's own tools (`FUJIGET`/`FUJIPUT`/`FUJIDIR`), not to `de-tnfsd`'s own
setup.

## The CP/M-side gotcha: everything you type gets uppercased first

**This altairsim CP/M build, and possibly others, uppercases the whole
command-line tail before any `.COM` program sees it, including all four
FujiNet tools.** The team confirmed this by reading `FUJIDIR.ASM`'s own
command-tail parser: it copies bytes verbatim, with no case-folding anywhere
in the source. There is no way to override this from the CP/M side.
`FUJIDIR N1:TNFS://host/pub/` and `FUJIDIR N1:TNFS://host/PUB/` both result in
the same uppercased request being sent from CP/M.

This is exactly why `de-tnfsd`'s fixed `pub`/`incoming` zone names need to
match case-insensitively, and why leaf content inside `pub` still needs to be
uppercase on disk.

### Leaf content inside `pub` still needs to be uppercase on disk

Once a CP/M client is inside a resolved zone, it looks up filenames on disk
exactly as typed. The CCP still uppercases them first, and Linux still does
an exact-case filesystem lookup. Anything that reaches `pub` through
`FUJIPUT` is already safe, since the CCP uppercases the whole path before the
tool ever sees it. The real risk is content added **directly on the
server**: `scp`, `rsync`, or unpacking a `.tar.gz`. These routinely use
lowercase or mixed-case names, which would otherwise stay silently
unreachable from CP/M forever. `de-tnfsd`'s `contrib/tnfs-case-fix/` fixes
this automatically; see that repo for install steps.

## A diagnostic-wording note (needs re-verification against a live CP/M client)

Under de-tnfsd, `OPENDIR`, `STAT`, and `OPEN` against anything under
`/incoming` all get refused with a uniform `EACCES`. This comes straight from
the capability table, since `LOOKUP` and `LIST` are both `no` for that zone.
The refusal happens before any real filesystem call, no matter whether the
exact name is known. This is stricter than the old stock-`tnfsd` layout.
There, a `0333` directory blocked listing but still let a client fetch a file
by an exact known name. de-tnfsd has no equivalent gap.

The old guide documented `FUJIGET` failing against `INCOMING/` with `"failed
-- parent path does not exist"`, rather than "denied". This was a quirk of
`FUJIGET`'s own parent-directory reachability probe, under stock `tnfsd`'s
specific failure shape. **The team has not re-confirmed this wording against
de-tnfsd's `EACCES`-from-capability-table response.** The underlying refusal
reason has changed, even though the practical effect, a blocked read, has
not. Verify the actual wording your `FUJIGET` prints before you rely on it in
your own documentation.

## Quick verification checklist

Once your de-tnfsd is running with this layout, run these commands from
CP/M:

```
FUJIDIR N1:TNFS://<host>/            -> lists pub/ and incoming/
FUJIDIR N1:TNFS://<host>/PUB/        -> lists whatever you've put there
FUJIGET N1:TNFS://<host>/PUB/<file> local.txt   -> succeeds
FUJIPUT local.txt N1:TNFS://<host>/PUB/x.txt    -> denied
FUJIPUT local.txt N1:TNFS://<host>/INCOMING/x.txt -> succeeds
FUJIDIR N1:TNFS://<host>/INCOMING/              -> fails (unlisted)
FUJIGET N1:TNFS://<host>/INCOMING/x.txt out.txt -> fails (unreadable)
```

If the first two commands unexpectedly fail with "not found" or zone errors,
check that you are running our `de-tnfsd` fork, not vanilla upstream. Without
its case-fold patch, CP/M's uppercased `/PUB`/`/INCOMING` cannot resolve to
either zone at all.

If you installed `contrib/tnfs-case-fix/`, wait for the next cron tick (up to
15 minutes) after the upload above, then check on the host itself, not over
TNFS:

```
ls -la /srv/tnfs/for-review/
```

The file you uploaded to `INCOMING/` should now be there, and gone from
`incoming/`.
