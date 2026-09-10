# Firmware uploader, patched for Apple Silicon Macs

This file is a patched drop-in replacement for upstream FujiNet's
[`fujinet_firmware_uploader.py`](https://github.com/FujiNetWIFI/fujinet-firmware/blob/master/fujinet_firmware_uploader.py).
The script flashes new firmware onto a FujiNet adapter over USB.

The stock script does not run on an Apple Silicon (M-series) Mac. It shells out to
`esptool.py` and `pio device monitor` from a `~/.platformio/packages/tool-esptoolpy/`
install. In the past, PlatformIO did not publish its bundled `esptool.py` package for
macOS `arm64`. So flashing from an M-series Mac needed a separate Intel Mac, or a
Rosetta workaround, just to run this one script.

**This is an interim fix, not a fork of the project.** It is not a pull request against
upstream. It is not meant to become one; see the note below.

Once upstream ships a version that works natively on Apple Silicon, delete this folder.
Go back to the original script. Check the link above regularly.

## What's different

- Installation needs only `pip install requests esptool`. It does not need PlatformIO.
- Flashing runs `python -m esptool` instead of shelling out to PlatformIO's copy. This
  uses whichever `esptool` is pip-installed for the interpreter that runs the script.
  `esptool` is pure Python and ships `arm64` wheels. So it works the same way on Intel
  and Apple Silicon.
- The uploader flashes both `firmware.bin` and `littlefs.bin` in one `write-flash` call,
  instead of two separate `esptool` calls. This call needs only one connect/reset
  handshake with the chip.
- Monitoring the device after a flash uses `esptool`'s own `pyserial` dependency
  (`python -m serial.tools.miniterm`), instead of `pio device monitor`. The reason is
  the same: `pyserial` is always present, works on any architecture, and needs no
  PlatformIO.
- Internally, `subprocess.run(...)` with an argument list replaces the original's
  `os.system(...)` call on a hand-quoted command string. This avoids shell-quoting
  issues. It does not change how the script behaves for the user.

Everything else stays the same as upstream: the GitHub release browser, the interactive
menus, USB port auto-detection, and command-line flags.

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
for the full walkthrough: the menu system, device monitoring, and troubleshooting. None
of that changed here. Only the installation steps and the flashing/monitoring internals
described above changed.

## Why this lives here instead of as an upstream PR

FujiNet's own maintainers have asked contributors not to open pull requests on their
own. Contributors relay confirmed findings to the maintainers directly instead. The
maintainers decide whether and how to fold a change into upstream.

This fix is small and self-contained. It solves a real problem: the maintainer himself
has mentioned using a separate Intel Mac just to flash firmware. So this tool is
published here as a standalone interim tool, instead of left unused in a private
branch.

## What changed

**Rule 2 (sentence limits).** The two long compound sentences in the opening
paragraphs (the "shells out to `esptool.py`..." sentence and the "confirmed findings
get relayed..." sentence) were each split into three shorter sentences, one fact each.

**Rule 4 (active voice).** "Both `firmware.bin` and `littlefs.bin` are flashed in a
single `write-flash` call" → "The uploader flashes both `firmware.bin` and
`littlefs.bin` in one `write-flash` call." "PlatformIO's bundled `esptool.py` package
historically wasn't published for macOS `arm64`" → "PlatformIO did not publish its
bundled `esptool.py` package for macOS `arm64`" (names PlatformIO as the actual agent).
"confirmed findings get relayed to them" → "Contributors relay confirmed findings to
the maintainers directly."

**Rule 9/10 (word substitutions, slop, em dashes).** All contractions expanded
(*doesn't* → *does not*, *isn't* → *is not*, *It's* → *It is*, *that's* → *So*,
*wasn't* → *did not*, *he's* → *has*). Every em dash removed and replaced with a
period or comma, splitting the sentence around it. *unilaterally* → *on their own*.
*invocations* → *calls*. *proper* dropped as an empty qualifier before *`arm64`
wheels*. *periodically* → *regularly*.

**Rule 3 (one instruction per sentence).** "drop this folder and go back to the
original script; check the link above periodically" became three separate imperative
sentences.

**Left alone.** All code, filenames, paths, commands, and links are reproduced exactly
as in the original, including the code block and both upstream URLs. The "interim fix,
not a fork" framing and the maintainer-relay policy explanation are both preserved as
facts, only restated in shorter active sentences.
