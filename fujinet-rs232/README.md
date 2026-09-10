# Bringing up a physical FujiNet RS-232 adapter for CP/M

The adapter ships with a manual written for an IBM PC that runs MS-DOS. That manual's
physical-hardware material still applies here: the serial connector, the lamps, USB power, and
the 2.4 GHz WiFi band caveat. This document does not repeat that material in full.

What is different for CP/M is everything that happens **after** you plug in the hardware. The
DOS manual builds its whole setup story around `CONFIG.SYS` and `CONFIG.EXE`. Neither one exists
in CP/M.

This document replaces the DOS manual's Section 2 ("Setup") for CP/M. The team tested it against
a real FujiNet RS-232 adapter on a real Altair 8800c.

## Why the DOS instructions do not apply

- **CP/M has no loadable-driver model.** DOS setup depends on `DEVICE=FUJINET.SYS` and
  `DEVICE=FUJIPRN.SYS` lines in `CONFIG.SYS`. CP/M 2.2 has no equivalent. It has no driver to
  install at all.
- **`CONFIG.EXE` cannot run under CP/M.** It is an 8086 DOS binary. CP/M on this hardware runs on
  an 8080 or Z80 processor. No CP/M port of `CONFIG.EXE` exists. CP/M also has no native
  replacement for its WiFi-scan screen, its host-slot editor, or its configuration display.

`CONFIG.EXE` normally does two jobs: it joins a WiFi network, and it sets up the adapter. Under
CP/M, both jobs **happen entirely independent of the host computer.** This is true of the
FujiNet firmware in general. WiFi setup and adapter configuration are not a DOS feature. They are
a capability of the adapter itself.

## 1. Physical connection

This step is identical to the DOS manual's Section 1. Seat the adapter on the host's serial
port, with the thumbscrews finger-tight. Power it over USB-C, from a wall charger or a spare USB
port. **The adapter never draws power from the serial line itself.** See the DOS manual for the
full lamp and connector tour. Nothing in this step is CP/M-specific.

## 2. Configure WiFi (and everything else) before it ever talks to CP/M

At boot, the adapter reads a plain-text config file, `fnconfig.ini`, from its microSD card. It
applies that file before it does anything else, including before it joins WiFi. This setup never
goes over the serial line. It never touches the host computer at all.

1. **You must supply your own microSD card.** None comes with the adapter. Format the card
   FAT32. Use a **4 GB or 8 GB** card: FujiNet's own documentation recommends that range and
   warns that larger cards can cause problems.
2. Copy [`fnconfig.ini.sample`](fnconfig.ini.sample), from this folder, onto the card's root as
   `fnconfig.ini`. Edit two lines under `[WiFi]`:
   ```ini
   [WiFi]
   enabled=1
   SSID=your-network-name
   passphrase=your-network-password
   ```
   Only the 2.4 GHz band works. The DOS manual gives the same caveat, in its Section 1: "if your
   network hides its 2.4-gigahertz band behind the same name as a 5-gigahertz band... give the
   slower band its own name."
3. Seat the card in the adapter. Power it on, or reset it if it is already running. The adapter
   joins the network on its own. It needs no host interaction, no button press, and nothing
   typed anywhere. The white WiFi lamp lights once the adapter connects.

`fnconfig.ini.sample` is the actual factory-default template FujiNet ships on the SD card. Its
SSID and passphrase are left as the literal placeholders `ssid` and `passwd`; fill in your own.
Two more settings are worth knowing about while you are in the file:

- **`[CPM] cpm_enabled=`** is unrelated to anything in this repository. It toggles FujiNet's own
  *embedded* CP/M emulator, for a different kind of client: an 8-bit machine that dials in as a
  dumb terminal. This project uses a real CP/M machine as the client instead, so this setting
  does not apply to it. Leave it at its default. It does not affect FUJIGET, FUJIPUT, or FUJIDIR
  either way.
- **`[Host1]` through `[Host4]`** are FujiNet's own "Host Slots." DOS's `CONFIG.EXE` and `FMOUNT`
  mount disk images from these slots. **The CP/M tool suite in this repository does not use them
  at all.** `FUJIGET`, `FUJIPUT`, and `FUJIDIR` each take a full `N1:TNFS://host/path`-style URL
  directly, and bypass host slots entirely. It is safe to leave them at their defaults. They only
  matter if you also plan to use FujiNet's own web UI for disk-image browsing.

## 3. Find the adapter's IP address

There is no `CONFIG.EXE` screen to read the address from. Instead, use whatever you would
normally use to find a new device on your LAN: a network scanner app (for example, LanScan),
your router's DHCP client list, or `arp -a` after you ping the subnet's broadcast address. If
your network resolves mDNS or `.local` names, the adapter advertises the hostname set by
`devicename=` in `fnconfig.ini` (`fujinet` by default). Otherwise, use its IP address.

