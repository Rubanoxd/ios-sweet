// SPDX-License-Identifier: MIT
//! sweet-m2vtest: the metal2vulkan runtime (the Metal API on Vulkan) over our Turnip build.
//! Adapted from UniXNU/NativeMetal bridge/NativeMetalBridge.rs (MIT): a compute kernel, a render
//! pass read back through a blit, a render into host pages imported without a copy (the IOSurface
//! path), and, given a metallib, the translation of its kernels and vertex/fragment pairs.
//!   sweet-m2vtest [loader|""] [metallib]
//! The loader defaults to /var/jb/usr/lib/libvulkan_freedreno.dylib (it exports
//! vkGetInstanceProcAddr; iOS has no Khronos loader).

use metal2vulkan::metal::{PixelFormat, PrimitiveType, TextureUsage};
use metal2vulkan::pipeline::{ColorAttachmentDescriptor, RenderPipelineDescriptor, StageSource};
use metal2vulkan_runtime::{
    BlitOption, ClearColor, CommandBuffer, CommandBufferStatus, Device, DeviceOptions, HostMemory, LoadAction, Library,
    MetalLevel, Origin, PipelineOptions, RenderPassDescriptor, ResourceOptions, ShaderCacheOptions, Size, StoreAction,
    Texture, TextureDescriptor,
};
use std::path::PathBuf;
use std::ptr::NonNull;
use std::time::{Duration, Instant};

/// The runtime's own example library (runtime_examples.metal), assembled by build.sh.
static FIXTURE_AIR: &[u8] = include_bytes!(env!("SWEET_M2V_FIXTURE"));

const LOADER: &str = "/var/jb/usr/lib/libvulkan_freedreno.dylib";
const CACHE: &str = "/var/tmp/sweet-m2v-cache";
const WAIT: Duration = Duration::from_secs(10);

/// Cleans and invalidates the data cache over a range. iOS's sys_dcache_flush is only a barrier on
/// arm64 (Apple GPUs snoop the CPU caches); the Adreno does not, and XNU lets EL0 run `dc civac`.
fn flush(start: *const u8, len: usize) {
    let mut p = start as usize & !63;
    let end = start as usize + len;
    // SAFETY: cache maintenance on a mapped range; it changes no memory contents.
    unsafe {
        std::arch::asm!("dsb sy");
        while p < end {
            std::arch::asm!("dc civac, {0}", in(reg) p);
            p += 64;
        }
        std::arch::asm!("dsb sy");
    }
}

fn finish(command_buffer: &CommandBuffer) -> Result<(), String> {
    command_buffer.commit().map_err(|e| format!("commit: {e:?}"))?;
    command_buffer.wait_until_completed_for(WAIT).map_err(|_| "no completion in 10 s".to_string())?;
    match command_buffer.status() {
        CommandBufferStatus::Completed => Ok(()),
        status => Err(format!("{status:?} {:?}", command_buffer.error())),
    }
}

fn open(loader: &str) -> Result<Device, String> {
    let mut options = DeviceOptions::default();
    options.loader = Some(PathBuf::from(loader));
    // Not a macOS host: answer as the newest measured Metal.
    options.metal_level = Some(MetalLevel::NEWEST);
    options.shader_cache = ShaderCacheOptions::in_directory(CACHE);
    Device::system_default_with(&options).map_err(|e| format!("device: {e:?}"))
}

fn compute(device: &Device, library: &Library) -> Result<u32, String> {
    const COUNT: usize = 1000;
    let function = library.new_function_with_name("scale_and_offset").map_err(|e| format!("{e:?}"))?;
    let state = device
        .new_compute_pipeline_state_with_function(&function, &PipelineOptions::default())
        .map_err(|e| format!("pipeline: {e:?}"))?;
    let input: Vec<u8> = (0..COUNT).flat_map(|i| (i as f32).to_le_bytes()).collect();
    let input = device.new_buffer_with_bytes(&input, ResourceOptions::shared()).map_err(|e| format!("{e:?}"))?;
    let output = device.new_buffer((COUNT * 4) as u64, ResourceOptions::shared()).map_err(|e| format!("{e:?}"))?;
    let scale = device.new_buffer_with_bytes(&2.0f32.to_le_bytes(), ResourceOptions::shared()).map_err(|e| format!("{e:?}"))?;
    let queue = device.new_command_queue().map_err(|e| format!("{e:?}"))?;
    let command_buffer = queue.command_buffer().map_err(|e| format!("{e:?}"))?;
    let mut encoder = command_buffer.compute_command_encoder().map_err(|e| format!("{e:?}"))?;
    encoder.set_compute_pipeline_state(&state).map_err(|e| format!("{e:?}"))?;
    encoder.set_buffer(Some(&input), 0, 0).map_err(|e| format!("{e:?}"))?;
    encoder.set_buffer(Some(&output), 0, 1).map_err(|e| format!("{e:?}"))?;
    encoder.set_buffer(Some(&scale), 0, 2).map_err(|e| format!("{e:?}"))?;
    encoder.dispatch_threads(Size::new(COUNT as u64, 1, 1), Size::new(64, 1, 1)).map_err(|e| format!("{e:?}"))?;
    encoder.end_encoding().map_err(|e| format!("{e:?}"))?;
    finish(&command_buffer)?;
    let contents = output.contents().ok_or("no contents")?;
    // SAFETY: the buffer holds COUNT floats and no command buffer writes it now.
    let values = unsafe { std::slice::from_raw_parts(contents.as_ptr() as *const f32, COUNT) };
    Ok(values.iter().enumerate().filter(|(i, v)| **v != 3.0 * *i as f32).count() as u32)
}

