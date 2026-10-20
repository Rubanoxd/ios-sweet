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

## Display controller: zero-copy swaps (xnu 0083, not yet booted)

Today the CPU copies every frame (the centered 1080x2400 part of
backboardd's 1125x2436 surface, 10 MB) into ABL's splash framebuffer.
`bsd/dev/sweet_dpu.c` drives the MDSS display pipe that ABL left scanning
out that framebuffer instead:

- `sweetdpu=1` (default): read-only dump, `SWEET DPU:` lines with every
  source pipe (SRC_SIZE, XY, address, stride, format, op mode) and CTL
  (layers, flush, intf). It also picks the pipe whose SRC0_ADDR is the splash.
- `sweetdpu=2` (needs `sweetfb_noconsole=1`): zero-copy. backboardd's two
  display-sized IOSurfaces get physical slots inside cont_splash_region
  (`0x9c000000` and `0x9cc48000`, 0xab8000 bytes each). A full-screen swap
  of one of them cleans its caches through its write-back kernel mapping and
  repoints the pipe (SRC0_ADDR, YSTRIDE0 4608, SRC_XY 22,18) with a CTL
  flush at the next frame. Other swaps use the copy path, and display off
  restores ABL's framebuffer.

The slots stay inside the carve-out the display already reads, so the MDSS
IOMMU setup does not matter. Writes are 3 SSPP registers and CTL_FLUSH
(nothing else of ABL's pipeline). Register offsets: Linux dpu1
(dpu_hw_sspp.c, dpu_hw_ctl.c), Xiaomi sde_hw_sspp.c, DT qcom,sde-*-off;
mdp_phys `0xae00000`.

Test, in order:
1. `shim/out/shim-boot-joyeuse-dpu1.img`: check the `SWEET DPU:` dump in
   the live log (pipe found, format and stride as expected).
2. `shim/out/shim-boot-joyeuse-dpu2.img`: expect `pool slot 1/0 ...` and
   `pipe ... now fetches 0x9cc48000`, a smoother GUI, and lower CPU
   (`ssh ... top`).

Result on hardware (2026-10-19): both work. `dpu1` boots to the home
screen; its dump runs before the USB log is up, so it is not in the live
log (the 128 KiB kernel buffer has wrapped by the time SSH works). `dpu2`:
`pool slot 1 at 0x9cc48000`, then `pipe vig0 now fetches 0x9cc48000` and
`0x9c000000` alternately, display off/on restores and resumes, and the
picture and touch are correct. The splash pipe is VIG0. backboardd idles at
0% CPU, but it still takes 300-600% while the UI moves: that is the
CoreAnimation software renderer, which only the GPU removes.

If the screen goes wrong, reboot (hold Power + Volume down). Nothing is
persistent: the pipe is reprogrammed on every boot by ABL.

## GPU (Adreno 618): plan

Research (2026-10-19): there is no Apple-GPU-free iOS GPU stack anywhere.
iOS 16 composites through Metal, and Metal.framework loads the userspace
driver plugin named by the GPU's kernel service (`AGXMetalA11.bundle` on the
iPhone X). The IPSW has no paravirtualized one. A path, in steps:
1. An XNU kernel driver for the Adreno 618 (GMU, SQE `a630_sqe.fw`,
   `a618_gmu`/`a630_gmu.bin`, zap shader from the MIUI ROM, IOMMU, rings),
   modelled on Linux msm a6xx. It could expose a KGSL-like interface.
2. Mesa Turnip (Vulkan 1.3 conformant on A618; it has a KGSL backend and a
   no-drm build MR) ported to Darwin.
3. A Metal plugin on top (Darling's Indium: Metal on Vulkan 1.3, AIR to
   SPIR-V), plus the private interfaces QuartzCore uses. This is the
   hardest part.

### Step 0: state probe (xnu 0084)

`bsd/dev/sweet_gpu.c` (joyeuse only, `sweetgpu=0` skips it) runs after the
USB probe and only reads. It prints the GCC branches in front of the GPU
(`gpu_cfg_ahb` 0x171004, `gpu_memnoc_gfx` 0x17100c, `gpu_snoc_dvm_gfx`
0x171018) and, only when `gpu_cfg_ahb` is running, the GPUCC CX and GX GDSCs
(0x509106c, 0x509100c). It reads neither the GMU nor the core: they need
GPUCC branch clocks that the first real driver step will turn on. Both
`dpu1`/`dpu2` shims carry it; look for the `SWEET GPU:` lines.

Firmware for the later steps comes from the MIUI 14.0.3.0 vendor image
(`/vendor/firmware`): `a630_sqe.fw`, `a618_gmu.bin`, `a615_zap.mdt` and
`.b00`-`.b02` (the zap shader the TrustZone loads; on atoll it is named
a615). Like the touch firmware it stays outside git: extract it to
`../gpufw/` next to the checkout.

### Step 1: CX power (xnu 0085)

SM7125 is SC7180 with other CPU names (Linux `sm7125.dtsi` includes
`sc7180.dtsi`), and SC7180's A618 is well supported upstream, so the
sequences come from Linux `gcc-sc7180.c`, `gpucc-sc7180.c`, `gdsc.c`,
`clk-rcg2.c` and `msm/adreno/a6xx_gmu.c`. UniXNU's `NativeAdreno` is an
A740 (a7xx) driver: its ring, submit, user client and Metal layers are the
reference for later steps, not its hardware init.

`sweetgpu=<stage>` (thread `sweetgpudelay` s after boot, default 20; the
lines also stay in `sysctl kern.sweetgpu`):
1. Read GCC and GPUCC (default). Hardware result from `dpu1`:
   `gpu_cfg_ahb` on, `memnoc_gfx` and `snoc_dvm_gfx` off.
2. Power the CX side: GCC `gpll0`/`gpll0_div` GPU votes (0x152000 bits
   15/16), `memnoc_gfx`, `snoc_dvm_gfx`, `ddrss_gpu_axi`; CX GDSC (GDSCR
   0x509106c, status in gds_hw_ctrl 0x5091540); GPUCC `cxo`, `gmu_clk_src`
   at 200 MHz (GPLL0 div / 1.5), `cx_gmu`, `cx_snoc_dvm`. Then read the GMU
   (CM3 reset/init result, RSCC, AO status).
3. Also read the adreno SMMU at 0x5040000 (CR0, IDRs, stream matches,
   context banks), to see what the GMU (stream 5) and GPU (stream 0) get.

Hardware result of stage 2 (2026-10-20, read with
`/var/jb/usr/sbin/sysctl -n kern.sweetgpu`): the first try enabled the GCC
bus branches before the CX GDSC and `memnoc_gfx` stayed off (0x80004221);
with the GDSC first everything comes up: `cx_gdsc on: gdscr 0xf8288000
gds_hw 0x80001fe0`, `cxo` and `cx_gmu` on, `gmu_rcg cfg 0x602` (200 MHz),
GCC `memnoc_gfx`/`snoc_dvm_gfx`/`ddrss_gpu_axi` on. The GMU answers: CM3 held
in reset (`sysreset 1`, `fw_init 0`), `cm3_cfg 0x52`, `rpmh_state 0xf`,
`sptprac 0xd4`, RSCC idle. iOS keeps running normally.

Test shims: `shim/out/shim-boot-joyeuse-gpu2.img` and `-gpu3.img` (both
with `sweetdpu=2`). Read the result with
`ssh ... sysctl -n kern.sweetgpu`.

Stage 3 on hardware: `smmu cr0 0x00200626 idr0 0x48016605 idr1 0x20008005
idr2 0x00007511 gfsr 0`. The SMMU is enabled with unmatched streams
faulting (USFCFG), 5 stream match groups and 5 stage-1-only context banks
(4 KiB pages, 8 global pages, so bank n sits at 0x5048000 + n * 0x1000), and
all of them are empty: ABL leaves nothing for the GPU, so the driver owns
the whole SMMU.

4. `sweetgpu=4` (xnu 0086, shim `shim-boot-joyeuse-gpu4.img`): GMU firmware
   boot. Context bank 4 for the GMU's stream 5 (AArch64 stage-1 tables in
   kernel memory) maps its uncached memory at 0x60000000 (dummy, debug,
   log, HFI queue table); the a618 RSCC/PDC sequencer values (PDC at
   0xb290000, its sequencer at 0xb490000); the legacy image (ITCM 16 KiB +
   DTCM 16 KiB, raw Cortex-M3 vectors) is written through the ITCM window;
   then CM3 out of reset and `FW_INIT_RESULT` must read `0xbabeface`. The
   firmware is read from the root filesystem,
   `/usr/share/firmware/joyeuse/gpu/` (copied there from `../gpufw/` over
   SSH; `a630_gmu.bin` by default, `sweetgmufw=618` for `a618_gmu.bin`).

