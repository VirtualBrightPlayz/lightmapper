#pragma once

#ifdef __cplusplus
#include "data_macros.h"
#endif

struct ParamsType
{
    float4x4 view;
    float4x4 invProj;
    float4 inSeed;
    uint4 offsetPixels;
};

struct AABB
{
    float4 min_pos;
    float4 max_pos;
};

struct MeshObject
{
    float4x4 model;
    float4x4 invModel;
    uint4 indices;
    AABB aabb;
};

struct MeshVertex
{
    float4 position;
    float4 normal;
    float4 uv01;
};

struct PointLightObject
{
    float4 position;
    float4 color;
    float4 data;
};