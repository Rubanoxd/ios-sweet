/*
 * sweet-iridium.h over Iridium::translate. Every function entry of the
 * metallib is repacked into a one-function metallib (header, that entry,
 * its bitcode) and translated alone. Iridium parses with LLVM's global
 * context and reports most refusals as C++ exceptions: one mutex
 * serializes translations, and every exception becomes the function's
 * error string.
 */
#include "sweet-iridium.h"
#include <iridium/iridium.hpp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>
#include <vector>

static std::mutex sLock;

static uint64_t
le64(const uint8_t *p)
{
	uint64_t v;
	memcpy(&v, p, 8);
	return v;
}

static uint32_t
le32(const uint8_t *p)
{
	uint32_t v;
	memcpy(&v, p, 4);
	return v;
}

/* One function entry: its name, where its tags say its bitcode is, and the
 * entry bytes with the bitcode offset patched to SINGLE_BC (0). */
static bool
parse_entry(const uint8_t *e, size_t size, std::string &name, uint64_t &bc_off, uint64_t &bc_size,
    std::vector<uint8_t> &patched)
{
	patched.assign(e, e + size);
	size_t q = 4;
	while (q + 4 <= size) {
		if (!memcmp(e + q, "ENDT", 4)) {
			return !name.empty();
		}
		if (q + 6 > size) {
			return false;
		}
		uint16_t len;
		memcpy(&len, e + q + 4, 2);
		const uint8_t *v = e + q + 6;
		if (q + 6 + len > size) {
			return false;
		}
		if (!memcmp(e + q, "NAME", 4) && len) {
			name.assign(reinterpret_cast<const char *>(v), strnlen(reinterpret_cast<const char *>(v), len));
		} else if (!memcmp(e + q, "MDSZ", 4) && len >= 8) {
			bc_size = le64(v);
		} else if (!memcmp(e + q, "OFFT", 4) && len >= 24) {
			bc_off = le64(v + 16);
			memset(&patched[q + 6 + 16], 0, 8);
		}
		q += 6 + len;
	}
	return false;
}

static void
translate_one(const uint8_t *lib, size_t length, const uint8_t *entry, uint32_t entry_size,
    sweet_air_function &f)
{
	std::string name;
	uint64_t bc_off = 0, bc_size = 0;
	std::vector<uint8_t> patched;
	const uint64_t bc_base = le64(lib + 0x48);
	if (!parse_entry(entry, entry_size, name, bc_off, bc_size, patched) || bc_base + bc_off + bc_size > length) {
		snprintf(f.error, sizeof(f.error), "malformed function entry");
		return;
	}
	snprintf(f.name, sizeof(f.name), "%s", name.c_str());
	/* header (0x58 bytes), function list at 0x58 (count + entry), bitcode after it */
	std::vector<uint8_t> one(0x58);
	memcpy(one.data(), lib, 0x58);
	const uint64_t list = 0x58, list_size = 4 + entry_size, bc = list + list_size;
	uint32_t n = 1;
	one.resize(bc);
	memcpy(&one[list], &n, 4);
	memcpy(&one[list + 4], patched.data(), entry_size);
	one.insert(one.end(), lib + bc_base + bc_off, lib + bc_base + bc_off + bc_size);
	uint64_t total = one.size();
	memcpy(&one[0x10], &total, 8);
	memcpy(&one[0x18], &list, 8);
	memcpy(&one[0x20], &list_size, 8);
	memcpy(&one[0x48], &bc, 8);
	memcpy(&one[0x50], &bc_size, 8);
	try {
		Iridium::OutputInfo info;
		size_t size = 0;
		void *spv = Iridium::translate(one.data(), one.size(), size, info);
		auto it = info.functionInfos.find(name);
		if (!spv || size == 0 || it == info.functionInfos.end()) {
			free(spv);
			snprintf(f.error, sizeof(f.error), "Iridium produced no SPIR-V");
			return;
		}
		auto &fi = it->second;
		f.kind = static_cast<int>(fi.type);
		for (auto &b : fi.bindings) {
			if (f.bindings == SWEET_AIR_MAX_BINDINGS) {
				break;
			}
			auto &o = f.binding[f.bindings];
			o.type = static_cast<int>(b.type);
			o.index = b.index == SIZE_MAX ? UINT32_MAX : static_cast<unsigned>(b.index);
			o.internal = static_cast<unsigned>(b.internalIndex);
			o.sampled = b.textureAccessType == Iridium::TextureAccessType::Sample;
			o.embedded = b.type == Iridium::BindingType::Sampler && b.embeddedSamplerIndex != SIZE_MAX ?
			    static_cast<int>(b.embeddedSamplerIndex) : -1;
			f.bindings++;
		}
		for (auto &e : fi.embeddedSamplers) {
			if (f.samplers == sizeof(f.sampler) / sizeof(f.sampler[0])) {
				break;
			}
			auto &o = f.sampler[f.samplers++];
			o.address[0] = static_cast<uint8_t>(e.widthAddressMode);
			o.address[1] = static_cast<uint8_t>(e.heightAddressMode);
			o.address[2] = static_cast<uint8_t>(e.depthAddressMode);
			o.mag = static_cast<uint8_t>(e.magnificationFilter);
			o.min = static_cast<uint8_t>(e.minificationFilter);
			o.mip = static_cast<uint8_t>(e.mipmapFilter);
			o.normalized = e.usesNormalizedCoordinates;
			o.compare = static_cast<uint8_t>(e.compareFunction);
			o.anisotropy = e.anisotropyLevel;
			o.border = static_cast<uint8_t>(e.borderColor);
			o.lod_min = e.lodMin;
			o.lod_max = e.lodMax;
		}
		f.spirv = spv;
		f.spirv_bytes = size;
	} catch (const std::exception &e) {
		snprintf(f.error, sizeof(f.error), "Iridium: %s", e.what());
	} catch (...) {
		snprintf(f.error, sizeof(f.error), "Iridium: unknown failure");
	}
}

extern "C" struct sweet_air_function *
sweet_air_translate(const void *metallib, size_t length, size_t *count, char *err, size_t errlen)
{
	std::lock_guard<std::mutex> guard(sLock);
	const uint8_t *lib = static_cast<const uint8_t *>(metallib);
	*count = 0;
	if (length < 0x58 || memcmp(lib, "MTLB", 4) != 0) {
		snprintf(err, errlen, "not a metallib");
		return nullptr;
	}
	static bool ready = Iridium::init();
	if (!ready) {
		snprintf(err, errlen, "Iridium did not initialize");
		return nullptr;
	}
	const uint64_t list = le64(lib + 0x18);
	if (list + 4 > length) {
		snprintf(err, errlen, "bad function list");
		return nullptr;
	}
	const uint32_t n = le32(lib + list);
	auto *out = static_cast<sweet_air_function *>(calloc(n ? n : 1, sizeof(sweet_air_function)));
	if (!out) {
		snprintf(err, errlen, "out of memory");
		return nullptr;
	}
	size_t p = list + 4;
	for (uint32_t i = 0; i < n; ++i) {
		if (p + 4 > length || le32(lib + p) < 8 || p + le32(lib + p) > length) {
			snprintf(out[i].error, sizeof(out[i].error), "function list truncated");
			*count = i + 1;
			return out;
		}
		const uint32_t size = le32(lib + p);
		translate_one(lib, length, lib + p, size, out[i]);
		p += size;
	}
	*count = n;
	return out;
}

extern "C" void
sweet_air_free(struct sweet_air_function *functions, size_t count)
{
	for (size_t i = 0; functions && i < count; ++i) {
		free(functions[i].spirv);
	}
	free(functions);
}