Stage 4 on hardware (2026-10-20): **the GMU firmware runs.**
`a630_gmu.bin: 32768 bytes, sp 0x00043f80`, `smmu cb4 at 0xc000: sid 5 ->
ttbr0 0x10483c000, sctlr 0x67`, PDC was disabled before (`enable 0`),
`rpmh init done; rsc off (status0 0x01010006)`, then `gmu fw UP: init result
0xbabeface`. No SMMU fault (`gfsr 0`, CB4 `fsr 0x400` is only its
long-descriptor FORMAT field). iOS keeps running.

5. `sweetgpu=5` (xnu 0087, shim `shim-boot-joyeuse-gpu5.img`): GX power
   and HFI v1. Hardware result (2026-10-20): **GX is up and the GPU core
   answers.** cmd-db `gfx.lvl`/`cx.lvl`/`mx.lvl` have 16 levels each
   (0, 16, 64, 128, ...); boot vote `0x01800307` (800 MHz); BOOT_SLUMBER
   OOB acked, `sptprac on (0x28)`, `gx_gdscr 0xf8222000` (on); HFI queues
   up, GMU firmware version `0x10070000`, perf table (8 GPU levels), a618
   bw table and test accepted; GPU_SET OOB acked; core `rbbm_status
   0x00000001`, no CP fault.

