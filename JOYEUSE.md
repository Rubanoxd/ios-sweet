# joyeuse: Redmi Note 9 Pro (SM7125 "atoll")

Port of the sweet bring-up to the global Redmi Note 9 Pro (`joyeuse`;
`curtana`/`excalibur` are the same "miatoll" platform). **Status
2026-10-19: prepared, not yet booted on the phone.** Everything below the
GENI layer is host-tested; the GENI SPI layer and the first boot are not.

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
5. Payload, shim, flash and boot: as README. Use an OrangeFox build for
   miatoll to read the log with `tools/sweet-log-pull.sh`.

Host test of the touch protocol layer (simulated ICs, real firmware):

```sh
tools/touch-spi-test/run.sh touchfw/focaltech_ts_fw_huaxing.bin touchfw/novatek_ts_tianma_fw.bin
```

## Not verified yet (check these in the first boot logs)

- **GENI SPI in polled FIFO mode for long frames** (up to 63 KiB). Linux
  uses DMA above the FIFO size; the driver relies on the sequencer waiting
  on an empty TX / full RX FIFO. Log: `SWEET TOUCH SPI: xfer ... error`.
  If it fails, `sweettouchdiv` higher is the first thing to try, DMA mode
  the real fix.
- SE11 must come up with the SPI protocol firmware loaded (proto 1) and its
  RCG either in DFS level 0 = XO or free to set; both are checked and logged.
- IC detection probes Focaltech first; on a Novatek its frames are an offset
  read and a write into page-0 SRAM that the firmware download overwrites.
- Novatek is polled without its IRQ: the event buffer is read every 10 ms.
- RAM: `--highmem` assumes the 6 GB layout of sweet (upper bank
  `0x1_00000000`, `0xfcc00000` bytes); check `/proc/iomem` in OrangeFox.
- ABL framebuffer format on the LCD (sweet: 32-bit BGRA, stride 1080*4).
- Display off (patch 0079) blacks the pixels; on the LCD the backlight
  stays on (PM6150L WLED control is not implemented).
- USB, battery, keys: same hardware addresses, untested on joyeuse.
