
// vertex shader

struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) vertex_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(
    in: VertexInput
) -> VertexOutput {
    var out: VertexOutput;
    out.vertex_position = vec4<f32>(in.position, 0.0, 1.0);
    out.uv = in.uv;
    return out;
}

// fragment shader

@group(0) @binding(0)
var<uniform> total: vec4<f32>;
@group(0) @binding(1)
var t_diffuse: texture_2d<f32>;
@group(0) @binding(2)
var t_normal: texture_2d<f32>;
@group(0) @binding(3)
var s_diffuse: sampler;

fn filter_5x5(
    uv: vec2<f32>,
) -> vec3<f32> {
    var weights: array<f32, 25> = array<f32, 25>(
        0.0, 1.0, 1.0, 1.0, 0.0,
        1.0, 1.0, 2.0, 1.0, 1.0,
        1.0, 2.0, 4.0, 2.0, 1.0,
        1.0, 1.0, 2.0, 1.0, 1.0,
        0.0, 1.0, 1.0, 1.0, 0.0,
    );
    var vals: array<vec3<f32>, 25> = array<vec3<f32>, 25>();
    var val: vec3<f32> = vec3<f32>();
    for (var y: i32 = -2; y <= 2; y++)
    {
        for (var x: i32 = -2; x <= 2; x++)
        {
            let offset: vec2<f32> = vec2<f32>(f32(x), f32(y));
            let norm2: vec3<f32> = textureSample(t_diffuse, s_diffuse, uv + offset / total.zw).rgb;
            let x2: i32 = x + 2;
            let y2: i32 = y + 2;
            let index: i32 = x2 + y2 * 5;
            val = val + weights[index];
            vals[index] = norm2 * weights[index];
        }
    }

    var k: i32 = 0;
    var l: i32 = 0;
    var vals_sort: array<vec3<f32>, 9> = array<vec3<f32>, 9>();
    var val2: vec3<f32> = vec3<f32>();
    for (var j: i32 = 0; j < 81; j++)
    {
        if (length(val2) <= length(vals[k]))
        {
            k = j;
            val2 = vals[k];
            vals_sort[l] = val2;
            l++;
        }
        if (l > 4) {
            break;
        }
    }
    let out: vec3<f32> = vals_sort[4] / 3.0;
    return out;
};

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    var out: vec4<f32>;
    var y3: vec3<f32>;
    out = vec4<f32>(textureSample(t_diffuse, s_diffuse, in.uv).rgb, 1.0 / (total.x + 1.0));
    out = vec4<f32>(filter_5x5(in.uv), out.a);
    y3 = out.rgb * vec3<f32>(0.2126, 0.7152, 0.0722);
    out = vec4<f32>(out.rgb * (1.0 / ((y3.r + y3.g + y3.b) + 1.0)), out.a);
    return out;
}