6. `sweetgpu=6` (xnu 0088, shim `shim-boot-joyeuse-gpu6.img`): the GPU's
   SMMU context (bank 0 for stream 0, the DT's `gfx3d_user`), the a618 part
   of hw_init, `a630_sqe.fw` (version 0x19a), a 32 KiB ring, CP start and
   CP_ME_INIT, then the zap shader through the SCM PAS calls (pas id 13,
   `pil_gpu_mem` 0x93b15000) and a CP_MEM_WRITE test. First hardware run
   (2026-10-20): **the CP runs**: `cp me_init: idle (rptr 9 wptr 9)`, no
   fault. `pas_is_supported(13)` answered 0, and the fallback write to
   `RBBM_SECVID_TRUST_CNTL` stalled the probe thread for good (iOS kept
   running). The second build tries the PAS calls anyway and never touches
   that register (`sweetgpuzap=0` skips the zap).
   Second run (2026-10-20): **the GPU executes commands.** TrustZone takes
   the zap even though `pas_is_supported` says 0: `pas_init_image` (6860
   bytes of metadata), `pas_mem_setup(0x93b15000, 0x1000)` and
   `pas_auth_and_reset` all return 0; `CP_SET_SECURE_MODE 0` drains;
   `CP_MEM_WRITE` drains and the CPU reads `0xcafe0618` back from memory
   written by the GPU through SMMU bank 0; no SMMU fault, no CP fault.

7. `sweetgpu=7` (xnu 0089, shim `shim-boot-joyeuse-gpu7.img`): peripheral
   interrupts. `bsd/dev/sweet_irq.c` programs SPIs in the GIC distributor
   (Group 1 NS, priority 0xa0, level/edge, routed to the boot CPU) and
   `sleh_irq` hands INTIDs >= 32 to its handler table (until now no
   peripheral interrupt reached any driver). With two security states
   `GICD_IGROUPR` is RAZ/WI for non-secure accesses, so it reads 0 and must
   not be checked. Hardware result (2026-10-20): `INTID 332 (level) -> CPU
   0x0, 960 lines`, then `irq: RECEIVED after 1 interrupt(s), status
   0x00100000` (CP_CACHE_FLUSH_TS) with the fence (1560) in memory.

8. User client (xnu 0090, shim `shim-boot-joyeuse-gpu8.img`, still
   `sweetgpu=7`): after stage 7 the GPU stays up and
   `iokit/Kernel/arm/SweetAdreno.cpp` publishes `NativeAdrenoGpuPublished`,
   which speaks UniXNU's NativeAdreno ABI v1 (`NativeAdrenoABI.h`, MIT,
   unchanged) in its direct form: `IOServiceOpen` type 0, selector = ABI
   method. Buffers are IOBufferMemoryDescriptors below 2^36 mapped at the
   client's chosen GPU address (0x40000000-0x100000000 in SMMU bank 0),
   CPU maps are write-combined, submissions are indirect buffers with a
   CACHE_FLUSH_TS IRQ fence (8 in flight), the a618 UBWC registers are
   programmed. `tools/sweet-gputest` (built without an iOS SDK, installed
   as `/var/jb/usr/bin/sweet-gputest`) checks the whole path from a user
   process: one CP_MEM_WRITE through an IB, then a burst of jobs.

   Hardware (2026-10-20): **a user process drives the GPU.**
   `sweet-gputest`: buffers at GPU 0x40000000/0x40100000, mapped into the
   process, an IB with CP_MEM_WRITE submitted through the user client:
   `GPU wrote 0x600df00d ... OK`; a burst of 50 jobs (IRQ fence each) in
   2.1 ms with no busy retry and no fault. Two earlier runs froze the phone
   (no panic on screen): the step trace (`sweetgpudebug=1`, `sweet-gputest
   N notime slow`) showed the last step was IOConnectMapMemory64 of a
   buffer made of kernel RAM, write-combined; changing a managed page's
   cache mode rewrites its physical-aperture PTE and hangs this port. The
   buffers now come from DDR the kernel does not manage (0xb0000000 -
   0xfd000000 with the `--highmem` ADT), mapped write-combined everywhere.
   Open: `CP_ALWAYS_ON_COUNTER` does not count (GetTimestamp is constant).

## Turnip (Vulkan) on the Adreno

