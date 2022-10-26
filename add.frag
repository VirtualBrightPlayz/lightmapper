#version 450

layout(location = 0) in vec2 fsin_UV;
layout(location = 0) out vec4 fsout_Color;

layout(set = 0, binding = 0) uniform texture2D tex;
layout(set = 0, binding = 1) uniform sampler texSampler;
layout(set = 0, binding = 2) uniform Params
{
    vec4 total;
};
layout(set = 0, binding = 3) uniform texture2D texNorm;

vec3 filter_3x3()
{
    float weights[9] = float[](
        1, 2, 1,
        2, 4, 2,
        1, 2, 1
    );
    vec3 vals[9] = vec3[](
        vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0)
    );
    vec3 val = vec3(0);
    for (int y = -1; y <= 1; y++)
    {
        for (int x = -1; x <= 1; x++)
        {
            vec2 offset = vec2(x, y);
            vec3 norm2 = texture(sampler2D(tex, texSampler), fsin_UV + offset / total.zw).rgb;
            int x2 = x + 2;
            int y2 = y + 2;
            val += weights[x2 + y2 * 3];
            vals[x2 + y2 * 3] = norm2 * weights[x2 + y2 * 3];
        }
    }

    int k = 0;
    int l = 0;
    vec3 valsSort[9] = vec3[](
        vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0)
    );
    vec3 val2 = vec3(0);
    {
        for (int j = 0; j < 81; j++)
        {
            if (length(val2) <= length(vals[k]))
            {
                k = j;
                val2 = vals[k];
                valsSort[l] = val2;
                l++;
            }
            if (l > 4)
                break;
        }
    }

    return valsSort[4];
}

vec3 filter_5x5()
{
    float weights[25] = float[](
        0, 1, 1, 1, 0,
        1, 1, 2, 1, 1,
        1, 2, 4, 2, 1,
        1, 1, 2, 1, 1,
        0, 1, 1, 1, 0
    );
    vec3 vals[25] = vec3[](
        vec3(0), vec3(0), vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0), vec3(0), vec3(0)
    );
    vec3 val = vec3(0);
    for (int y = -2; y <= 2; y++)
    {
        for (int x = -2; x <= 2; x++)
        {
            vec2 offset = vec2(x, y);
            vec3 norm2 = texture(sampler2D(tex, texSampler), fsin_UV + offset / total.zw).rgb;
            int x2 = x + 2;
            int y2 = y + 2;
            val += weights[x2 + y2 * 5];
            vals[x2 + y2 * 5] = norm2 * weights[x2 + y2 * 5];
        }
    }

    int k = 0;
    int l = 0;
    vec3 valsSort[25] = vec3[](
        vec3(0), vec3(0), vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0), vec3(0), vec3(0),
        vec3(0), vec3(0), vec3(0), vec3(0), vec3(0)
    );
    vec3 val2 = vec3(0);
    {
        for (int j = 0; j < 625; j++)
        {
            if (length(val2) <= length(vals[k]))
            {
                k = j;
                val2 = vals[k];
                valsSort[l] = val2;
                l++;
            }
            if (l > 12)
                break;
        }
    }

    return valsSort[12];
}

void main()
{
    fsout_Color = vec4(texture(sampler2D(tex, texSampler), fsin_UV).rgb, 1.0 / (total.x + 1.0));
    // fsout_Color.rgb *= filter_3x3();
    // fsout_Color.rgb = filter_5x5();
}
