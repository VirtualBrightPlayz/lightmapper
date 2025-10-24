#pragma once

#include "consts.slang"

struct Ray
{
    float3 origin;
    float3 direction;
    float3 energy;
    float predicted_distance;
}

struct RayHit
{
    float3 position;
    float dist;
    float3 normal;
    float3 albedo;
    float3 specular;
    float3 emission;
    float2 uv1;
}

Ray CreateRay(float3 origin, float3 direction)
{
    Ray ray;
    ray.origin = origin;
    ray.direction = direction;
    ray.energy = float3(1, 1, 1);
    ray.predicted_distance = 0;
    return ray;
}

RayHit CreateRayHit()
{
    RayHit rayHit;
    rayHit.position = float3(0);
    rayHit.dist = float.maxValue;
    rayHit.normal = float3(0);
    rayHit.albedo = float3(0);
    rayHit.specular = float3(0);
    rayHit.emission = float3(0);
    rayHit.uv1 = float2(-1);
    return rayHit;
}