/// Draws the fixture's top-left-quarter quad into `target` (cleared blue), optionally copying it to a buffer.
fn draw_quad(device: &Device, library: &Library, target: &Texture,
             readback: Option<(&metal2vulkan_runtime::Buffer, u64, u64)>) -> Result<(), String> {
    let vertex = library.new_function_with_name("colored_vertex").map_err(|e| format!("{e:?}"))?;
    let fragment = library.new_function_with_name("colored_fragment").map_err(|e| format!("{e:?}"))?;
    let mut descriptor = RenderPipelineDescriptor::new(StageSource::Function(vertex.function_descriptor()));
    descriptor.fragment = Some(StageSource::Function(fragment.function_descriptor()));
    descriptor.color_attachments[0] = Some(ColorAttachmentDescriptor::new(PixelFormat::RGBA8Unorm));
    let state = device.new_render_pipeline_state(&descriptor, &PipelineOptions::default()).map_err(|e| format!("pipeline: {e:?}"))?;
    let positions: [[f32; 2]; 6] = [[-1.0, 1.0], [0.0, 1.0], [-1.0, 0.0], [0.0, 1.0], [0.0, 0.0], [-1.0, 0.0]];
    let positions: Vec<u8> = positions.iter().flatten().flat_map(|v| v.to_le_bytes()).collect();
    let colors: Vec<u8> = (0..6).flat_map(|_| [1.0f32, 0.2, 0.0, 1.0]).flat_map(|v| v.to_le_bytes()).collect();
    let positions = device.new_buffer_with_bytes(&positions, ResourceOptions::shared()).map_err(|e| format!("{e:?}"))?;
    let colors = device.new_buffer_with_bytes(&colors, ResourceOptions::shared()).map_err(|e| format!("{e:?}"))?;
    let mut pass = RenderPassDescriptor::new();
    let color = &mut pass.color_attachments[0];
    color.texture = Some(target.clone());
    color.load_action = LoadAction::Clear;
    color.store_action = StoreAction::Store;
    color.clear_color = ClearColor::new(0.0, 0.0, 1.0, 1.0);
    let queue = device.new_command_queue().map_err(|e| format!("{e:?}"))?;
    let command_buffer = queue.command_buffer().map_err(|e| format!("{e:?}"))?;
    let mut encoder = command_buffer.render_command_encoder(&pass).map_err(|e| format!("{e:?}"))?;
    encoder.set_render_pipeline_state(&state).map_err(|e| format!("{e:?}"))?;
    encoder.set_vertex_buffer(Some(&positions), 0, 0).map_err(|e| format!("{e:?}"))?;
    encoder.set_vertex_buffer(Some(&colors), 0, 1).map_err(|e| format!("{e:?}"))?;
    encoder.draw_primitives(PrimitiveType::Triangle, 0, 6, 1, 0).map_err(|e| format!("{e:?}"))?;
    encoder.end_encoding().map_err(|e| format!("{e:?}"))?;
    if let Some((buffer, row, side)) = readback {
        let mut blit = command_buffer.blit_command_encoder().map_err(|e| format!("{e:?}"))?;
        blit.copy_from_texture_to_buffer(target, 0, 0, Origin::new(0, 0, 0), Size::new(side, side, 1), buffer, 0, row,
                                         row * side, BlitOption::None).map_err(|e| format!("{e:?}"))?;
        blit.end_encoding().map_err(|e| format!("{e:?}"))?;
    }
    finish(&command_buffer)
}

/// Texels off the expected picture: the top-left quarter drawn (255, 51, 0, 255), the rest cleared blue.
fn wrong_texels(bytes: &[u8], row: usize, side: usize) -> u32 {
    let mut bad = 0;
    for y in 0..side {
        for x in 0..side {
            let at = y * row + x * 4;
            let inside = x < side / 2 && y < side / 2;
            let expected: [u8; 4] = if inside { [255, 51, 0, 255] } else { [0, 0, 255, 255] };
            if bytes[at..at + 4] != expected {
                bad += 1;
            }
        }
    }
    bad
}