## 4. Set the serial baud rate from the web UI

Once you have the IP address, browse to `http://<that-ip>`. This is the same admin page the DOS
manual mentions: "the FujiNet serves a full settings page to any web browser in the house." Use
this page to set everything from here on, independent of CP/M or the host. One setting matters
most for a serial link: the `[Serial] baud=` value must match whatever baud rate your serial
board is wired or jumpered for.

**On a classic Altair 88-2SIO, a physical jumper or DIP switch on the board sets the baud rate.**
You cannot configure it from the CP/M side in software. So follow this order: first, find what
your 2SIO's serial port is actually set to (check the board silkscreen, the jumper documentation,
or ask whoever configured it). Then set the FujiNet's `[Serial] baud=` to match that value, from
the web UI. Do not do this in the other order. This project's own 8800c has its 2SIO's
FujiNet-facing port fixed at a specific baud rate; testing confirmed it works at both 38400 and,
later, at a slower rate. There is no single correct answer, only whatever your board is
physically set to.

The web UI rewrites `fnconfig.ini` on the SD card live, as you change settings. Pull the card
afterward if you want to confirm what actually landed. You can also keep a copy of your working
config, for the next time you set one of these up.

## 5. Get the CP/M tool suite onto the machine

This step is identical to the emulator case. See this repository's main
[README](https://github.com/trgeuy/fujinet-cpm22#3-get-the-tools-onto-your-cpm-disk), section 3,
"Get the tools onto your CP/M disk." That step does not depend on whether real hardware or
FujiNet-PC is on the other end of the serial line.

## 6. Verify the link

Install the tools. Confirm the adapter's WiFi lamp is lit. Then, from the CP/M prompt, run:

```
A>FUJIDIR N1:TNFS://tnfs.fujinet.online/
```

A real directory listing back confirms the whole chain works end to end: CP/M, the serial link,
the adapter, its WiFi join, and the outbound network path.

## Known real-hardware differences from the emulator

Know these differences before you assume something is broken:

- **No flow control.** Classic serial boards like the 2SIO have none. Pacing must stay inside
  what CP/M's own console-read loop can keep up with. In practice, this means well under the
  link's nominal baud rate. If a script drives the link, instead of a human typing, do not send
  data at full baud. Add per-character pacing instead.
- **Real hardware is measurably slower than the emulator, even locally.** This project isolated
  the cause. The real adapter's own ESP32 firmware is measurably slower per FujiBus
  request/response cycle than the desktop FujiNet-PC software. The cause is not CPU clock speed:
  real hardware runs within 1.35% of the emulator's rate. The cause is also not the 2SIO board.
  See [`throughput-investigation.md`](throughput-investigation.md) for the full isolation
  experiment and numbers. Do not expect emulator-level throughput.
- **Check the physical network path if a request that should work reports "server not
  responding."** A correct command against a reachable host can still fail for ordinary reasons
  on the wired or WiFi path between the adapter and its target, such as a switch port or a cable.
  Rule out these causes before you suspect the CP/M tools or the adapter's firmware.

---

## What changed

Full Simplified-Technical-English-style rewrite, not a light pass. Every fact, number, file
name, command, code sample, and quoted string from the original is preserved exactly. Nothing was
added or dropped.

**Rule 2 (sentence limits).** The original is written in a dense style, with many 30-60 word
sentences that carry two or three ideas joined by em dashes or semicolons. Almost every sentence
in the rewrite is under 20-25 words; each long original sentence was split into several short
ones, one idea per sentence.

**Rule 10 (em dashes).** The original uses the em dash constantly, as a stand-in for commas,
colons, periods, and parentheses. Every one was removed and replaced with whichever of those it
was actually doing the job of in that sentence.

**Rule 4 (active voice).** A few constructions with no clear subject ("have to happen entirely
independent of...", "is inflated by...") were rewritten with an explicit agent doing the action.

**Contractions.** Expanded throughout (*isn't* to *is not*, *doesn't* to *does not*, *you'll* to
*you must*, and so on), except inside the two direct quotes from the DOS manual and the FujiNet
web UI's own wording, which are left byte-for-byte exact per the skill's rule against simplifying
quoted text.

**Left alone.** Both direct quotes from the DOS manual, every code block, every command, every
file name, and every link are reproduced exactly as in the original. Established short technical
terms (`FujiBus request/response cycle`, `Host Slots`, `loadable-driver model`) were kept as-is:
each is three nouns or fewer, so none trips the noun-cluster rule.
