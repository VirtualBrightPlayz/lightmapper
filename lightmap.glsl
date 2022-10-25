#version 450
#line 3 "lightmap.glsl"
#extension GL_ARB_compute_shader : require
#extension GL_ARB_separate_shader_objects : enable
#extension GL_ARB_shading_language_420pack : enable
#extension GL_ARB_shader_storage_buffer_object : require

#include "inputs.glsl"
#include "sphere.glsl"
#include "meshobject.glsl"
#line 12 "lightmap.glsl"

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
layout(std430, set = 0, binding = 6) readonly buffer PointLights
{
    PointLightObject lights[];
};
layout(set = 0, binding = 7, rgba32f) uniform image2D outTex;

float seed = 0;
float rand()
{
    float result = fract(sin(seed / 100.0 * dot(gl_GlobalInvocationID.xy, vec2(12.9898, 78.233))) * 43758.5453);
    seed += 1;
    return result;
}

vec3 lastShade = vec3(1);

float atten(vec3 pos)
{
    float att = 0;
    for (uint i = 0; i < lights.length(); i++)
    {
        vec3 dir = normalize(pos - lights[i].position.xyz);
        float d = distance(lights[i].position.xyz + dir * 0, pos);
        if (d <= 0)
            continue;
        float v = (lights[i].position.w / (d * d));
        if (v > 0)
            att += v;
    }
    return att;
}

#include "ray.glsl"
#include "rayhit.glsl"
#include "intersect.glsl"
#line 72 "lightmap.glsl"

vec3 GetBarycentric(vec2 v1, vec2 v2, vec2 v3, vec2 p)
{
    vec3 B = vec3(0);
    B.x = ((v2.y - v3.y)*(p.x-v3.x) + (v3.x - v2.x)*(p.y - v3.y)) /
        ((v2.y-v3.y)*(v1.x-v3.x) + (v3.x-v2.x)*(v1.y -v3.y));
    B.y = ((v3.y - v1.y)*(p.x-v3.x) + (v1.x - v3.x)*(p.y - v3.y)) /
        ((v3.y-v1.y)*(v2.x-v3.x) + (v1.x-v3.x)*(v2.y -v3.y));
    B.z = 1 - B.x - B.y;
    return B;
}

Ray CreateRayFromTriangle(mat4 model, mat4 invModel, MeshVertex v0, MeshVertex v1, MeshVertex v2, vec3 uvw)
{
    // float u = 1.0 / 3.0;
    // uv1 = u * v0.uv01.zw + u * v1.uv01.zw + u * v2.uv01.zw;
    vec3 pos = uvw.x * v0.position.xyz + uvw.y * v1.position.xyz + uvw.z * v2.position.xyz;
    pos = (model * vec4(pos, 1)).xyz;
    vec3 nor = uvw.x * v0.normal.xyz + uvw.y * v1.normal.xyz + uvw.z * v2.normal.xyz;
    nor = (vec4(nor, 0) * invModel).xyz;
    Ray ray = CreateRay(pos, nor);
    return ray;
}

void TraceMesh(MeshObject mesh, PointLightObject light, vec2 uv1, bool add)
{
    uint offset = uint(mesh.indices.x);
    uint count = offset + uint(mesh.indices.y);
    for (uint i = offset; i < count; i += 3)
    {
        MeshVertex v0 = meshVertices[uint(meshIndices[i].x)];
        MeshVertex v1 = meshVertices[uint(meshIndices[i+1].x)];
        MeshVertex v2 = meshVertices[uint(meshIndices[i+2].x)];
        vec3 uvw = GetBarycentric(v0.uv01.zw, v1.uv01.zw, v2.uv01.zw, uv1);
        float minmax = 0.0025;
        if (!(uvw.x >= -minmax && uvw.x <= 1+minmax && uvw.y >= -minmax && uvw.y <= 1+minmax && uvw.z >= -minmax && uvw.z <= 1+minmax))
        {
            continue;
        }
        Ray ray = CreateRayFromTriangle(mesh.model, mesh.invModel, v0, v1, v2, uvw);
        vec3 wpos = ray.origin.xyz;
        float d = distance(ray.origin.xyz, light.position.xyz);
        if (light.position.w > 0 && d > light.position.w)
        {
            // continue;
        }
        // ray.direction = SampleHemisphere(normalize(light.position.xyz - ray.origin.xyz).xyz, 1);
        // ray.direction = normalize(light.position.xyz - ray.origin.xyz).xyz;
        ray.origin = ray.origin.xyz + ray.direction * 0.001;
        // vec3 rng = normalize((vec3(rand(), rand(), rand()) - 0.5) * 2);
        ray.direction = -ray.direction;
        // ray.direction = SampleHemisphere(ray.direction, 0);
        // ray.energy = light.color.rgb;

        vec3 result = vec3(0);
        for (int i = 0; i < 1; i++)
        {
            RayHit hit = Trace(ray);
            vec3 e = ray.energy;
            vec3 s = Shade(ray, hit);
            result += e * s;

            if (ray.energy.x <= 0.0 && ray.energy.y <= 0.0 && ray.energy.z <= 0.0)
                break;
        }
        if (light.position.w > 0)
        {
            // if (d > 0 && false)
                // result *= vec3((light.position.w / (d * d)));
        }
        // ivec2 sizeOut = imageSize(outTex);
        // ivec2 pos = ivec2(round(uv1.x * sizeOut.x), round(uv1.y * sizeOut.y));
        // vec4 color = imageLoad(outTex, pos);
        /*
        if (add || true)
        {
            imageStore(outTex, pos, vec4(result + color.xyz, 1));
        }
        else
        {
            imageStore(outTex, pos, vec4(result, 1));
        }
        */
        minmax = 0;
        int j = (uvw.x >= -minmax && uvw.x <= 1+minmax && uvw.y >= -minmax && uvw.y <= 1+minmax && uvw.z >= -minmax && uvw.z <= 1+minmax) ? 0 : 2;
        int k = (j * 2 + 1);
        k *= k;
        for (int y = -j; y <= j; y++)
        for (int x = -j; x <= j; x++)
        {
            ivec2 sizeOut = imageSize(outTex);
            ivec2 pos = ivec2(round(uv1.x * sizeOut.x), round(uv1.y * sizeOut.y)) + ivec2(x, y);
            vec4 color = imageLoad(outTex, pos);
            if (color.a <= 0 || j == 0)
                imageStore(outTex, pos, vec4(result /*+ color.rgb*/, 1));
        }
        /*
        for (int y = -j; y <= j; y++)
        for (int x = -j; x <= j; x++)
        {
            ivec2 sizeOut = imageSize(tex);
            imageStore(tex, ivec2(uv1.x * sizeOut.x, uv1.y * sizeOut.y) + ivec2(x, y), vec4(1-result, 1));
        }
        */
    }
}

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

        if (ray.energy.x <= 0.0 && ray.energy.y <= 0.0 && ray.energy.z <= 0.0)
            break;
    }
    imageStore(tex, ivec2(id.x, id.y), vec4(result, 1));
}

void main()
{
	uvec3 id = gl_GlobalInvocationID;
    seed = inSeed.x;
    uint i = id.x;
    ivec2 sizeOut = imageSize(outTex);
    vec2 uv1 = vec2(id.xy) / vec2(sizeOut.xy);
    // if (i >= 0 && i < meshes.length())
    for (uint i = 0; i < meshes.length(); i++)
    {
        for (uint j = 0; j < lights.length(); j++)
        {
            TraceMesh(meshes[i], lights[j], uv1, i != 0 && j != 0);
            // break;
        }
    }
    // CS();
}
