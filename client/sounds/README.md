# These wav files are silent on purpose

Every one of them is 64 samples of nothing. They are not the game's sounds and
replacing them by hand does nothing: `arena/sfx.lua` overwrites all fifteen at
boot with buffers rendered by `ext/simcore/src/sfx.c`, which is where the kit
actually lives.

They exist because a Defold sound component has to point at a sound resource at
build time, and `resource.set_sound` needs a distinct resource per component to
write into. One shared placeholder would leave all fifteen components sharing
one buffer, so there is one file per sound and each keeps the name its
component uses.

The `.sound` files beside them are real and hand maintained. Gain, mixer group
and whether a sound loops live there, not in the synth.

To hear the kit outside the game:

```sh
make -C client/tools sfx && client/tools/sfxdump /tmp/kit
```
