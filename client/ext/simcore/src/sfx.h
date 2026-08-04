// The sound kit, synthesised.
//
// Every sound in vectorwake is ours, per docs/design/identity.md, and the
// cheapest way to guarantee that is to generate it from arithmetic rather
// than record or source it. This is where that arithmetic lives, and it runs
// on the player's machine: the client renders the kit at boot and hands the
// buffers to Defold, so no audio ships in the page.
//
// Nothing here is the simulation. Doubles are fine, results need not be
// reproducible across machines, and no rule of the game may be decided in
// this file.

#ifndef SFX_H
#define SFX_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Every sound the kit knows, in the order the client asks for them, ending in
// a null. The names double as the sound component ids in main.collection.
extern const char *const sfx_names[];

// Renders one sound into the bytes of a 16-bit mono wav file, header and all,
// which is what Defold's resource.set_sound takes. Returns null on a name the
// kit does not know. The caller owns the block and frees it.
unsigned char *sfx_render(const char *name, size_t *len);

// Whether this sound is played end to end forever rather than as an event.
// The client routes the two differently, and which is which is decided here
// so that the kit stays the only place that knows. Zero for a name the kit
// does not hold.
int sfx_is_loop(const char *name);

#ifdef __cplusplus
}
#endif

#endif
