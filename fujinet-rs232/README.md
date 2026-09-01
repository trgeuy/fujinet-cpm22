# Bringing up a physical FujiNet RS-232 adapter for CP/M

The adapter ships with a manual written for an IBM PC running MS-DOS. Its physical-hardware
material — the serial connector, the lamps, USB power, the 2.4 GHz WiFi band caveat — applies
unchanged here, and isn't repeated in full below. What's different for CP/M is everything
**after** the hardware is plugged in: the DOS manual's whole setup story is built around
`CONFIG.SYS`/`CONFIG.EXE`, and neither exists in this world. This doc is the CP/M-side
replacement for the DOS manual's Section 2 ("Setup"), tested against a real FujiNet RS-232
adapter on a real Altair 8800c.

## Why the DOS instructions don't apply

- **CP/M has no loadable-driver model.** DOS's setup hinges on `DEVICE=FUJINET.SYS` /
  `DEVICE=FUJIPRN.SYS` lines in `CONFIG.SYS`. CP/M 2.2 has nothing equivalent to load — there's
  no driver to install at all.
- **`CONFIG.EXE` can't run under CP/M.** It's an 8086 DOS binary; CP/M on this hardware runs on
  an 8080/Z80. There's no CP/M port of it, and no CP/M-native replacement for its WiFi-scan
  screen, host-slot editor, or configuration display.

So the two jobs `CONFIG.EXE` normally does — join a WiFi network, and set the adapter up the
way you want it — have to happen **entirely independent of whatever the host computer is
running.** That turns out to be true of the real FujiNet firmware generally: it's not a DOS
feature bolted on, it's a capability of the adapter itself.

## 1. Physical connection

Identical to the DOS manual's Section 1: seat the adapter on the host's serial port (thumbscrews
finger-tight), and power it over USB-C from a wall charger or a spare USB port — **the adapter
never draws power from the serial line itself.** See that manual for the full lamp/connector
tour if you want it; nothing here is CP/M-specific.

## 2. Configure WiFi (and everything else) before it ever talks to CP/M

The adapter reads a plain-text config file, `fnconfig.ini`, off its microSD card at boot and
applies it before it does anything else — including joining WiFi. This is the whole trick:
none of this setup goes over the serial line or touches the host computer at all.

1. **You'll need to supply your own microSD card** — none comes with the adapter. Use one
   formatted FAT32, and stick to **4 GB or 8 GB**: FujiNet's own documentation specifically
   recommends that range and cautions that larger cards can cause issues.
2. Copy [`fnconfig.ini.sample`](fnconfig.ini.sample) (in this folder) onto the card's root as
   `fnconfig.ini`, and edit two lines under `[WiFi]`:
   ```ini
   [WiFi]
   enabled=1
   SSID=your-network-name
   passphrase=your-network-password
   ```
   Only the 2.4 GHz band works — same caveat as the DOS manual (Section 1: "if your network
   hides its 2.4-gigahertz band behind the same name as a 5-gigahertz band... give the slower
   band its own name").
3. Seat the card in the adapter, then power it on (or reset it, if it was already running).
   It joins the network on its own — no host interaction, no button press, nothing typed
   anywhere. The white WiFi lamp lights once it's connected.

`fnconfig.ini.sample` here is the actual factory-default template FujiNet ships on the SD
card (SSID/passphrase left as the literal placeholders `ssid`/`passwd` — fill in your own).
Two settings worth knowing about while you're in there:

- **`[CPM] cpm_enabled=`** is unrelated to anything in this repo — it toggles FujiNet's own
  *embedded* CP/M emulator (for an entirely different kind of client, an 8-bit machine dialing
  in as a dumb terminal). It has nothing to do with a real CP/M machine acting as the client,
  which is what this whole project is. Leave it at its default; it doesn't affect FUJIGET/
  FUJIPUT/FUJIDIR/FUJIMKD either way.
- **`[Host1]`–`[Host4]`** are FujiNet's own "Host Slots" — the thing DOS's `CONFIG.EXE`/
  `FMOUNT` mount disk images from. **The CP/M tool suite in this repo doesn't use them at
  all** — `FUJIGET`/`FUJIPUT`/`FUJIDIR`/`FUJIMKD` all take a full `N1:TNFS://host/path`-style
  URL directly, bypassing host slots entirely. They're harmless to leave at their defaults;
  they only matter if you also intend to use FujiNet's own web UI for disk-image browsing.

## 3. Find the adapter's IP address

There's no `CONFIG.EXE` screen to read it off, so use whatever you'd normally use to find a
new device on your LAN — a network scanner app (e.g. LanScan), your router's DHCP client
list, or `arp -a` after pinging the subnet's broadcast address. It advertises the hostname set
by `devicename=` in `fnconfig.ini` (`fujinet` by default) if your network resolves mDNS/
`.local` names; otherwise go by IP.

## 4. Set the serial baud rate from the web UI

Once you have its IP, browse to `http://<that-ip>` — the same admin page the DOS manual
mentions ("the FujiNet serves a full settings page to any web browser in the house"). This
page is how you set everything from here on, independent of CP/M or the host entirely. The one
setting that matters for a serial link: the `[Serial] baud=` value has to match whatever your
serial board is actually wired/jumpered for.

**On a classic Altair 88-2SIO, the baud rate is set by a physical jumper or DIP switch on the
board itself — it is not software-configurable from the CP/M side.** So the order of operations
is: find out what your 2SIO's serial port is actually set to (board silkscreen, jumper
documentation, or ask whoever configured it), then set the FujiNet's `[Serial] baud=` to match
that value from the web UI — not the other way around. This project's own 8800c has its 2SIO's
FujiNet-facing port fixed at a specific baud (confirmed working at both 38400 and, in later
testing, a slower rate) — there's no universal "right" answer, only "whatever your board is
physically set to."

The web UI rewrites `fnconfig.ini` on the SD card live as you change settings — pull the card
afterward if you want to confirm what actually landed, or keep a copy of your working config
for next time you set one of these up.

## 5. Get the CP/M tool suite onto the machine

This is identical to the emulator case — see this repo's main
[README](https://github.com/trgeuy/fujinet-cpm22#3-get-the-tools-onto-your-cpm-disk),
section 3, "Get the tools onto your CP/M disk." Nothing about that step depends on whether
you're talking to real hardware or FujiNet-PC on the other end of the serial line.

## 6. Verify the link

From the CP/M prompt, once the tools are installed and the adapter shows its WiFi lamp lit:

```
A>FUJIDIR N1:TNFS://tnfs.fujinet.online/
```

A real directory listing back confirms the whole chain — CP/M, the serial link, the adapter,
its WiFi join, and the outbound network path — is working end to end.

## Known real-hardware differences from the emulator

Worth knowing before you assume something's broken:

- **No flow control.** Classic serial boards like the 2SIO have none — pacing has to stay
  inside what CP/M's own console-read loop can keep up with, which in practice means well
  under the link's nominal baud rate. If you're driving the link with a script rather than a
  human typing, don't blast data at full baud; add per-character pacing.
- **Real hardware is measurably slower than the emulator, even locally.** In this project's own
  measurements, a real adapter took roughly 2.5–3x longer per FujiBus request/response cycle
  than the desktop FujiNet-PC build used for emulator testing — likely the real ESP32
  firmware's own processing time, not a network or CPU-speed effect. Don't expect
  emulator-level throughput.
- **Check the physical network path if a request that should work reports "server not
  responding."** A correct command against a reachable host can still fail for mundane
  reasons on the wired/WiFi side between the adapter and its target (switch port, cabling) —
  rule that out before suspecting the CP/M tools or the adapter's firmware.
