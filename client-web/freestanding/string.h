/* Minimal <string.h> for the freestanding WebAssembly build. The sim core
 * uses only these two, and wasm_shim.c defines them. */
#ifndef VW_FREESTANDING_STRING_H
#define VW_FREESTANDING_STRING_H
typedef unsigned long size_t;
void *memcpy(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);
#endif
