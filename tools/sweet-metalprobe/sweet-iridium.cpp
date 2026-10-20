/*
 * sweet-iridium.h over Iridium::translate. Iridium parses with LLVM's
 * global context and reports most refusals as C++ exceptions: one mutex
 * serializes translations, and every exception becomes an error string.
 */
#include "sweet-iridium.h"
#include <iridium/iridium.hpp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>

static std::mutex sLock;

extern "C" void *
sweet_air_translate(const void *metallib, size_t length, size_t *spv_bytes, struct sweet_air_function **functions,
    size_t *count, char *err, size_t errlen)
{
	std::lock_guard<std::mutex> guard(sLock);
	*functions = nullptr;
	*count = 0;
	if (length < 4 || memcmp(metallib, "MTLB", 4) != 0) {
		snprintf(err, errlen, "not a metallib");
		return nullptr;
	}
	static bool ready = Iridium::init();
	if (!ready) {
		snprintf(err, errlen, "Iridium did not initialize");
		return nullptr;
	}
	try {
		Iridium::OutputInfo info;
		size_t size = 0;
		void *spv = Iridium::translate(metallib, length, size, info);
		if (!spv || size == 0) {
			free(spv);
			snprintf(err, errlen, "Iridium produced no SPIR-V");
			return nullptr;
		}
		auto *out = static_cast<sweet_air_function *>(calloc(info.functionInfos.size() ? info.functionInfos.size() : 1,
		    sizeof(sweet_air_function)));
		size_t n = 0;
		for (auto &[name, fi] : info.functionInfos) {
			sweet_air_function &f = out[n++];
			snprintf(f.name, sizeof(f.name), "%s", name.c_str());
			f.kind = static_cast<int>(fi.type);
			for (auto &b : fi.bindings) {
				if (f.bindings == SWEET_AIR_MAX_BINDINGS) {
					break;
				}
				f.binding[f.bindings].type = static_cast<int>(b.type);
				f.binding[f.bindings].index = static_cast<unsigned>(b.index);
				f.bindings++;
			}
		}
		*spv_bytes = size;
		*functions = out;
		*count = n;
		return spv;
	} catch (const std::exception &e) {
		snprintf(err, errlen, "Iridium: %s", e.what());
	} catch (...) {
		snprintf(err, errlen, "Iridium: unknown failure");
	}
	return nullptr;
}
