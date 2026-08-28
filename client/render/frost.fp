#version 140

// What a button lets through: the scene behind it, blurred, at the strength
// the vertex asked for.
//
// Premultiplied out, like everything else this game draws, so the layer
// composites under the same blend the interface uses. At alpha one the box
// holds the blurred scene alone and the panel's own wash goes on top of it.
// Below one, some of the sharp picture comes through with it, which is a pane
// half frosted.

in mediump vec2 var_uv;
in mediump vec4 var_color;

out vec4 out_fragColor;

uniform mediump sampler2D tex0;

void main()
{
    mediump float a = var_color.a;
    out_fragColor = vec4(texture(tex0, var_uv).rgb * var_color.rgb * a, a);
}