**Vulkan runs on the GPU under iOS** (2026-10-20): Mesa's Turnip with
UniXNU's darwin kernel backend, built for iOS 16, finds
`NativeAdrenoGpuPublished`, reports `Turnip Adreno (TM) 618, Vulkan
1.3.354` (vendor 0x5143, device 0x6010800, one 2022 MiB heap), creates a
device, and a `vkCmdFillBuffer` of 1 MiB executed by the GPU reads back
right (`tools/sweet-vkinfo`).

Build (outside git, next to this checkout):
- `../sdk/theos-sdks/iPhoneOS16.5.sdk`: sparse clone of github.com/theos/sdks
  (commit 0222fd5) - there is no Xcode on this Mac.
- `../mesa/src`: Mesa at 85fda3b3 (tree b72ff1eb, UniXNU's pin) plus
  UniXNU's five `patches/mesa` patches (UniXNU dec4c7b) plus
  `tools/mesa-patches/0001-tu-has-host-import.patch` (their backend uses a
  `tu_physical_device` field their patch does not declare).
- `../mesa/venv`: meson, mako, pyyaml, packaging; Homebrew bison 3.8,
  glslang, ninja.
- `tools/build-turnip-ios.sh` configures (cross file for arm64-apple-ios16.0
  with the Theos SDK, UniXNU's option set, `-Dtu-darwin-abi-dir` = the
  kernel's `NativeAdrenoABI.h`) and builds
  `../mesa/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib` (17 MB).
- On the phone: `/var/jb/usr/lib/libvulkan_freedreno.dylib` (ad-hoc signed)
  and `/var/jb/usr/bin/sweet-vkinfo`, which loads it as an ICD without a
  loader (`vk_icdGetInstanceProcAddr`) and sets
  `TU_DARWIN_SERVICE=NativeAdrenoGpuPublished`.

`tools/sweet-vktest` (2026-10-20, on the phone): a 64-wide compute
shader over 1M uints (`out[i] = i*i + 7`) is right in every word (62.8 ms,
ir3 compiles the pipeline in 18 ms on the phone), and a render pass draws a
red/green/blue triangle on a gray clear into a 256x256 RGBA8 image in
2.9 ms; the pixels at the clear corner and near each vertex check out and
the PPM it writes shows the interpolated triangle.

Robustness (xnu 0092, shim `shim-boot-joyeuse-gpu9.img`, 2026-10-20 on the
phone): a watchdog thread recovers the GPU after an error interrupt or 3 s
without progress on a pending job (halt SQE, drain GBIF, RBBM soft reset,
hw_init, CP start, secure-mode exit; the GMU stays up). `sweet-gputest 200
hang` submits a CP_WAIT_MEM_GTE that never ends: `recover (no progress for
3 s) ... recover #1: GBIF drained, GPU running again`, the wait returns
after 3.3 s, the fault count goes 0 -> 1 and the next job runs. GetTimestamp
now reads the GMU always-on counter (CP_ALWAYS_ON_COUNTER stays constant:
231702 -> 231702 over 1 ms, GMU 853476 -> 876366).
Reboot into Fastboot (xnu 0091, `sync; sysctl -w
kern.sweet_reboot_bootloader=1`), tried on hardware: (1) IMEM reason + PSCI
SYSTEM_RESET rebooted into the normal boot (Redmi logo): ABL reads the
reason from the PMIC. (2) PON SOFT_RB_SPARE + warm PS_HOLD reset froze the
phone: on a v5 arbiter an APID's write channel is chnls + 0x10000 * apid,
not 0x80 * apid like the observer. (3) With the right channel every write
went through (PON = APID 154: `0x88f 0x00 -> 0x02`, `0x85a 0x07 -> 0x01`,
enable bit back on) and the phone rebooted into **MIUI Recovery**: the
reason is read, but 1 is recovery; pm6150.dtsi has mode-bootloader 2,
mode-recovery 1. (4) **Works** (2026-10-20): `0x88f 0x00 -> 0x04`, and the
phone is in Fastboot a few seconds later; test kernels are now booted
without touching the phone.
Per-connection GPU address windows (xnu 0093): one 512 MiB window per
user-client connection (six), so two Vulkan processes do not collide.
GPU frequency scaling (xnu 0094, opt-in `sweetgpudcvs=1`): the A618 of
sc7180/atoll has no hardware clock gating in Linux, so the GPU sits at the
800 MHz boot vote. The legacy DCVS OOB is acked, but on hardware the first
change leaves the core without its state (CP_RB_BASE 0, rptr 0) and the
CP does not restart, even with GPU_SET and BOOT_SLUMBER cleared first as
Linux does; so it is off by default. Every core access now checks
CP_RB_BASE and restarts a core that lost its state.
DCVS experiment (xnu 0095, `sweetgpudcvstest=1`, 2026-10-20): stepping
800 -> 650 -> 355 -> 180 MHz kept the core running each time (CP_MEM_WRITE
ok after every step); 180 -> 800 MHz lost the core state (SPTPRAC 0x28 ->
0xa8) and the CP did not restart. So the runtime now sets one lower level at
start and never raises it: `sweetgpulevel=N` (gpu_khz index 1..6), default
6 = 650 MHz. Shim `shim-boot-joyeuse-gpu11.img` (0091-0095): verified,
`dcvs: 800000 -> 650000 kHz`, sweet-gputest passes.
Shim `shim-boot-joyeuse-gpu10.img` (0091-0094, default options), verified
2026-10-20: sweet-gputest passes twice in a row (each connection gets its
own 512 MiB window) and the reboot into Fastboot works.

Next steps: Turnip's own GPU timestamps (CP counter); hwcg and CP
protect from hw_init; the GMU interrupts; per-process address spaces.

## Internet over USB

The phone reaches the internet through the Mac (2026-10-20: ping, DNS and
`apt-get update` work):
1. Mac: `sudo tools/sweet-nat-macos.sh` (IP forwarding plus a pf NAT rule
   in `com.apple/sweet-nat`; lasts until the Mac reboots, `off` undoes it).
2. Phone: `ue0` is created by the kernel outside IOKit, so configd never
   makes a service for it (`addNetworkInterface` only looks at
   IONetworkInterface). `tools/sweet-netconfig` publishes
   `State:/Network/Service/sweet-usb/{IPv4,DNS}` (router 192.168.7.1, DNS
   1.1.1.1 and 8.8.8.8); IPMonitor then installs the default route and
   mDNSResponder gets the servers. The launchd job `es.sweet.netconfig`
   runs it at boot and every 60 s (`sweet-jb-install.py --netconfig BIN`;
   on the live phone it was added to the launchd cache by hand, with the
   original kept in `/var/jb/var/sweet/launchd.plist.orig`; checked across
a reboot).
`route`, `ifconfig` and `netstat` come from Procursus `network-cmds`.

## Metal: what iOS needs (notes, 2026-10-20)

Plan and state of making iOS itself use the GPU.
- Discovery: Metal.framework looks up the IOKit service `IOAcceleratorES`,
  reads its `MetalPluginName` property, loads that bundle and calls its
  principal class' `initWithAcceleratorPort:`. backboardd already asks for
  `IOAcceleratorES` all the time on this port (`IOK backboardd: matching
  ... IOAcceleratorES -> 0 found`), so publishing one is the entry point.
- Sandbox: the processes that use Metal (SpringBoard, backboardd, apps) may
  only `IOServiceOpen` a user client of class `AGXDeviceUserClient`, and
  the profile filters external-method selectors. UniXNU names its
  connection class so and tunnels every ABI method through one admitted
  selector (Turnip backend: `TU_DARWIN_SERVICE` / open type 0x4147). Our
  "SWEET Sandbox" MAC policy (0050) is permissive, so this may matter less
  here; to be checked.
- UniXNU's plugin stage 1 (`NativeAdrenoMetalPlugin.mm`) only runs a GPU
  test from inside SpringBoard and returns nil, so the CPU renderer keeps
  working; their Metal frontend (Metal on Turnip, AIR to NIR) is written
  but unproven on hardware.
- Plan: (1) an opt-in `IOAcceleratorES` service with `MetalPluginName`
  pointing at a test bundle that logs and returns nil, to see who loads it
  and under which sandbox; (2) Turnip from inside SpringBoard; (3) only then
  a real MTLDevice.

Stage 1 works (xnu 0096, `sweetmetal=1`, 2026-10-20). The kernel publishes
a built-in `IOAcceleratorES` (no closed IOGPUFamily here, so the class name
is free) with `MetalPluginName` = `MetalPluginClassName` = `SweetMetalProbe`
(`sweetmetalplugin=<name>` to change it); it prints `SWEET MTL:` lines for
property reads and opens of user processes and refuses `IOServiceOpen`.
`tools/sweet-metalprobe` builds the bundle (a `_MTLDevice` subclass whose
`initWithAcceleratorPort:` appends to `/var/tmp/sweetmetal.log` and returns
nil) and `sweet-mtlquery` (prints what `MTLCreateSystemDefaultDevice`
returns). Installed as `/System/Library/Extensions/SweetMetalProbe.bundle`
(ad-hoc signed), shim `shim-boot-joyeuse-metal1.img` (= gpu11 + 0096 +
`sweetmetal=1`):
- backboardd[58] and SpringBoard[26], both uid 501, load the bundle and call
  `initWithAcceleratorPort:` (a real port) on their own; the library
  validation of this port accepts our ad-hoc bundle in those processes.
- A root process (`sweet-mtlquery`) goes the same way: `reads
  MetalPluginName`, `reads MetalPluginClassName`, load, init, nil.
- With nil, both keep the CPU renderer: same PIDs after 80 s, no crash loop.
- None of them called `IOServiceOpen` on the accelerator before the plugin:
  the open is the plugin's job (`_MTLDevice`'s IOGPU path does it in the
  original plugins).

Stage 2 works (same kernel and shim, 2026-10-20). On its first
`initWithAcceleratorPort:` in SpringBoard (or `sweet-mtlquery`) the plugin
starts a thread that loads Turnip (`/var/jb/usr/lib/libvulkan_freedreno.dylib`),
opens our GPU user client, runs sweet-vktest's compute shader over 64K
uints, checks every word, destroys device and instance, logs one line and
still returns nil (`tools/sweet-metalprobe/turnip-job.c`):
- `sweet-mtlquery[282] uid 0: turnip OK: Turnip Adreno (TM) 618: compute
  65536 words OK (0 bad), device 151.6 ms, ir3 19.5 ms, run 0.74 ms`
- after a respring (`killall SpringBoard`, so it loads the new bundle):
  `SpringBoard[293] uid 501: turnip OK: ... 65536 words OK (0 bad), device
  33.4 ms, ir3 3.3 ms, run 0.29 ms`; SpringBoard and backboardd kept their
  PIDs for the next minute, the GPU watchdog saw no hang.
So a mobile-user UI process reaches the GPU through Metal's own discovery,
with no sandbox or library-validation obstacle on this port.

Stage 3, first part, works (same kernel and shim, 2026-10-20): a real
`MTLDevice` over Turnip for client processes. UniXNU's frontend sits on a
Rust runtime this Mac cannot build for iOS, so `tools/sweet-metalprobe`
has its own small one: `sweet-mtl-vk.c` (one Vulkan device per process,
buffers in host-visible coherent memory, one-shot command lists with
fill/copy and full barriers, 5 s fence timeout) and `SweetMetalDevice.m`
(the plugin's `_MTLDevice` subclass plus buffer, queue, command-buffer and
blit-encoder classes, shaped like UniXNU's NativeBridgeMetalFrontend.mm).
The clients are the names in `/var/jb/etc/sweetmetal.clients`, else only
`sweet-mtltest`; backboardd never gets a device, everyone else still gets
nil. What Metal requires, read from the iOS 16.7 shared cache
(`ipsw dyld disass`, cryptex image `087-86593-047.dmg`): `MTLAddDevice`
asserts `conformsToProtocol:` `MTLDevice` and the private `MTLDeviceSPI`
(added at runtime with `class_addProtocol`), then `-[_MTLDevice initLimits]`
sizes its limit tables from `featureProfile` and
`indirectArgumentBufferCapabilities`, which only the AGX plugins implement
(A11: 5 and 1, used here); `MTLDeviceFeatureQueries` is empty in release
builds. `_MTLDevice` is 528 bytes on iOS 16.7.
`sweet-mtltest` (root and mobile): `device: Turnip Adreno (TM) 618
(SweetMetal), registryID 0x100000128, unified 1`; two 16 MiB buffers, an
unaligned fill (head and tail through staging copies) plus a copy, and a
second command buffer that reads the first one's result: status 4/4,
completed handlers once each, 0 wrong bytes, ~10 ms; `newLibraryWithSource:`
returns nil with an error. SpringBoard and backboardd kept their PIDs.

Shaders, compute (2026-10-20): Metal kernels run on the Adreno 618.
- AIR -> SPIR-V is Darling's Iridium (github.com/darlinghq/indium,
  `src/iridium`, 0BSD), cloned next to this repo as `indium/` (8423a7d) with
  `tools/iridium-patches/0001-integer-binops.patch` (integer add..xor, which
  Iridium lacked, and its wrong SDiv opcode). Turnip then lowers the SPIR-V
  to NIR and ir3 (`spirv_to_nir`).
- Iridium needs typed pointers (`LLVMGetElementType` on pointer types; AIR
  has them, LLVM 17+ drops them), so it runs on LLVM 14.0.6:
  `tools/build-llvm-ios.sh` cross-builds Core/BitReader/Support for iOS
  (host tblgen: Homebrew `llvm@14`); `iridium-static-llvm.cpp` replaces its
  dlopen of libLLVM. UniXNU's AirNir was not used: vertex/fragment only.
- Iridium's ABI: set 0 binding 0 is a uniform buffer of 64-bit buffer
  device addresses (one per buffer argument), threadgroup size from spec
  constants 0..2 (`LocalSizeId`). So the device is Vulkan 1.3 with
  bufferDeviceAddress, shaderInt64 and maintenance4; every MTLBuffer has a
  GPU address; a dispatch writes its argument addresses into a small UBO
  and uses a pipeline specialized per threadgroup size.
- Metal side: `newLibraryWithData/File/URL`, `newDefaultLibrary`,
  `newFunctionWithName:`, `newComputePipelineStateWithFunction:`, compute
  encoder (`setBuffer`, `setBytes`, `dispatchThreadgroups`, and
  `dispatchThreads` for whole threadgroups only: Iridium has no
  out-of-grid check).
- `sweet-mtltest` with `sweet-mtltest.metallib` (`sweet-mtltest.metal`,
  built by build.sh with the metal compiler of this Mac's MetalToolchain
  asset): library translated on the phone in 4-27 ms, `add_arrays` (float)
  and `square_add` (integers + setBytes) over 1M elements: 0 wrong, both
  dispatches 2.6-3.3 ms, as root and as mobile. `sweet-air2spv` runs
  Iridium alone on the phone.

Rendering (2026-10-20): Metal draws on the Adreno 618.
- Runtime: 2D textures (optimal tiling, kept in `VK_IMAGE_LAYOUT_GENERAL`,
  CPU access through a staging buffer), dynamic rendering (Vulkan 1.3),
  graphics pipelines from the library's one SPIR-V module (vertex +
  fragment entry points), three per pipeline for the point/line/triangle
  topology classes; viewport, scissor, topology, cull mode and front face
  are dynamic. Iridium's argument tables: set 0 vertex, set 1 fragment.
  Metal's clip-space y points up: negative-height viewport (as Indium).
  Full memory barriers around every pass and copy (correct, not fast).
