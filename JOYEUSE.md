# joyeuse: Redmi Note 9 Pro (SM7125 "atoll")

Port of the sweet bring-up to the global Redmi Note 9 Pro (`joyeuse`;
`curtana`/`excalibur` are the same "miatoll" platform). **Status
2026-10-19: boots iOS 16.7.16 to the home screen, with working touch.**
Kernel `5e42f18` (fork CI run 39290730255), shim with
`sweetfb_noconsole=1 sweetusb=2 sweettouchdelay=120`, Huaxing panel
(FT8756). Confirmed on the phone: unlocking by swipe, the home screen,
opening Settings, and the home gesture (leaving an app).

## Verified on the phone (2026-10-19)

- `fastboot boot` of the shim works with the stock MIUI 14 ABL; the
  read-only UFS probe sees LUN0 (~115 GB) and the GPT.
- XNU: framebuffer (`AppleCLCD 1080x2400 at 0x9c000000`), UFS root on
  `userdata`, SMP with `cpus=6`, launchd, backboardd, SpringBoard.
- The CPU nodes must stay `qcom,kryo470`: SweetCPU (xnu 0018) matches that
  name. With `kryo465` the boot stops silently right after AppleCLCD.
- USB Ethernet live log to a Mac (`tools/sweet-usbnet-macos.sh`, needs
  `sweetusb=2`).
- Touch: SE11 comes up with the SPI protocol firmware (proto 1). Polled FIFO
  SPI handles the 32 KiB firmware frames. The FT8756 firmware download
  (PRAM + DRAM, ECC) works, and the chip runs (`chip 0x87 fw 0xe`). HID
  down/up and swipes reach SpringBoard. The QUP1 s_ahb branch is
  hardware-gated: its CLK_OFF bit is not a failure.
- The first boot sits on the Apple logo while lsd builds the LaunchServices
  database; SpringBoard waits in `_LSContextInitCommon`.

Flashing notes: MIUI's `flash_all` writes `sparsecrclist`, so ABL then
CRC-checks `userdata`. Flash an empty `SPARSECRC-LIST` before the iOS root.
Homebrew fastboot 37 pads AVB images (`dtbo`/`boot`/`recovery`), and ABL
rejects them with "Check CRC failed"; platform-tools r32.0.0 does not pad.
Fastboot can also hang because some app holds the phone's USB device
(Chrome WebUSB tabs, Spotify): check with
`ioreg -r -n Android -l | grep IOUserClientCreator`. OrangeFox (R12.0,
R11.3) did not boot with `fastboot boot` here.

## How much differs

Compared from the stock MIUI V14.0.3.0.SJZMIXM `boot.img`, whose kernel
carries both the atoll and the sdmmagpie (SM7150) base DTBs, plus the
joyeuse DTBO.

| Block | Address | joyeuse vs sweet |
| --- | --- | --- |
| GICv3 GICD / GICR | `0x17a00000` / `0x17a60000` | same |
| UFS host | `0x1d84000` | same |
| SPMI (core / obs / cnfg) | `0xc440000` / `0xe600000` / `0xc40a000` | same |
| RPMh apps_rsc | `0x18220000` | same (joyeuse needs no vote) |
| IMEM restart reason, PS_HOLD | `0x146aa65c`, `0xc264000` | same |
| ABL framebuffer (cont_splash) | `0x9c000000`, `0x1700000` | same |
| USB dwc3, GCC USB clocks | `0xa600000`, `0xf004`.. | same |
| CPUs (MPIDR) | `0x000`..`0x700`, 6x A55 + 2x A76 | same |
| Keys | PON SID0 `0x810`, PM6150L GPIO2 (vol+) | same |
| Fixed reserved memory | highest ends `0xa1200000` (sweet `0xa1600000`) | both RAM windows of mkadt stay free |
| Panel | 1080x2400 | LCD (Huaxing FT8756 or Tianma NT36675) instead of AMOLED |
| **Touch** | | **different**, see below |
| **QUP1 clock vote** | GCC `0x52008` | sweet (SM7150) uses `0x5200c` |

### Touch

sweet: Goodix GT9896 over I2C on QUP SE7, powered through an RPMh vote.
joyeuse: the touch controller is inside the LCD driver chip (TDDI), on
**SPI**, QUP SE11 (`spi@a94000`), 8 MHz max, mode 0, CS0:

