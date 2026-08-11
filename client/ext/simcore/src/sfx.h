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

// --- the soundtrack --------------------------------------------------------
//
// There are several of them and the client rotates through them while the game
// runs, so they are not rendered by name like the rest of the kit. One takes
// about an eighth of a second to build, which is a frozen frame if it happens
// during a fight, so a track is built in steps small enough to hide inside one
// and the next is ready before it is wanted.
//
//     sfx_music_job *j = sfx_music_begin(n);
//     while (!sfx_music_step(j)) { /* a frame goes by */ }
//     unsigned char *wav = sfx_music_take(j, &len);
//
// `take` frees the job whether or not it succeeded, and returns null if it did
// not. `cancel` frees an unfinished one.
typedef struct sfx_music_job sfx_music_job;

int sfx_music_count(void);
// A track's tempo, for anything that needs to check the loop closes.
int sfx_music_bpm(int track);
sfx_music_job *sfx_music_begin(int track);
int sfx_music_step(sfx_music_job *job);
unsigned char *sfx_music_take(sfx_music_job *job, size_t *len);
void sfx_music_cancel(sfx_music_job *job);

#ifdef __cplusplus
}
#endif

#endif
