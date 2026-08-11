# These wav files are silent on purpose

Every one of them is 64 samples of nothing. They are not the game's sounds and
replacing them by hand does nothing: `arena/sfx.lua` overwrites them at boot
with buffers rendered by `ext/simcore/src/sfx.c`, which is where the kit actually
lives. All but `music_b`, which stays silent until the first crossfade needs
it.

They exist because a Defold sound component has to point at a sound resource at
build time, and `resource.set_sound` needs a distinct resource per component to
write into. One shared placeholder would leave every component sharing one
buffer, so there is one file per sound and each keeps the name its component
uses.

Twelve of them are the weapon ladders, four rungs each of `gun`, `bomb` and
`blast`. Every buffer is normalized to one peak, so a heavier weapon has to get
its loudness from the gain here.

Those gains are not in ascending order and that is not a mistake to fix. The
eight launch sounds are built differently from each other rather than tuned from
one recipe, and a dense buffer is louder than a sparse one at the same peak, so
the numbers that make the heard climb even are not themselves a ladder. They come
from measuring each sound's loudest 300 ms window and solving for two decibels a
rung. Changing one by ear puts a step back in the ladder that nobody meant.

The `.sound` files beside them are real and hand maintained. Gain, mixer group
and whether a sound loops live there, not in the synth.

To hear the kit outside the game:

```sh
make -C client/tools sfx && client/tools/sfxdump /tmp/kit
```
