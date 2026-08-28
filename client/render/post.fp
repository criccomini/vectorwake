#version 140

// The blit: the frame the game drew, copied from the target it was drawn into
// onto the screen.
//
// It exists because a shader cannot read the screen it is writing to. To blur
// what is behind a button the frame has to be a texture first, so the world
// passes draw into one and this puts it back. Opaque: the scene target was
// cleared to the same ground color the screen was, and its alpha carries the
// additive layers' accumulated brightness rather than any coverage worth
// keeping.

in mediump vec2 var_uv;

out vec4 out_fragColor;

uniform mediump sampler2D tex0;

void main()
{
    out_fragColor = vec4(texture(tex0, var_uv).rgb, 1.0);
}