- Metal: `newTextureWithDescriptor:` (2D, 1 level, common color formats),
  `getBytes`/`replaceRegion`, `newRenderPipelineStateWithDescriptor:`
  (color formats, blending, write masks), `renderCommandEncoderWithDescriptor:`
  (color attachments, load/store/clear), `set{Vertex,Fragment}{Buffer,Bytes}`,
  `setViewport`, `setCullMode`, `setFrontFacingWinding`, `drawPrimitives`.
- `sweet-mtltest`: a 256x256 BGRA8 render: cleared gray, an RGB triangle and
  a half-transparent white triangle blended over the corner; pass 0.38 ms;
  pixels checked (orientation, colors, blending) as root and as mobile;
  image in `/var/tmp/sweet-mtltest.ppm`.

Textures and samplers in shaders (2026-10-20): `newSamplerStateWithDescriptor:`,
`set{Vertex,Fragment}Texture`, `set{Vertex,Fragment}SamplerState`, compute
`setTexture`/`setSamplerState`, and constexpr samplers inside shaders.
Iridium gives each stage its own set: binding 0 is the buffer-address UBO
only when the function takes buffers, sampled images and samplers follow at
Iridium's `internalIndex`; each kernel/pipeline now builds its layouts from
the function's bindings. Iridium samples only (no storage images yet).
Test: a PNG decoded with ImageIO, uploaded with `replaceRegion`, drawn with
a linear sampler and blended by its alpha, plus a 60 % copy with a constexpr
sampler: 2852 of 2852 flat sample points match the image over the
background (image `/var/tmp/sweet-mtltest-texture.ppm`).
Libraries now translate function by function (each metallib function has
its own AIR module): a function Iridium cannot handle no longer takes the
library with it (`newFunctionWithName:` returns nil for it, logged).

