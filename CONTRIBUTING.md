# Issue process

Bug reports and feedback are welcome via GitHub Issues.

When a fix ships for an issue someone else filed:

- The tracking commit does **not** use `Fixes #N`/`Closes #N` — those auto-close on push,
  before the reporter has confirmed anything. Reference the issue number in prose instead
  (e.g. "addresses #N").
- The issue gets a comment summarizing what actually happened: the root cause, what changed,
  and the commit/release that has the fix — not just a link.
- The issue is left **open** for the reporter to confirm and close themselves. It only gets
  closed directly when the reporter asks for that, or when the report came from the maintainer.
