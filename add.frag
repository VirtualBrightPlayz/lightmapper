#version 450

layout(location = 0) in vec2 fsin_UV;
layout(location = 0) out vec4 fsout_Color;

layout(set = 0, binding = 0) uniform texture2D tex;
layout(set = 0, binding = 1) uniform sampler texSampler;
layout(set = 0, binding = 2) uniform Params
{
    vec4 total;
};

void main()
{
    fsout_Color = vec4(texture(sampler2D(tex, texSampler), fsin_UV).rgb, 1.0 / (total.x + 1.0));
}
