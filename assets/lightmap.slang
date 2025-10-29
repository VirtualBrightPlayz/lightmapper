#include "consts.slang"
#include "ray.slang"
#include "intersect.slang"

layout(binding = 0, set = 1) [format("rgba8")] RWTexture2D<float4> outTex;
layout(binding = 0, set = 0) StructuredBuffer<ParamsType> Params;
layout(binding = 1, set = 0) StructuredBuffer<MeshObject> Meshes;
layout(binding = 2, set = 0) StructuredBuffer<MeshVertex> Vertices;
layout(binding = 3, set = 0) StructuredBuffer<uint4> Indices;
layout(binding = 4, set = 0) StructuredBuffer<PointLightObject> PointLights;

static float seed = 0;
static uint3 threadId = uint3(0);
float rand()
{
    float result = fract(sin(seed / 100.0 * dot(threadId.xy, float2(12.9898, 78.233))) * 43758.5453);
    seed += 1;
    return result;
}

float atten(float4 lightPos, float3 pos)
{
    float att = 0;
    float d = distance(lightPos.xyz, pos);
    if (d <= 0)
        return att;
    float v = clamp(1.0 - pow(d / lightPos.w, 4), 0, 1) / pow(d, 2);
    v = clamp(1.0 - pow(d / lightPos.w, 1), 0, 1);
    att += v;
    return att;
}

float GetArea(float2 a, float2 b, float2 c)
{
    return (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y)) / 2;
}

// https://gamedev.stackexchange.com/questions/23743/whats-the-most-efficient-way-to-find-barycentric-coordinates
// https://www.scratchapixel.com/lessons/3d-basic-rendering/ray-tracing-rendering-a-triangle/barycentric-coordinates.html
float3 GetBarycentric(float2 a, float2 b, float2 c, float2 p)
{
    float areaABC = GetArea(a, b, c);
    float areaBCP = GetArea(b, c, p);
    float areaCAP = GetArea(c, a, p);
    float3 uvw = float3(0);
    uvw.x = areaBCP / areaABC;
    uvw.y = areaCAP / areaABC;
    uvw.z = 1 - uvw.x - uvw.y;
    return uvw;
}

Ray CreateRayFromTriangle(float4x4 model, float4x4 invModel, MeshVertex v0, MeshVertex v1, MeshVertex v2, float3 uvw)
{
    float3 pos = uvw.x * v0.position.xyz + uvw.y * v1.position.xyz + uvw.z * v2.position.xyz;
    pos = mul(model, float4(pos, 1)).xyz;
    float3 nor = uvw.x * v0.normal.xyz + uvw.y * v1.normal.xyz + uvw.z * v2.normal.xyz;
    nor = mul(float4(nor, 0), invModel).xyz;
    Ray ray = CreateRay(pos, nor);
    return ray;
}

RayHit Trace(Ray ray, float3 color, bool canShade)
{
    RayHit bestHit = CreateRayHit();
    for (uint i = 0; i < Meshes.getCount(); i++)
    {
        IntersectMeshObject(ray, bestHit, Meshes[i], float4(color, 0), Vertices, Indices);
    }
    return bestHit;
}

RayHit Trace(Ray ray)
{
    return Trace(ray, float3(0), false);
}

float2 roundUV(float2 uv)
{
    int2 sizeOut;
    outTex.GetDimensions(sizeOut.x, sizeOut.y);
    return round(uv * float2(sizeOut)) / float2(sizeOut);
}

float4 TraceMesh(MeshObject mesh, float2 uv1)
{
    int2 sizeOut;
    outTex.GetDimensions(sizeOut.x, sizeOut.y);
    float2 halfPixel = 0.5 / sizeOut;
    uint offset = uint(mesh.indices.x);
    uint count = offset + uint(mesh.indices.y);
    float3 normal = float3(0);
    float4 result = float4(0);
    for (uint i = offset; i < count; i += 3)
    {
        MeshVertex v0 = Vertices[uint(Indices[i].x)];
        MeshVertex v1 = Vertices[uint(Indices[i + 1].x)];
        MeshVertex v2 = Vertices[uint(Indices[i + 2].x)];
        float3 uvw = GetBarycentric((v0.uv01.zw), (v1.uv01.zw), (v2.uv01.zw), (uv1));
        float3 uvw2 = GetBarycentric((v0.uv01.zw), (v1.uv01.zw), (v2.uv01.zw), (uv1 + halfPixel * 2));
        float2 uvmax = max(max(v0.uv01.zw, v1.uv01.zw), v2.uv01.zw) + halfPixel;
        float2 uvmin = min(min(v0.uv01.zw, v1.uv01.zw), v2.uv01.zw) - halfPixel;
        float minmax = distance(uvw, uvw2) + EPSILON;
        if (!(uvw.x >= -minmax && uvw.x <= 1 + minmax && uvw.y >= -minmax && uvw.y <= 1 + minmax && uvw.z >= -minmax && uvw.z <= 1 + minmax))
        {
            continue;
        }
        if (uv1.x < uvmin.x || uv1.x > uvmax.x || uv1.y < uvmin.y || uv1.y > uvmax.y)
        {
            continue;
        }
        Ray ray = CreateRayFromTriangle(mesh.model, mesh.invModel, v0, v1, v2, uvw);
        float3 wpos = ray.origin.xyz;
        float3 wnorm = ray.direction.xyz;
        float alpha = 0;
        float amax = 0;
        for (uint k = 0; k < PointLights.getCount(); k++)
        {
            amax += PointLights[k].data.x;
            float d = distance(PointLights[k].position.xyz, wpos + wnorm * 0.001);
            if (d > PointLights[k].position.w * 2)
                continue;
            float3 result2 = float3(0);
            // blur from light size
            for (uint l = 0; l < 4; l++)
            {
                float3 rng = normalize((float3(rand(), rand(), rand()) - 0.5) * 2);
                ray.origin = PointLights[k].position.xyz + rng * (PointLights[k].data.x);
                float d2 = distance(ray.origin, wpos + wnorm * 0.001);
                ray.direction = normalize(wpos + wnorm * 0.001 - ray.origin);
                ray.energy = float3(1);
                ray.predicted_distance = d;
                {
                    RayHit hit = Trace(ray);
                    float3 e = ray.energy;
                    if (hit.dist + EPSILON < d2)
                        continue;
                    float3 val = e * PointLights[k].color.rgb * atten(PointLights[k].position, wpos) * PointLights[k].color.a;
                    result2 += val;
                    normal = (normal + normalize(PointLights[k].position.xyz - wpos)) * 0.5;
                    if (ray.energy.x <= 0.0 && ray.energy.y <= 0.0 && ray.energy.z <= 0.0)
                        break;
                }
            }
            result += float4(result2 / 4.0, 1);
        }
    }
    if (result.a == 0)
    {
        return float4(0);
    }
    return float4(clamp(normal * 0.5 + 0.5, 0, 1), 1);
    return result / result.a;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    threadId = id;
    seed = Params[0].inSeed.x;
    int2 sizeOut;
    outTex.GetDimensions(sizeOut.x, sizeOut.y);
    uint2 uv = Params[0].offsetPixels.xy + id.xy;
    float2 uv1 = (uv + 0.5) / float2(sizeOut);
    for (int i = 0; i < Meshes.getCount(); i++)
    {
        if (Meshes[i].indices.z < 1)
            continue;
        float4 result = TraceMesh(Meshes[i], uv1);
        if (result.w > 0) {
            outTex[uv] = result;
        }
    }
}
