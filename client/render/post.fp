#version 140

// One shader for every bloom pass. `dir.xy` is the blur step in texture
// space: one pass steps horizontally, the next vertically, which is the
// usual separation of a gaussian into two cheap lines. The five taps use
// the linear-filtering trick, so they read like nine. `dir.z` scales the
// result, and a zero step turns the whole thing into a plain textured
// copy, which is what the composite pass is; the weights sum to one
// exactly so that copy is faithful.

in mediump vec2 var_uv;

out vec4 out_fragColor;

uniform mediump sampler2D tex;

uniform fs_uniforms
{
    mediump vec4 dir;
};

void main()
{
    mediump vec2 o1 = dir.xy * 1.3846153846;
    mediump vec2 o2 = dir.xy * 3.2307692308;
    mediump vec4 c = texture(tex, var_uv) * 0.2270270270;
    c += (texture(tex, var_uv + o1) + texture(tex, var_uv - o1)) * 0.3162162162;
    c += (texture(tex, var_uv + o2) + texture(tex, var_uv - o2)) * 0.0702702703;
    out_fragColor = c * dir.z;
}
