#include "consts.slang"
#include "ray.slang"
#include "intersect.slang"

layout(binding = 0, set = 1) RWTexture2D<float4> outTex;
layout(binding = 0, set = 0) Texture2D<float4> colorTex;
layout(binding = 1, set = 0) StructuredBuffer<ParamsType> Params;
layout(binding = 2, set = 0) StructuredBuffer<MeshObject> Meshes;
layout(binding = 3, set = 0) StructuredBuffer<MeshVertex> Vertices;
layout(binding = 4, set = 0) StructuredBuffer<uint4> Indices;
layout(binding = 5, set = 0) StructuredBuffer<PointLightObject> PointLights;

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

float atten2(float4 lightPos, float d)
{
    float att = 0;
    if (d <= 0 || d >= lightPos.w)
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

float3 GetTangent(MeshVertex v0, MeshVertex v1, MeshVertex v2)
{
    float3 edge1 = v1.position.xyz - v0.position.xyz;
    float3 edge2 = v2.position.xyz - v0.position.xyz;
    float2 deltaUV1 = v1.uv01.zw - v0.uv01.zw;
    float2 deltaUV2 = v2.uv01.zw - v0.uv01.zw;
    float f = 1.0f / (deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y);
    float3 tangent1 = float3(0);
    tangent1.x = f * (deltaUV2.y * edge1.x - deltaUV1.y * edge2.x);
    tangent1.y = f * (deltaUV2.y * edge1.y - deltaUV1.y * edge2.y);
    tangent1.z = f * (deltaUV2.y * edge1.z - deltaUV1.y * edge2.z);
    return normalize(tangent1);
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

float CalcEnergy(float3 color)
{
    return dot(color, float3(1.0 / 3.0));
}

float3x3 GetTangentSpace(float3 normal)
{
    float3 helper = float3(1, 0, 0);
    if (abs(normal.x) > 0.99)
        helper = float3(0, 0, 1);

    float3 tangent = normalize(cross(normal, helper));
    float3 binormal = normalize(cross(normal, tangent));
    return float3x3(tangent, binormal, normal);
}

float3x3 GetTangentSpace(float3 normal, float3 tangent)
{
    float3 binormal = normalize(cross(normal, tangent));
    return float3x3(tangent, binormal, normal);
}

float3 SampleHemisphere(float3 normal, float alpha)
{
    float cosTheta = pow(rand(), 1 / (alpha + 1));
    // float cosTheta = rand();
    float sinTheta = sqrt(1 - cosTheta * cosTheta);
    float phi = 2 * PI * rand();
    float3 tangentSpaceDir = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

    return mul(tangentSpaceDir, GetTangentSpace(normal));
}

bool ShadeDirectMesh(MeshObject mesh, float2 uv1, bool useRay, Ray originRay, inout float4 color, inout float4 lightDir, out RayHit outHit)
{
    outHit = CreateRayHit();
    int2 sizeOut;
    outTex.GetDimensions(sizeOut.x, sizeOut.y);
    float2 halfPixel = 0.5 / sizeOut;
    float2 halfPixel2 = 0.25 / sizeOut;
    halfPixel2 = float2(0.0);
    uint offset = uint(mesh.indices.x);
    uint count = offset + uint(mesh.indices.y);
    float4 normal = float4(0);
    float4 result = float4(0);
    for (uint i = offset; i < count; i += 3)
    {
        MeshVertex v0 = Vertices[uint(Indices[i].x)];
        MeshVertex v1 = Vertices[uint(Indices[i + 1].x)];
        MeshVertex v2 = Vertices[uint(Indices[i + 2].x)];
        float3 uvw = GetBarycentric((v0.uv01.zw), (v1.uv01.zw), (v2.uv01.zw), (uv1));
        float3 uvw2 = GetBarycentric((v0.uv01.zw), (v1.uv01.zw), (v2.uv01.zw), (uv1 + halfPixel2 * 2));
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
        if (useRay)
            ray = originRay;
        if (useRay)
        {
            // ray = originRay;
            float3 att = float3(0);
            for (uint k = 0; k < PointLights.getCount(); k++)
            {
                float d2 = distance(ray.origin, PointLights[k].position.xyz);
                ray.direction = normalize(ray.origin - PointLights[k].position.xyz);
                RayHit hit = Trace(ray);
                if (hit.dist + EPSILON < d2)
                    continue;
                outHit = hit;
                att = PointLights[k].color.rgb * PointLights[k].color.a * atten(PointLights[k].position, hit.position);
                // normal = (normal + normalize(ray.origin - PointLights[k].position.xyz)) * 0.5;
                result += float4(att, 1);
            }
            continue;
        }
        float3 wpos = ray.origin.xyz;
        float3 wnorm = ray.direction.xyz;
        float3 tangent = GetTangent(v0, v1, v2);
        float alpha = 0;
        float amax = 0;
        // texture lights
        if (Params[0].inSeed.y != 0)
        {
            for (uint k = 0; k < 6; k++)
            {
                ray.direction = SampleHemisphere(wnorm, 1.0);
                RayHit hit = Trace(ray);
                if (hit.dist != float.maxValue)
                {
                    result.xyz += colorTex[uint2(hit.uv1 * sizeOut)].xyz;
                    result.w += 1.0;
                    normal.xyz = (normal.xyz + normalize(ray.direction));
                    float attn = 1.0 / hit.dist;
                    normal.w = (normal.w + attn);
                }
            }
            continue;
        }
        // point lights
        for (uint k = 0; k < PointLights.getCount(); k++)
        {
            amax += PointLights[k].data.x;
            float d = distance(PointLights[k].position.xyz, wpos + wnorm * 0.001);
            // if (d > PointLights[k].position.w * 2)
            //     continue;
            float3 result2 = float3(0);
            // blur from light size
            for (uint l = 0; l < 4; l++)
            {
                float3 rng = normalize((float3(rand(), rand(), rand()) - 0.5) * 2);
                ray.origin = PointLights[k].position.xyz + rng * (PointLights[k].data.x);
                float3 targetPos = wpos + wnorm * 0.001;
                float d2 = distance(ray.origin, targetPos);
                ray.direction = normalize(targetPos - ray.origin);
                ray.energy = PointLights[k].color.rgb * PointLights[k].color.a;
                ray.predicted_distance = d;
                float accDist = 0;
                // bounce this many rays minus one for the initial ray
                for (uint j = 0; j < 1; j++)
                {
                    RayHit hit = Trace(ray);
                    // Ray ray2 = CreateRay(targetPos, -ray.direction);
                    // RayHit hit2 = Trace(ray2);
                    // float3 e = ray.energy;
                    // ray.energy = PointLights[k].color.rgb * PointLights[k].color.a * atten2(PointLights[k].position, accDist);
                    outHit = hit;
                    // if (hit.dist + 0.001 < d2)
                    if (hit.dist + 0.001 < d2)
                    // if (abs(hit.dist - hit2.dist) <= EPSILON && j != 0)
                    {
                        // break;
                        // accDist += hit.dist;
                        float attn = atten2(PointLights[k].position, accDist);
                        // ray.energy *= attn;
                    }
                    else
                    {
                        accDist += hit.dist;
                        float attn = atten2(PointLights[k].position, accDist);
                        ray.energy *= attn;
                        // result2 += PointLights[k].color.rgb * PointLights[k].color.a * atten2(PointLights[k].position, accDist);
                        result2 += ray.energy;
                        float3 worldNormal = -ray.direction; // normalize(PointLights[k].position.xyz - targetPos);
                        // float3 tanNormal = mul(worldNormal, GetTangentSpace(wnorm, tangent));
                        // float3 tanNormal = mul(GetTangentSpace(wnorm, tangent), worldNormal);
                        // float3 tanNormal = hit.normal;
                        float3 tanNormal = worldNormal;
                        normal.xyz = (normal.xyz + tanNormal);
                        normal.w = (normal.w + attn) / 2.0;
                    }

                    if (ray.energy.x <= 0.0 && ray.energy.y <= 0.0 && ray.energy.z <= 0.0)
                        break;
                    ray.origin = hit.position + hit.normal * 0.001;
                    ray.direction = reflect(ray.direction, hit.normal);
                    // ray.direction = SampleHemisphere(reflect(ray.direction, hit.normal), 1.0);
                    continue;
                    RayHit hit2 = Trace(ray);
                    if (hit2.dist == float.maxValue)
                    {
                        break;
                    }
                    accDist += hit2.dist;
                    ray.energy *= saturate(dot(ray.direction, hit.normal));
                    ray.origin = PointLights[k].position.xyz + rng * (PointLights[k].data.x);
                    targetPos = hit2.position + hit2.normal * 0.001;
                    d2 = distance(ray.origin, targetPos);
                    ray.direction = normalize(targetPos - ray.origin);
                }
            }
            result += float4(result2 / 4.0, 1);
        }
    }
    if (result.a == 0)
    {
        // color = float4(0);
    }
    else
    {
        color = (color + result / result.a) / 2.0;
        color.a = 1.0;
    }
    lightDir.xyz = (lightDir.xyz + normal.xyz);
    lightDir.w = (lightDir.w + normal.w) / 2.0;
    return result.a != 0;
}

float4 TraceMesh(MeshObject mesh, float2 uv1)
{
    float4 color = float4(0);
    float4 lightDir = float4(0);
    RayHit hitOut;
    Ray raycast = CreateRay(float3(0), float3(0));
    if (ShadeDirectMesh(mesh, uv1, false, raycast, color, lightDir, hitOut))
    {
        if (Params[0].offsetPixels.z == 1)
        {
            return float4((normalize(lightDir.xyz) * 0.5) + 0.5, lightDir.w);
        }
        return color;
    }
    return float4(0);
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
        if (result.w > 0)
        {
            if (Params[0].inSeed.y == 0)
                outTex[uv] = result;
            else if (Params[0].offsetPixels.z == 1)
            {
                float3 input = outTex[uv].xyz * 2.0 - 1.0;
                float3 normal = result.xyz * 2.0 - 1.0;
                float3 output = normalize(input + normal);
                float inAttn = outTex[uv].w;
                outTex[uv] = float4(output * 0.5 + 0.5, inAttn + result.w / (Params[0].inSeed.y + 1));
            }
            else
                outTex[uv] = outTex[uv] + (result / (Params[0].inSeed.y + 1));
        }
        else if (Params[0].inSeed.y == 0)
        {
            outTex[uv] = float4(0);
        }
    }
}
