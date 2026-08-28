#version 140

// One axis of a gaussian blur, run twice: across, then down. A blur is
// separable, so two passes of five taps do what one pass of twenty-five would,
// and the second pass reads what the first wrote.
//
// The taps are not on texel centers. Sitting one between two texels and
// letting the bilinear filter return their weighted mean buys two samples for
// one fetch, which is why five reads here cover nine texels. The offsets and
// weights are the standard pair for a nine-tap kernel.

in mediump vec2 var_uv;

out vec4 out_fragColor;

uniform mediump sampler2D tex0;
uniform fs_uniforms
{
    // One texel along the axis being blurred, and zero across it.
    mediump vec4 blur_step;
};

void main()
{
    mediump vec2 d = blur_step.xy;
    mediump vec3 c = texture(tex0, var_uv).rgb * 0.2270270270;
    c += (texture(tex0, var_uv + d * 1.3846153846).rgb
        + texture(tex0, var_uv - d * 1.3846153846).rgb) * 0.3162162162;
    c += (texture(tex0, var_uv + d * 3.2307692308).rgb
        + texture(tex0, var_uv - d * 3.2307692308).rgb) * 0.0702702703;
    out_fragColor = vec4(c, 1.0);
}