fn render(device: &Device, library: &Library) -> Result<u32, String> {
    const SIDE: u64 = 8;
    let mut texture = TextureDescriptor::texture_2d(PixelFormat::RGBA8Unorm, SIDE, SIDE, false);
    texture.usage = TextureUsage::RENDER_TARGET;
    texture.resource_options = ResourceOptions::private();
    let target = device.new_texture(&texture).map_err(|e| format!("{e:?}"))?;
    let readback = device.new_buffer(SIDE * 4 * SIDE, ResourceOptions::shared()).map_err(|e| format!("{e:?}"))?;
    draw_quad(device, library, &target, Some((&readback, SIDE * 4, SIDE)))?;
    let contents = readback.contents().ok_or("no contents")?;
    // SAFETY: SIDE rows of SIDE * 4 bytes, no longer written.
    let bytes = unsafe { std::slice::from_raw_parts(contents.as_ptr(), (SIDE * 4 * SIDE) as usize) };
    Ok(wrong_texels(bytes, (SIDE * 4) as usize, SIDE as usize))
}

/// The IOSurface path without an IOSurface: page-aligned host pages imported without a copy, a
/// linear render target over them, CPU caches cleaned before and invalidated after the GPU's use.
fn import(device: &Device, library: &Library) -> Result<u32, String> {
    const SIDE: u64 = 64;
    const ROW: u64 = 256;
    let bytes = (ROW * SIDE) as usize;
    // SAFETY: an anonymous private mapping of whole pages, unmapped below after every GPU use completed.
    let pages = unsafe {
        libc::mmap(std::ptr::null_mut(), bytes, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_PRIVATE | libc::MAP_ANON, -1, 0)
    };
    if pages == libc::MAP_FAILED {
        return Err("mmap".into());
    }
    let result = (|| {
        // SAFETY: the pages were just mapped; nothing else uses them.
        unsafe { std::ptr::write_bytes(pages as *mut u8, 0x5a, bytes) };
        // SAFETY: the mapping is writable, page aligned and outlives the buffer (dropped before the unmap).
        let memory = unsafe { HostMemory::new(NonNull::new(pages as *mut u8).ok_or("null")?) };
        // SAFETY: as above, for `bytes` bytes.
        let buffer = unsafe { device.new_buffer_with_bytes_no_copy(memory, bytes as u64, ResourceOptions::shared(), None) }
            .map_err(|e| format!("no-copy buffer: {e:?}"))?;
        let mut texture = TextureDescriptor::texture_2d(PixelFormat::RGBA8Unorm, SIDE, SIDE, false);
        texture.usage = TextureUsage::RENDER_TARGET | TextureUsage::SHADER_READ;
        texture.resource_options = ResourceOptions::shared();
        let target = buffer.new_texture(&texture, 0, ROW).map_err(|e| format!("texture over pages: {e:?}"))?;
        flush(pages as *const u8, bytes);
        draw_quad(device, library, &target, None)?;
        flush(pages as *const u8, bytes);
        // SAFETY: the pages hold `bytes` bytes and no command buffer writes them now.
        let view = unsafe { std::slice::from_raw_parts(pages as *const u8, bytes) };
        let bad = wrong_texels(view, ROW as usize, SIDE as usize);
        drop(target);
        drop(buffer);
        Ok(bad)
    })();
    // SAFETY: the buffer and texture over the pages are gone.
    unsafe { libc::munmap(pages, bytes) };
    result
}

/// The AIR slice of a universal metallib (a big-endian fat container of an AIR64 metallib and an
/// Apple-GPU binary); a thin metallib is returned as it is.
fn air_slice(bytes: &[u8]) -> Option<&[u8]> {
    const AIR64: u32 = 0x0100_0017;
    let word = |at: usize| bytes.get(at..at + 4).map(|w| u32::from_be_bytes([w[0], w[1], w[2], w[3]]));
    if word(0)? != 0xcafe_babe {
        return Some(bytes);
    }
    let count = word(4)? as usize;
    for i in 0..count.min(16) {
        let at = 8 + 20 * i;
        if word(at)? == AIR64 {
            let (offset, size) = (word(at + 8)? as usize, word(at + 12)? as usize);
            return bytes.get(offset..offset.checked_add(size)?);
        }
    }
    None
}

