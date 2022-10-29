#version 450
#line 3 "lightmap.glsl"
#extension GL_ARB_compute_shader : require
#extension GL_ARB_separate_shader_objects : enable
#extension GL_ARB_shading_language_420pack : enable
#extension GL_ARB_shader_storage_buffer_object : require

#include "inputs.glsl"
#include "sphere.glsl"
#include "meshobject.glsl"
#include "aabb.glsl"
#line 13 "lightmap.glsl"

layout(set = 0, binding = 0, rgba32f) uniform image2D tex;
layout(set = 0, binding = 1) uniform Params
{
    mat4 view;
    mat4 invProj;
    vec4 inSeed;
    vec4 offsetPixels;
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

float atten(vec4 lightPos, vec3 pos)
{
    float att = 0;
    // for (uint i = 0; i < lights.length(); i++)
    {
        // vec3 dir = normalize(pos - lightPos.xyz);
        float d = distance(lightPos.xyz, pos);
        if (d <= 0)
            return att;
            // continue;
        float v = clamp(1.0 - pow(d / lightPos.w, 4), 0, 1) / pow(d, 2);
        // if (v > 0)
            att += v;
    }
    return att;
}

#include "ray.glsl"
#include "rayhit.glsl"
#include "intersect.glsl"
#line 75 "lightmap.glsl"

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

void TraceMesh(MeshObject mesh, vec2 uv1, bool add)
{
    uint offset = uint(mesh.indices.x);
    uint count = offset + uint(mesh.indices.y);
    for (uint i = offset; i < count; i += 3)
    {
        MeshVertex v0 = meshVertices[uint(meshIndices[i].x)];
        MeshVertex v1 = meshVertices[uint(meshIndices[i+1].x)];
        MeshVertex v2 = meshVertices[uint(meshIndices[i+2].x)];
        vec3 uvw = GetBarycentric(v0.uv01.zw, v1.uv01.zw, v2.uv01.zw, uv1);
        vec2 uvmax = max(max(v0.uv01.zw, v1.uv01.zw), v2.uv01.zw);
        vec2 uvmin = min(min(v0.uv01.zw, v1.uv01.zw), v2.uv01.zw);
        float minmax = 0.25;
        if (!(uvw.x >= -minmax && uvw.x <= 1+minmax && uvw.y >= -minmax && uvw.y <= 1+minmax && uvw.z >= -minmax && uvw.z <= 1+minmax))
        {
            continue;
        }
        if (uv1.x < uvmin.x || uv1.x > uvmax.x || uv1.y < uvmin.y || uv1.y > uvmax.y)
        {
            continue;
        }
        Ray ray = CreateRayFromTriangle(mesh.model, mesh.invModel, v0, v1, v2, uvw);
        vec3 wpos = ray.origin.xyz;
        vec3 wnorm = ray.direction.xyz;
        vec3 normal = vec3(0);
        vec3 result = vec3(0);
        /*
        ray.origin = ray.origin.xyz + ray.direction * 0.001;
        // ray.direction = -ray.direction;
        for (int j = 0; j < 1; j++)
        {
            RayHit hit = Trace(ray);
            vec3 e = ray.energy;
            vec3 s = Shade(ray, hit, normal);
            result += e * s;

            if (ray.energy.x <= 0.0 && ray.energy.y <= 0.0 && ray.energy.z <= 0.0)
                break;
        }
        */
        // /*
        float alpha = 0;
        float amax = 0;
        for (uint k = 0; k < lights.length(); k++)
        {
            amax += lights[k].data.x;
            float d = distance(lights[k].position.xyz, wpos + wnorm * 0.001);
            if (d > lights[k].position.w * 2)
            {
                continue;
            }
            // vec3 n = normalize(lights[k].position.xyz - wpos);
            // vec3 rng = cross(GetTangentFromNormal(n), n);
            // vec3 rng = GetTangentFromNormal(n);
            for (float l = 0; l < 8; l++) // 4.0
            {
                vec3 rng = normalize((vec3(rand(), rand(), rand()) - 0.5) * 2);
                // vec3 rng = SampleHemisphere(normalize(lights[k].position.xyz - wpos), 16);
                ray.origin = lights[k].position.xyz + rng * (lights[k].data.x);
                float d2 = distance(ray.origin, wpos + wnorm * 0.001);
                ray.direction = normalize(wpos + wnorm * 0.001 - ray.origin);
                // ray.origin = wpos + wnorm * 0.001;
                // ray.direction = normalize(lights[k].position.xyz - wpos + wnorm * 0.001);
                ray.energy = vec3(1);
                for (int j = 0; j < 1; j++)
                {
                    vec3 result2 = vec3(0);
                    RayHit hit = Trace(ray);
                    vec3 e = ray.energy;
                    if (hit.dist <= d2)
                    {
                        // vec3 s = Shade(ray, hit, normal);
                        // result += e * s;
                        continue;
                    }
                    // vec3 s = Shade(ray, hit, normal);
                    // result += e * s;
                    vec3 val = e * lights[k].color.rgb * atten(lights[k].position, wpos) * lights[k].color.a;
                    result += val;
                    // alpha += lights[k].data.x * atten(lights[k].position, wpos) * lights[k].color.a;

                    if (ray.energy.x <= 0.0 && ray.energy.y <= 0.0 && ray.energy.z <= 0.0)
                        break;
                }
            }
        }
        // */
        // ivec2 sizeOut = imageSize(outTex);
        // imageStore(outTex, ivec2(floor(uv1.x * sizeOut.x) - 1, floor(uv1.y * sizeOut.y) - 1), vec4(result, 1));
        // continue;
        minmax = 0;
        int j = (uvw.x >= -minmax && uvw.x <= 1+minmax && uvw.y >= -minmax && uvw.y <= 1+minmax && uvw.z >= -minmax && uvw.z <= 1+minmax) ? 0 : 0;
        // j = 1;
        int km = (j * 2 + 1);
        km *= km;
        for (int y = -j; y <= j; y++)
        for (int x = -j; x <= j; x++)
        {
            ivec2 sizeOut = imageSize(outTex);
            ivec2 size = imageSize(tex);
            ivec2 pos1 = ivec2(floor(uv1.x * sizeOut.x), floor(uv1.y * sizeOut.y)) + ivec2(x, y) - ivec2(1);
            ivec2 pos2 = ivec2(floor(uv1.x * sizeOut.x), ceil(uv1.y * sizeOut.y)) + ivec2(x, y) - ivec2(1);
            ivec2 pos3 = ivec2(ceil(uv1.x * sizeOut.x), floor(uv1.y * sizeOut.y)) + ivec2(x, y) - ivec2(1);
            ivec2 pos4 = ivec2(ceil(uv1.x * sizeOut.x), ceil(uv1.y * sizeOut.y)) + ivec2(x, y) - ivec2(1);
            // ivec2 pos2 = ivec2(floor(uv1.x * sizeOut.x), floor(uv1.y * sizeOut.y)) + ivec2(x, y);// - ivec2(1);
            vec4 color = imageLoad(outTex, pos1);
            if (color.a <= 0 || j == 0)
            {
                imageStore(outTex, pos1, vec4(result /*+ color.rgb*/, 1));
                imageStore(outTex, pos2, vec4(result /*+ color.rgb*/, 1));
                imageStore(outTex, pos3, vec4(result /*+ color.rgb*/, 1));
                imageStore(outTex, pos4, vec4(result /*+ color.rgb*/, 1));
                // imageStore(tex, pos2, vec4(normal * 0.5 + 0.5, 1));
            }
        }
    }
}

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
void main()
{
	uvec3 id = gl_GlobalInvocationID;
    seed = inSeed.x;
    // uint i = id.z;
    ivec2 sizeOut = imageSize(outTex);
    vec2 uv1 = (offsetPixels.xy + vec2(id.xy)) / vec2(sizeOut.xy);
    if (offsetPixels.x + id.x > sizeOut.x || offsetPixels.y + id.y > sizeOut.y)
        return;
    // if (i >= 0 && i < meshes.length() && meshes[i].indices.z >= 1)
    // imageStore(outTex, ivec2(floor(uv1.x * sizeOut.x), floor(uv1.y * sizeOut.y)), vec4(offsetPixels.xy / vec2(sizeOut.xy), 0, 1));
    // return;
    for (uint i = 0; i < meshes.length(); i++)
    {
        if (meshes[i].indices.z < 1)
            continue;
        // imageStore(outTex, ivec2(floor(uv1.x * sizeOut.x), floor(uv1.y * sizeOut.y)), vec4(1));
        uint j = 0;
        // for (uint j = 0; j < lights.length(); j++)
        {
            TraceMesh(meshes[i], uv1, i != 0 && j != 0);
            // break;
        }
    }
    // else
    {
    }
    // CS();
}