IOSurface textures and drawables (2026-10-20):
- `newTextureWithDescriptor:iosurface:plane:` imports the surface's own
  pages (as mapped in the process) with VK_EXT_external_memory_host (the
  kernel's BoImport pins them, Turnip maps them into the GPU) as a linear
  image with the surface's row pitch (VK_EXT_image_drm_format_modifier,
  DRM_FORMAT_MOD_LINEAR, explicit layout). Turnip needs the pitch to be a
  multiple of 64 bytes: SweetSurface already pads rows to 64
  (`SWEET_SURFACE_ROW_ALIGN`) and publishes that alignment, so no kernel
  change was needed. Single-plane, page-aligned surfaces only for now.
- Coherency: the Adreno does not snoop the CPU caches, and iOS's
  `sys_dcache_flush()` is only `dsb ish` on arm64 (Apple GPUs are
  coherent): with it, 13-16 of 30 CPU->GPU->CPU rounds had stale 64-byte
  lines both ways. The device now cleans and invalidates each IOSurface a
  command buffer uses with `dc civac` from EL0 (XNU sets SCTLR_EL1.UCI)
  before and after the GPU runs, and every command list starts with a
  host-write barrier and ends with a host-read one: 0 of 30 rounds wrong
  (300x200 surfaces, 0.44 ms per round).
