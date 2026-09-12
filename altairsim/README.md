# altairsim setup files

This folder has four files. Together, they get a fresh `altairsim` machine ready to talk to
FujiNet. This folder is not part of the packaged release. It is only useful if you are setting
up `altairsim` itself.

**Setting up for the first time?** Start with the main README's
[§1, "Get and install FujiNet-PC"](../README.md#1-get-and-install-fujinet-pc-the-rs232-build).
This repo does not include FujiNet-PC itself. §1 has the download link and install steps. Then
come back here. Short version of what each file in this folder is for:

- **`8800c.toml`** — an `altairsim` machine definition. It wires up a second 2SIO unit
  (`sio0:b`) to FujiNet-PC's BOIP port, per the main README's
  [§2, "Point altairsim at it"](../README.md#2-point-altairsim-at-it).
- **`CPM22-8MB-56K.DSK`** — the system disk `8800c.toml` boots from. An 8MB CP/M 2.2 disk with
  `altairsim`'s own Host Bridge tools (`R`/`W`/`HDIR`) and the `PCGET`/`PCPUT` reference
  utilities already on it. It does **not** ship `FUJIGET`/`FUJIPUT`/`FUJIDIR`; get those from
  the top level of this repo.
- **`BLANK-8MB.DSK`** — an empty second drive, wired up as `B:`.
- **`run-fujinet`** — a wrapper around FujiNet-PC's own `fujinet` binary. It restarts FujiNet-PC
  automatically if it exits with code 75 (`EX_TEMPFAIL`). Drop it into your extracted
  FujiNet-PC directory (see §1 above).

To boot: get FujiNet-PC running first
([§1](../README.md#1-get-and-install-fujinet-pc-the-rs232-build)), then, from this folder, run

```
altairsim 8800c.toml
```
