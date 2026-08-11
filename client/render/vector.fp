#version 140

// Premultiplied out, which is what lets the render script pick between
// ordinary compositing and additive glow by changing only the destination
// factor: source stays ONE either way, so the same geometry means the same
// thing in both passes.

in mediump vec4 var_color;

out vec4 out_fragColor;

void main()
{
    out_fragColor = vec4(var_color.rgb * var_color.a, var_color.a);
}