/// Translates a metallib: every kernel into a compute pipeline, and the vertex/fragment pairs named
/// alike (`<name>_vert_<p>` with `<name>_frag_<p>`) into render pipelines over a BGRA8 attachment.
/// Counts only; refusals are listed with SWEET_M2V_LIST=1.
fn translate(device: &Device, bytes: &[u8]) -> Result<String, String> {
    let bytes = air_slice(bytes).ok_or("no AIR64 slice")?;
    let library = device.new_library_with_data(bytes).map_err(|e| format!("library: {e:?}"))?;
    let names = library.function_names();
    let list = std::env::var_os("SWEET_M2V_LIST").is_some();
    let (mut kernels_ok, mut kernels_failed, mut pairs_ok, mut pairs_failed) = (0, 0, 0, 0);
    let mut vertices = Vec::new();
    let mut fragments = Vec::new();
    for name in &names {
        let Ok(function) = library.new_function_with_name(name) else { continue };
        match function.function_type() {
            Ok(metal2vulkan::metal::FunctionType::Kernel) => {
                match device.new_compute_pipeline_state_with_function(&function, &PipelineOptions::default()) {
                    Ok(_) => kernels_ok += 1,
                    Err(e) => {
                        kernels_failed += 1;
                        if list {
                            eprintln!("kernel {name}: {e:?}");
                        }
                    }
                }
            }
            Ok(metal2vulkan::metal::FunctionType::Vertex) => vertices.push((function, name.clone())),
            Ok(metal2vulkan::metal::FunctionType::Fragment) => fragments.push((function, name.clone())),
            _ => {}
        }
    }
    for (vertex, vname) in &vertices {
        let Some(fname) = [vname.replace("_vert_", "_frag_"), vname.replacen("_vert", "_frag", 1)]
            .into_iter()
            .find(|candidate| fragments.iter().any(|(_, n)| n == candidate))
        else {
            continue;
        };
        let fragment = &fragments.iter().find(|(_, n)| *n == fname).unwrap().0;
        let mut descriptor = RenderPipelineDescriptor::new(StageSource::Function(vertex.function_descriptor()));
        descriptor.fragment = Some(StageSource::Function(fragment.function_descriptor()));
        descriptor.color_attachments[0] = Some(ColorAttachmentDescriptor::new(PixelFormat::BGRA8Unorm));
        match device.new_render_pipeline_state(&descriptor, &PipelineOptions::default()) {
            Ok(_) => pairs_ok += 1,
            Err(e) => {
                pairs_failed += 1;
                if list {
                    eprintln!("pair {vname} {fname}: {e:?}");
                }
            }
        }
    }
    Ok(format!("{} functions; kernels {kernels_ok} ok / {kernels_failed} refused; vertex+fragment pairs {pairs_ok} ok / {pairs_failed} refused",
               names.len()))
}

fn step<T>(name: &str, f: impl FnOnce() -> Result<T, String>) -> Option<T> {
    let t0 = Instant::now();
    let result = f();
    let ms = t0.elapsed().as_secs_f64() * 1e3;
    match result {
        Ok(v) => {
            println!("{name}: ran in {ms:.1} ms");
            Some(v)
        }
        Err(why) => {
            println!("{name}: FAILED after {ms:.1} ms: {why}");
            None
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let loader = args.get(1).map(String::as_str).filter(|s| !s.is_empty()).unwrap_or(LOADER);
    // Turnip's default is the plugin's IOAcceleratorES tunnel; a plain process opens the GPU directly.
    if std::env::var_os("TU_DARWIN_SERVICE").is_none() {
        std::env::set_var("TU_DARWIN_SERVICE", "NativeAdrenoGpuPublished");
    }
    let mut fails = 0;
    let Some(device) = step("device", || open(loader)) else { std::process::exit(1) };
    println!("device: {}", device.name());
    let Some(library) = step("fixture library", || {
        metal2vulkan::library::Library::from_air(FIXTURE_AIR)
            .map(|l| device.new_library_with_compile_library(l))
            .map_err(|e| format!("{e:?}"))
    }) else { std::process::exit(1) };
    for (name, f) in [("compute", compute as fn(&Device, &Library) -> Result<u32, String>), ("render", render), ("import", import)] {
        match step(name, || f(&device, &library)) {
            Some(0) => println!("{name}: OK"),
            Some(bad) => {
                println!("{name}: {bad} wrong values");
                fails += 1;
            }
            None => fails += 1,
        }
    }
    if let Some(path) = args.get(2) {
        match std::fs::read(path) {
            Ok(bytes) => match step("translate", || translate(&device, &bytes)) {
                Some(summary) => println!("{path}: {summary}"),
                None => fails += 1,
            },
            Err(e) => {
                println!("{path}: {e}");
                fails += 1;
            }
        }
    }
    println!("{}", if fails == 0 { "ALL OK: METAL2VULKAN RUNS ON TURNIP" } else { "SOME CHECKS FAILED" });
    std::process::exit(if fails == 0 { 0 } else { 1 });
}
