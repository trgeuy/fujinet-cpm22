# Issue process

File bug reports and feedback as GitHub Issues.

Follow this process when a fix ships for an issue someone else filed:

- Do not use `Fixes #N` or `Closes #N` in the tracking commit. Those keywords
  auto-close the issue on push, before the reporter confirms anything.
  Reference the issue number in prose instead (for example, "addresses #N").
- Add a comment to the issue. Explain what happened: the root cause, what
  changed, and the commit or release with the fix. A link alone is not
  enough.
- Leave the issue open so the reporter can confirm and close it. Close it
  directly only if the reporter asks, or if the report came from the
  maintainer.

---

## What changed

This is a full Simplified-Technical-English-style rewrite. The file was
already short and mostly clean, so the changes are smaller than a typical
pass, but three real violations were there.

**Rule 4 (active voice).** Two passive constructions had a clear agent
hiding behind them. "Bug reports and feedback are welcome via GitHub
Issues" became "File bug reports and feedback as GitHub Issues" (the
contributor is the agent). "The issue is left open... It only gets closed
directly when..." became "Leave the issue open... Close it directly only
if..." (the person handling the fix is the agent). The heading fragment
"When a fix ships for an issue someone else filed:" was also turned into a
direct instruction: "Follow this process when a fix ships for an issue
someone else filed:".

**Rule 2 (sentence limits).** One bullet ran a single sentence to 23 words,
over the 20-word instruction limit, by packing "add a comment" together
with everything the comment should say. Split into "Add a comment to the
issue." and "Explain what happened: the root cause, what changed, and the
commit or release with the fix."

**Rule 10 (em dashes).** Two em dashes removed: one replaced with a period
("...auto-close on push. Before the reporter confirms anything" combined
back into one sentence with a comma instead), one replaced with a period
("...with the fix. A link alone is not enough.").

**Minor clarity fix, not a numbered rule.** "commit/release" became
"commit or release" — a slash reads as shorthand, not as clear prose.

**Left alone.** `Fixes #N`, `Closes #N`, and `addresses #N` are exact
GitHub syntax and kept byte-for-byte. Nothing else in the file changed:
no facts were added or removed.
