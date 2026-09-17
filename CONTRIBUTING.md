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
