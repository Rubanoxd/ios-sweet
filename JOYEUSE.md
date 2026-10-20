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
mode-recovery 1. (4) Writes 2 << 1 now; not yet tested.
Per-connection GPU address windows (xnu 0093): one 512 MiB window per
user-client connection (six), so two Vulkan processes do not collide.
GPU frequency scaling (xnu 0094): the A618 of sc7180/atoll has no hardware
clock gating in Linux, so the GPU sat at the 800 MHz boot vote; submissions
now raise the level and the watchdog drops it to 180 MHz after 1 s idle
(legacy DCVS OOB). Shim `shim-boot-joyeuse-gpu10.img` has 0091-0094, untested.

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

Nothing here runs yet; this is the plan for making iOS itself use the GPU.
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
