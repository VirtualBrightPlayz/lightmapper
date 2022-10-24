#version 450
#line 3 "raytrace.glsl"
#extension GL_ARB_compute_shader : require
#extension GL_ARB_separate_shader_objects : enable
#extension GL_ARB_shading_language_420pack : enable
#extension GL_ARB_shader_storage_buffer_object : require

#include "inputs.glsl"
#include "sphere.glsl"
#include "meshobject.glsl"

layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D tex;
layout(set = 0, binding = 1) uniform Params
{
    mat4 view;
    mat4 invProj;
    vec4 inSeed;
};
layout(std430, set = 0, binding = 2) readonly buffer Spheres
{
    Sphere spheres[];
};
layout(std430, set = 0, binding = 3) readonly buffer Meshes
{
    MeshObject meshes[];
};
layout(std430, set = 0, binding = 4) readonly buffer Vertices
{
    MeshVertex meshVertices[];
};
layout(std430, set = 0, binding = 5) readonly buffer Indices
{
    vec4 meshIndices[];
};
layout(set = 0, binding = 6, rgba32f) uniform image2D outTex;

float seed = 0;
float rand()
{
    float result = fract(sin(seed / 100.0 * dot(gl_GlobalInvocationID.xy, vec2(12.9898, 78.233))) * 43758.5453);
    seed += 1;
    return result;
}

vec3 lastShade = vec3(1);

#include "ray.glsl"
#include "rayhit.glsl"
#include "intersect.glsl"

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
void CS()
{
	uvec3 id = gl_GlobalInvocationID;
    seed = inSeed.x;
    ivec2 size = imageSize(tex);
    ivec2 sizeOut = imageSize(outTex);
    vec2 uv = vec2((id.xy + vec2(0.5, 0.5)) / size.xy * 2 - 1);
    Ray ray = CreateCameraRay(uv);
    vec3 result = vec3(0);
    vec2 uv1 = vec2(-1);
    for (int i = 0; i < 8; i++)
    {
        RayHit hit = Trace(ray, ray.energy, true);
        // uv1 = vec2(-1);
        if (i == 0 || (hit.uv1.x >= 0 && hit.uv1.y >= 0 && uv1.x < 0 && uv1.y < 0))
            uv1 = hit.uv1;
        vec3 e = ray.energy;
        vec3 s = Shade(ray, hit);
        result += e * s;
        // result += s;
        // Ray r = CreateRay(hit.position + hit.normal * 0.001, hit.normal);
        // vec3 s2 = Shade(r, hit);
        if (uv1.x >= 0 && uv1.y >= 0)
        {
            ivec2 uv2 = ivec2(uv1.x * sizeOut.x, uv1.y * sizeOut.y);
            vec4 cur = imageLoad(outTex, uv2);
            imageStore(outTex, uv2, vec4(cur.xyz + e * s, 1));
        }

        if (energy(ray.energy) <= 0.0)
            break;
    }
    imageStore(tex, ivec2(id.x, id.y), vec4(result, 1));
}

void main()
{
    CS();
}
