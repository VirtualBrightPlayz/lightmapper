#include "consts.slang"
#include "ray.slang"
#include "intersect.slang"

layout(binding = 0, set = 0) Texture2D<float4> colorTex;
// layout(binding = 1, set = 0) Texture2D<float4> emissionTex;

layout(binding = 1, set = 0) StructuredBuffer<ParamsType> Params;
layout(binding = 2, set = 0) StructuredBuffer<PointLightObject> PointLights;
layout(binding = 3, set = 0) StructuredBuffer<BVHNode> BVHNodes;
layout(binding = 4, set = 0) StructuredBuffer<MeshVertex> BVHVertices;
layout(binding = 5, set = 0) StructuredBuffer<uint32_t> BVHIndices;

layout(binding = 0, set = 1) RWTexture2D<float4> outTex;

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

float atten2(float lightRange, float d)
{
    float att = 0;
    if (d <= 0 || d >= lightRange)
        return att;
    float v = clamp(1.0 - pow(d / lightRange, 4), 0, 1) / pow(d, 2);
    v = clamp(1.0 - pow(d / lightRange, 1), 0, 1);
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

Ray CreateRayFromTriangle(MeshVertex v0, MeshVertex v1, MeshVertex v2, float3 uvw)
{
    float3 pos = uvw.x * v0.position.xyz + uvw.y * v1.position.xyz + uvw.z * v2.position.xyz;
    float3 nor = uvw.x * v0.normal.xyz + uvw.y * v1.normal.xyz + uvw.z * v2.normal.xyz;
    Ray ray = CreateRay(pos, nor);
    return ray;
}

RayHit Trace(Ray ray, float3 color, bool canShade)
{
    float3 hitDUV;
    uint32_t hitIdx;
    IntersectVertsInds(ray, hitDUV, hitIdx, BVHVertices, BVHIndices, BVHNodes);

    RayHit bestHit = CreateRayHit();
    if (hitIdx != uint32_t.maxValue)
    {
        const uint32_t v0 = hitIdx * 3;
        const MeshVertex vertex0 = BVHVertices[v0];
        const MeshVertex vertex1 = BVHVertices[v0 + 1];
        const MeshVertex vertex2 = BVHVertices[v0 + 2];
        const float w = 1 - hitDUV.y - hitDUV.z;
        bestHit.dist = hitDUV.x;
        bestHit.position = ray.origin + hitDUV.x * ray.direction;
        bestHit.normal = normalize(hitDUV.y * vertex1.normal.xyz + hitDUV.z * vertex2.normal.xyz + w * vertex0.normal.xyz);
        bestHit.albedo = float3(0.8);
        bestHit.specular = float3(0.6);
        bestHit.uv1 = hitDUV.y * vertex1.uv01.zw + hitDUV.z * vertex2.uv01.zw + w * vertex0.uv01.zw;
    }
    return bestHit;
}

RayHit Trace(Ray ray)
{
    return Trace(ray, float3(0), false);
}

bool Trace(Ray ray, inout RayHit bestHit)
{
    float3 hitDUV;
    uint32_t hitIdx = uint32_t.maxValue;
    IntersectVertsInds(ray, hitDUV, hitIdx, BVHVertices, BVHIndices, BVHNodes);

    if (hitIdx != uint32_t.maxValue)
    // if (hitDUV.x != float.maxValue)
    {
        bestHit = CreateRayHit();
        bestHit.dist = hitDUV.x;
        const uint32_t v0 = hitIdx * 3;
        const MeshVertex vertex0 = BVHVertices[v0];
        const MeshVertex vertex1 = BVHVertices[v0 + 1];
        const MeshVertex vertex2 = BVHVertices[v0 + 2];
        const float w = 1 - hitDUV.y - hitDUV.z;
        bestHit.dist = hitDUV.x;
        bestHit.position = ray.origin + hitDUV.x * ray.direction;
        bestHit.normal = normalize(hitDUV.y * vertex1.normal.xyz + hitDUV.z * vertex2.normal.xyz + w * vertex0.normal.xyz);
        bestHit.albedo = float3(0.8);
        bestHit.specular = float3(0.6);
        bestHit.uv1 = hitDUV.y * vertex1.uv01.zw + hitDUV.z * vertex2.uv01.zw + w * vertex0.uv01.zw;
        return true;
    }
    return false;
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

float3 Hemisphere(float3 normal, float theta, float phi)
{
    float cosTheta = cos(theta);
    float sinTheta = sin(theta);
    // float phi = PI * 0.0;
    float3 tangentSpaceDir = float3(
        cos(theta) * sin(phi),
        sin(theta) * sin(phi),
        cos(phi)
    );

    return mul(tangentSpaceDir, GetTangentSpace(normal));
}

void ShadeBVH(const MeshVertex v0, const MeshVertex v1, const MeshVertex v2, const float3 uvw, inout float4 lightColor, inout float4 lightDir)
{
    int2 sizeOut;
    outTex.GetDimensions(sizeOut.x, sizeOut.y);
    Ray ray = CreateRayFromTriangle(v0, v1, v2, uvw);
    float4 resultColor = float4(0);
    float4 resultNormal = float4(0);
    const float3 wpos = ray.origin.xyz;
    const float3 wnorm = ray.direction.xyz;
    // texture lights
    if (Params[0].inSeed.y != 0)
    {
        // sample around us
        for (uint k = 0; k < 1; k++)
        {
            ray.direction = normalize(SampleHemisphere(wnorm, 1.0));
            RayHit hit = Trace(ray);
            if (hit.dist != float.maxValue)
            {
                const float4 sample = colorTex[uint2(hit.uv1 * sizeOut)];
                resultColor.xyz += sample.xyz;
                resultColor.w += 1.0;
                resultNormal.xyz = (resultNormal.xyz + normalize(ray.direction));
                const float attn = 1.0 / hit.dist;
                resultNormal.w = (resultNormal.w + attn);
            }
        }
    }
    else
    {
        // point lights
        for (uint k = 0; k < PointLights.getCount(); k++)
        {
            // reset the ray
            ray.origin = PointLights[k].position.xyz;
            const float3 targetPos = wpos + wnorm * 0.001;
            ray.direction = normalize(targetPos - ray.origin);
            const float d = distance(ray.origin, targetPos);
            ray.energy = PointLights[k].color.rgb * PointLights[k].color.a;
            ray.predicted_distance = 0;
            // trace the ray and shade
            RayHit hit = Trace(ray);
            if (hit.dist + 0.001 < d)
            {
                // we hit something closer, don't shade
                continue;
            }
            const float attn = atten2(PointLights[k].position.w, hit.dist);
            resultColor += float4(ray.energy * attn, 1);
            float3 tangentNormal = -ray.direction;
            resultNormal.xyz = (resultNormal.xyz + tangentNormal);
            resultNormal.w = (resultNormal.w + attn) / 2.0;
        }
    }
    // finalize outputs as needed
    if (resultColor.a != 0)
    {
        lightColor = (lightColor + resultColor / resultColor.a) / 2.0;
        lightColor.a = 1.0;
    }
    lightDir.xyz = (lightDir.xyz + resultNormal.xyz);
    lightDir.w = (lightDir.w + resultNormal.w) / 2.0;
}

float4 TraceBVH(float2 uv1)
{
    int2 sizeOut;
    outTex.GetDimensions(sizeOut.x, sizeOut.y);
    const float2 halfPixel = 0.5 / sizeOut;
    float4 lightColor = float4(0);
    float4 lightDir = float4(0);
    for (uint32_t i = 0; i < BVHIndices.getCount(); i++)
    {
        const MeshVertex v0 = BVHVertices[BVHIndices[i] * 3 + 0];
        const MeshVertex v1 = BVHVertices[BVHIndices[i] * 3 + 1];
        const MeshVertex v2 = BVHVertices[BVHIndices[i] * 3 + 2];
        const float3 uvw = GetBarycentric((v0.uv01.zw), (v1.uv01.zw), (v2.uv01.zw), (uv1));
        const float2 uvmax = max(max(v0.uv01.zw, v1.uv01.zw), v2.uv01.zw) + halfPixel;
        const float2 uvmin = min(min(v0.uv01.zw, v1.uv01.zw), v2.uv01.zw) - halfPixel;
        if (uvw.x < -EPSILON || uvw.x > 1 + EPSILON)
        {
            // continue;
        }
        if (uvw.y < -EPSILON || uvw.y > 1 + EPSILON)
        {
            // continue;
        }
        if (uvw.z < -EPSILON || uvw.z > 1 + EPSILON)
        {
            // continue;
        }
        if (uv1.x < uvmin.x || uv1.x > uvmax.x || uv1.y < uvmin.y || uv1.y > uvmax.y)
        {
            continue;
        }
        ShadeBVH(v0, v1, v2, uvw, lightColor, lightDir);
    }
    if (Params[0].offsetPixels.z == 1)
    {
        return float4((normalize(lightDir.xyz) * 0.5) + 0.5, lightDir.w);
    }
    return lightColor;
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
    if (Params[0].inSeed.y == 0)
    {
        outTex[uv] = float4(0);
    }
    float4 result = TraceBVH(uv1);
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
}
