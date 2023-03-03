
struct Params {
    view: mat4x4<f32>,
    inv_proj: mat4x4<f32>,
    seed: vec4<f32>,
    offset_pixels: vec4<f32>,
};

struct Sphere {
    position: vec4<f32>,
    radius: vec4<f32>,
    albedo: vec4<f32>,
    specular: vec4<f32>,
    emission: vec4<f32>,
};

struct AABB {
    min_pos: vec4<f32>,
    max_pos: vec4<f32>,
};

struct BVHNode {
    aabb: AABB,
    index: vec4<f32>,
};

struct MeshObject {
    model: mat4x4<f32>,
    inv_model: mat4x4<f32>,
    indicies: vec4<f32>,
    aabb: AABB,
};

struct PointLightObject {
    position: vec4<f32>,
    color: vec4<f32>,
    data: vec4<f32>,
};

struct MeshVertex {
    position: vec4<f32>,
    normal: vec4<f32>,
    uv01: vec4<f32>,
}

@group(0) @binding(0)
var<uniform> params: Params;
@group(0) @binding(1)
var<storage, read> spheres: array<Sphere>;
@group(0) @binding(2)
var<storage, read> meshes: array<MeshObject>;
@group(0) @binding(3)
var<storage, read> vertices: array<MeshVertex>;
@group(0) @binding(4) 
var<storage, read> indicies: array<vec4<f32>>;
@group(0) @binding(5)
var<storage, read> point_lights: array<PointLightObject>;
@group(0) @binding(6)
var tex: texture_storage_2d<rgba32float, write>;

@compute @workgroup_size(8, 8)
fn main(
    @builtin(workgroup_id) workgroud_id: vec3<u32>,
) {

}