- `presentDrawable:` (and `atTime:`, `afterMinimumDuration:`) presents the
  drawable from a completed handler. `CAMetalLayer nextDrawable` works
  with this device: QuartzCore makes the drawable's IOSurface texture
  through it; a GPU clear of it is presented and reads back right.

QuartzCore's compositor on the device (`tools/sweet-metalprobe/sweet-carender`,
CARenderer rendererWithMTLTexture:, 2026-10-20), what it needed so far:
- `newPipelineLibraryWithFilePath:error:` answered with nil (the base
  _MTLDevice loader crashed on default.pipelinelib, AGX binaries); CA then
  builds its pipelines from default.metallib functions.
- `supportsFamily:` Apple1-4 / Common1-2 and `supportsFeatureSet:` iOS
  GPU families 1-4 (the A11's): with no family, CA asks for shader
  variants iOS does not ship (fixed_frag_lpf_cpf); now it asks for the
  half-precision ones (fixed_frag_lph_cpf).
- `newFunctionWithDescriptor:error:`, depth/stencil state objects,
  command-queue/command-buffer SPI properties; unimplemented protocol
  selectors now answer nil/0 and are logged ("stubbed") instead of
  throwing; `touch /var/tmp/sweetmetal.trace` traces every Metal call.
- A CLI must `[CATransaction flush]` before rendering (no run loop).
- Where it stops now: CA's uber-shader `fixed_frag_lph_cpf` (13k lines,
  306 branches, 357 phis, 36 switches) is not translated. It is specialized
  by ~40 function constants (`air.function_constants`: externally
  initialized globals in section air.fc_initializer, e.g. fc_generic id 0,
  fc_vertex_layout id 3; arguments that exist only under a constant). Next:
  apply MTLFunctionConstantValues to those globals and run LLVM's
  sroa/mem2reg/instcombine/sccp/simplifycfg/adce/lowerswitch before
  Iridium (allocas and switches go away; branches remain), then structured
  control flow in Iridium for what is left.