- pins: GPIO 53-56 (`qup15`, WEST tile `0x3500000`), reset GPIO 8 and
  IRQ GPIO 9 (NORTH tile `0x3900000`)
- clocks: GCC vote `0x52008` bits 18-21 (wrapper 1) and 27 (SE11), RCG
  `0x18608`
- power: L18A (vddio) and LCDB LAB/IBB are the panel's rails, left on by ABL
- Huaxing panel -> Focaltech FT8756, Tianma panel -> Novatek NT36675. Both
  are flashless: the host downloads firmware to the IC after every reset.

Driver: `bsd/dev/sweet_touch_spi.c` (xnu patch 0082), ported from Xiaomi's
miatoll drivers (MiCode `curtana-q-oss`, `drivers/input/touchscreen/
{ft8756_spi,nt36xxx_spi}`). `sweet_touch_init()` starts it when the ADT has
`/sweet-touch` = `xiaomi,joyeuse-spi`; sweet's ADT has no such node, so
sweet is unchanged (its `mkadt.py` output is byte-identical). Boot-args:
`sweettouchic=1` (force FT8756) / `2` (force NT36675), `sweettouchdiv=N`
(SPI clock 19.2 MHz / N, default 3 = 6.4 MHz), plus sweet's `sweettouch`
and `sweettouchdelay`.

## Build and boot (differences from README)

1. Back up as in README step 0 (same partition names on joyeuse).
2. Kernel: same CI workflow; patch 0082 is part of the series.
3. Root image: after `sweet-root-tweaks.py`, add the touch firmware:

   ```sh
   python3 tools/joyeuse-touch-fw.py touchfw/        # from the MIUI ROM, ~440 MB download
   sudo python3 tools/sweet-root-tweaks.py /mnt/iosroot --touch-fw touchfw/
   ```

   The blobs are Xiaomi's (sha256 FT8756 `83e7fb01…6c9b`, NT36675
   `1a27ab58…bedd` for that ROM) and stay out of git.
4. ADT: `python3 tools/mkadt.py shim/out/joyeuse.adt --highmem --board joyeuse`
5. Payload, shim, flash and boot: as README (macOS root image:
   `sudo tools/mkiosroot-macos.sh OS.dmg SYSOS.dmg APPOS.dmg out.img 16g --touch-fw touchfw`).
   For the log, add `sweetusb=2` and run `sudo tools/sweet-usbnet-macos.sh`.

Host test of the touch protocol layer (simulated ICs, real firmware):

```sh
tools/touch-spi-test/run.sh touchfw/focaltech_ts_fw_huaxing.bin touchfw/novatek_ts_tianma_fw.bin
```

## Not verified yet

- The Tianma panel / NT36675 path (63 KiB SRAM frames), since this phone has
  the Huaxing panel.
- IC detection probes Focaltech first; on a Novatek its frames are an offset
  read and a write into page-0 SRAM that the firmware download overwrites.
- Novatek is polled without its IRQ: the event buffer is read every 10 ms.
- Display off (patch 0079) blacks the pixels; on the LCD the backlight
  stays on (PM6150L WLED control is not implemented).
- Keys and battery on joyeuse (USB works).

## Sileo / Procursus (2026-10-19)

`tools/sweet-jb-image-macos.sh` (with `sweet-jb-install.py`) puts the Procursus
iOS 16 rootless bootstrap (`/var/jb`), sshd and queued .debs on the root
image. On the phone: prep_bootstrap.sh ran (exit 0), Sileo 2.5.1 is
installed by dpkg, and SSH with key auth works as mobile and root
(`ssh -i ssh/joyeuse_ed25519 root@192.168.7.2`). `cpus=8`: hw.ncpu 8.

Open issue (first boot after reflashing): the Apple logo stays up with the
system idle. SpringBoard, lsd and the `uicache` that dpkg's uikittools trigger
runs all sleep at 0 % CPU, no LaunchServices `*.csstore` exists yet, installd
is not running and installcoordinationd is. So this is a wait chain, not
slowness. Next: thread backtraces of lsd/uicache (kernel sampler,
`sweetsample=lsd,uicache,SpringBoard`) and installd's launch.
