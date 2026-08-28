#version 140

// Quarter size, in four taps.
//
// Each tap sits half a texel off a corner of the 4x4 block this pixel stands
// for, so the hardware's own bilinear filter averages a 2x2 for us and the
// four of them come to the exact mean of the sixteen. Doing it by point
// sampling instead is what makes a starfield crawl: a star is one bright pixel
// on a dark ground, and a downsample that only reads every fourth pixel either
// keeps it whole or loses it entirely as the camera moves.

in mediump vec2 var_uv;

out vec4 out_fragColor;

uniform mediump sampler2D tex0;
uniform fs_uniforms
{
    // Source texel, in texture coordinates.
    mediump vec4 texel;
};

void main()
{
    mediump vec2 o = texel.xy;
    mediump vec3 c = texture(tex0, var_uv + vec2(-o.x, -o.y)).rgb
                   + texture(tex0, var_uv + vec2( o.x, -o.y)).rgb
                   + texture(tex0, var_uv + vec2(-o.x,  o.y)).rgb
                   + texture(tex0, var_uv + vec2( o.x,  o.y)).rgb;
    out_fragColor = vec4(c * 0.25, 1.0);
}
