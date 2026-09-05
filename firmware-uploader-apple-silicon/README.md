# Firmware uploader, patched for Apple Silicon Macs

This is a patched drop-in replacement for upstream FujiNet's
[`fujinet_firmware_uploader.py`](https://github.com/FujiNetWIFI/fujinet-firmware/blob/master/fujinet_firmware_uploader.py) —
the script used to flash new firmware onto a FujiNet adapter over USB. The stock
script doesn't run on an Apple Silicon (M-series) Mac: it shells out to
`esptool.py` and `pio device monitor` from a `~/.platformio/packages/tool-esptoolpy/`
install, and PlatformIO's bundled `esptool.py` package historically wasn't published
for macOS `arm64`. In practice that's meant flashing from an M-series Mac needing a
separate Intel Mac (or Rosetta workaround) just to run this one script.

**This is an interim fix, not a fork of the project.** It's not a pull request against
upstream, and it isn't meant to become one — see the note below. Once upstream ships
a version that works natively on Apple Silicon, drop this folder and go back to the
original script; check the link above periodically.

## What's different

- Installation is just `pip install requests esptool` — no PlatformIO required at all.
- Flashing runs `python -m esptool` (whichever `esptool` is pip-installed for the
  interpreter running the script) instead of shelling out to PlatformIO's copy.
  `esptool` is pure Python and ships proper `arm64` wheels, so this works the same
  on Intel and Apple Silicon.
- Both `firmware.bin` and `littlefs.bin` are flashed in a single `write-flash` call
  (one connect/reset handshake with the chip) instead of two separate `esptool`
  invocations.
- Post-flash device monitoring uses `esptool`'s own `pyserial` dependency
  (`python -m serial.tools.miniterm`) instead of `pio device monitor` — same
  reasoning: always present, architecture-independent, no PlatformIO needed.
- Internally, `subprocess.run(...)` with an argument list replaces the original's
  `os.system(...)` on a hand-quoted command string — avoids shell-quoting issues
  and is not a functional change from the user's point of view.

Everything else — the GitHub release browser, the interactive menus, USB port
auto-detection, command-line flags — is untouched from upstream.

## Requirements

- Python 3.6+
- `pip install requests esptool`
- A FujiNet device connected via USB

## Usage

Identical to upstream:

```
python fujinet_firmware_uploader.py            # interactive menu
python fujinet_firmware_uploader.py --latest   # auto-select latest release
python fujinet_firmware_uploader.py -p /dev/cu.usbserial-XXXX  # specify port
```

See upstream's
[`fujinet_firmware_uploader.md`](https://github.com/FujiNetWIFI/fujinet-firmware/blob/master/fujinet_firmware_uploader.md)
for the full walkthrough (menu system, device monitoring, troubleshooting) — none
of that changed here, only the installation story and the flashing/monitoring
internals described above.

## Why this lives here instead of as an upstream PR

FujiNet's own maintainers have asked contributors not to open PRs unilaterally;
confirmed findings get relayed to them directly instead, and it's their call
whether/how to fold something in upstream. This fix is small, self-contained, and
solves a real problem the maintainer himself has hit (he's mentioned using a
separate Intel Mac just to flash), so it's published here as a standalone interim
tool rather than left sitting unused in a private branch.
