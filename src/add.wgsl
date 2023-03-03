
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

// todo: finish filter_5x5
/*fn filter_5x5(
    uv: vec2<f32>,
) -> vec3<f32> {
    var out: vec3<f32>;
    let weights: array<f32, 25> = array<f32, 25>(
        0.0, 1.0, 1.0, 1.0, 0.0,
        1.0, 1.0, 2.0, 1.0, 1.0,
        1.0, 2.0, 4.0, 2.0, 1.0,
        1.0, 1.0, 2.0, 1.0, 1.0,
        0.0, 1.0, 1.0, 1.0, 0.0,
    );
    var vals: array<vec3<f32>, 25> = array<vec3<f32>, 25>();
    var val: vec3<f32>;
    for (var y: i32 = -2; y <= 2; y++)
    {
        for (var x: i32 = -2; x <= 2; x++)
        {
            let offset: vec2<f32> = vec2<f32>(x, y);
            let norm2: vec3<f32> = textureSample(t_diffuse, s_diffuse, uv + offset / total.zw).rgb;
            let x2: i32 = x + 2;
            let y2: i32 = y + 2;
            val = val + weights[x2 + y2 * 5];
            vals[x2 + y2 * 5] = norm2 * weights[x2 + y2 * 5];
        }
    }





    return out;
}*/

fn remap(
    value: vec3<f32>,
    low1: vec3<f32>,
    high1: vec3<f32>,
    low2: vec3<f32>,
    high2: vec3<f32>,
) -> vec3<f32> {
    return low2 + (value - low1) * (high2 - low2) / (high1 - low1);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    var out: vec4<f32>;
    var y3: vec3<f32>;
    out = vec4(textureSample(t_diffuse, s_diffuse, in.uv).rgb, 1.0 / (total.x + 1.0));

    y3 = out.rgb * vec3<f32>(0.2126, 0.7152, 0.0722);
    out = vec4<f32>(out.rgb * (1.0 / ((y3.r + y3.g + y3.b) + 1.0)), out.a);
    return out;
}