QuartzCore (what backboardd would need), from the iOS 16.7 images:
- `QuartzCore.framework/default.metallib` (1 MB) is AIR: 141 functions
  (39 vertex, 95 fragment, 7 kernels: blurs, downsampling, shading, paths,
  display overdrive...) plus `default.pipelinelib` (an AGX binary archive).
  `CA::OGL::MetalContext::load_pipeline_state` calls
  `newRenderPipelineStateWithName:` on that pipeline library, and
  `compile_shader` builds specialized vertex/fragment shaders from encoded
  "Spec" names; no MSL source compile was seen in those paths.
- Iridium as released translated 32 of the 141 to valid SPIR-V.
  `tools/iridium-patches/0002-quartzcore-coverage.patch` (on top of 0001)
  brings it to 97 translated, 93 valid for Vulkan 1.3 (`spirv-val`): every
  fcmp/icmp predicate (scalar and vector), select, sext/trunc/fpext,
  float<->int conversions, fneg, freeze, ptrtoint/inttoptr, i1 as real bool
  (logical and/or/xor, bool constants, zext/sitofp of bools), a generic
  air.* library table (floor..atan2, fma, mix, step, clamp, saturate, dot,
  length, min/max/clamp/abs for ints, air.convert.*), 3D/1D/array/MS/depth
  texture classes, Flat on integer fragment inputs, same-width int casts as
  bitcasts, 16-bit builtins, and the builtins instance_id,
  thread_position_in_threadgroup, threadgroup_position_in_grid,
  threads_per_threadgroup, thread_index_in_threadgroup,
  threadgroups_per_grid, thread_index_in_quadgroup, front_facing,
  point_coord. Measured with a host build of the same glue
  (`sweet-air2spv`) and `spirv-val --target-env vulkan1.3`; on the phone
  the plugin's own build translates the same 97 (2026-10-20), and
  sweet-mtltest still passes. Turnip has not compiled these yet (that
  happens at pipeline creation, once QuartzCore asks for them).
  `0003-inline-framebuffer-read.patch`: Iridium now runs LLVM's
  always-inliner on each module (internal helper functions marked
  alwaysinline; needs LLVMipo, also cross-built), reads `[[color(n)]]`
  arguments as input attachments (SubpassData, InputAttachmentIndex n, read
  with OpImageRead at (0,0)), and handles air.all/any: 123 of 141
  translated, 119 valid. The runtime side of framebuffer reads:
  VK_KHR_dynamic_rendering_local_read (the pass's color attachments are the
  input attachments, images keep the GENERAL layout and get the
  input-attachment usage) and VK_EXT_rasterization_order_attachment_access
  on pipelines that read, plus a by-region barrier before each of their
  draws. Verified on the phone (sweet-mtltest, root and mobile): a fragment
  that writes 1 - [[color(0)]], drawn twice with overlap: inverted where one
  draw covers, the clear color again where both do. Still missing (18): imageblocks (4, tile shading), texture
  read/write/size queries (5), globals (2), and control flow Iridium does
  not structure (switch, loops/forward references, alloca: ~7; 4 more
  translate but fail "Selection must be structured").
Path to GPU compositing: extend Iridium (intrinsics, half/i16, an LLVM
inlining pass before translation), `newRenderPipelineStateWithName:`
(pipeline library names -> our pipelines), IOSurface textures (surface
memory the GPU can map: the kernel's SweetSurface buffers), drawables, then
backboardd as a client with the CPU renderer as fallback.
Not yet: `newLibraryWithSource`, storage textures, vertex descriptors
(stage_in attributes), depth/stencil, scissor, blend color, indexed draws,
events, partial threadgroups.
