/*
 * Replaces Iridium's src/iridium/dynamic-llvm.cpp in the iOS plugin: there
 * is no libLLVM.dylib to dlopen on the phone, LLVM 14 is linked statically
 * (tools/build-llvm-ios.sh). Iridium still calls through its DynamicFunction
 * wrappers; each name resolves to the linked function, and naming every
 * function here also keeps the linker from dropping it.
 */
#include <iridium/dynamic-llvm.hpp>
#include <cstring>

#define DYNAMICLLVM_FUNCTION_DEF(_name) \
	Iridium::DynamicLLVM::DynamicFunction<decltype(_name)> Iridium::DynamicLLVM::_name(#_name);

IRIDIUM_DYNAMICLLVM_FUNCTION_FOREACH(DYNAMICLLVM_FUNCTION_DEF)

bool Iridium::DynamicLLVM::init() {
	return true;
}

void Iridium::DynamicLLVM::finit() {
}

void* Iridium::DynamicLLVM::resolveSymbol(const char* name) {
#define DYNAMICLLVM_FUNCTION_ADDR(_name) \
	if (!strcmp(name, #_name)) { \
		return reinterpret_cast<void*>(&::_name); \
	}
	IRIDIUM_DYNAMICLLVM_FUNCTION_FOREACH(DYNAMICLLVM_FUNCTION_ADDR)
	return nullptr;
}
