#pragma once

#include "consts.slang"
#include "ray.slang"

struct BVHNode
{
    float3 lmin; uint32_t left;
    float3 lmax; uint32_t right;
    float3 rmin; uint32_t triCount;
    float3 rmax; uint32_t firstTri;
    bool IsLeaf() { return triCount > 0; }
}

bool CheckAABB(float3 origin, float3 dir_inv, AABB aabb)
{
    float tmin = 0.0;
    float tmax = float.maxValue;

    for (int i = 0; i < 3; i++)
    {
        float t1 = (aabb.min_pos[i] - origin[i]) * dir_inv[i];
        float t2 = (aabb.max_pos[i] - origin[i]) * dir_inv[i];

        tmin = max(tmin, min(min(t1, t2), tmax));
        tmax = min(tmax, max(max(t1, t2), tmin));
    }

    return tmin < tmax;
}

bool IntersectTriangle_MT97(Ray ray, float3 vert0, float3 vert1, float3 vert2, inout float t, inout float u, inout float v)
{
    float3 edge1 = vert1 - vert0;
    float3 edge2 = vert2 - vert0;

    float3 pvec = cross(ray.direction, edge2);

    float det = dot(edge1, pvec);

    if (det < EPSILON)
        return false;
    float inv_det = 1.0 / det;

    float3 tvec = ray.origin - vert0;

    u = dot(tvec, pvec) * inv_det;
    if (u < 0.0 || u > 1.0)
        return false;
    float3 qvec = cross(tvec, edge1);

    v = dot(ray.direction, qvec) * inv_det;
    if (v < 0.0 || u + v > 1.0)
        return false;

    t = dot(edge2, qvec) * inv_det;

    return true;
}

// This function is based off tiny_bvh's BVH_GPU impl.
void IntersectVertsInds(Ray ray, inout float3 hitDUV, out uint32_t hitIdx, IArray<float4> verts, IArray<uint32_t> primIdx, IArray<BVHNode> bvhNodes)
{
    float3 hit = float3(float.maxValue, 0, 0);
    hitIdx = uint32_t.maxValue;
    uint32_t node = 0;
    uint32_t stack[64];
    uint32_t stackPtr = 0;
    while (true)
    {
        const BVHNode n = bvhNodes[node];
        const float3 lmin = n.lmin;
        const float3 lmax = n.lmax;
        const float3 rmin = n.rmin;
        const float3 rmax = n.rmax;
        const uint32_t triCount = n.triCount;
        if (n.IsLeaf())
        {
            const uint32_t firstTri = n.firstTri;
            for (uint32_t i = 0; i < triCount; i++)
            {
                const uint32_t triIdx = primIdx[firstTri + i].x;
                const uint32_t v0 = triIdx * 3;
                // const float4 edge1 = verts[v0 + 1] - verts[v0];
                // const float4 edge2 = verts[v0 + 2] - verts[v0];
                float t, u, v;
                if (IntersectTriangle_MT97(ray, verts[v0].xyz, verts[v0 + 1].xyz, verts[v0 + 2].xyz, t, u, v))
                {
                    hit = float3(t, u, v);
                    hitIdx = triIdx;
                }
            }
            if (stackPtr == 0)
                break;
            node = stack[--stackPtr];
            continue;
        }
        uint32_t left = n.left;
        uint32_t right = n.right;
        const float3 t1a = (lmin - ray.origin) * ray.direction;
        const float3 t2a = (lmax - ray.origin) * ray.direction;
        const float3 t1b = (rmin - ray.origin) * ray.direction;
        const float3 t2b = (rmax - ray.origin) * ray.direction;
        const float3 minta = min(t1a, t2a);
        const float3 maxta = max(t1a, t2a);
        const float3 mintb = min(t1b, t2b);
        const float3 maxtb = max(t1b, t2b);
        const float tmina = max(max(max(minta.x, minta.y), minta.z), 0);
        const float tminb = max(max(max(mintb.x, mintb.y), mintb.z), 0);
        const float tmaxa = min(min(min(maxta.x, maxta.y), maxta.z), hit.x);
        const float tmaxb = min(min(min(maxtb.x, maxtb.y), maxtb.z), hit.x);
        float dist1 = tmina > tmaxa ? float.maxValue : tmina;
        float dist2 = tminb > tmaxb ? float.maxValue : tminb;
        if (dist1 > dist2)
        {
            float h = dist1;
            dist1 = dist2;
            dist2 = h;
            uint32_t t = left;
            left = right;
            right = t;
        }
        if (dist1 == float.maxValue)
        {
            if (stackPtr == 0)
                break;
            else
                node = stack[--stackPtr];
        }
        else
        {
            node = left;
            if (dist2 != float.maxValue)
                stack[stackPtr++] = right;
        }
    }
    hitDUV = hit;
}

void IntersectMeshObject(Ray ray, inout RayHit bestHit, MeshObject mesh, float4 color, IArray<MeshVertex> meshVertices, IArray<uint4> meshIndices)
{
    float3 origin = mul(mesh.model, float4(ray.origin.xyz, 1)).xyz;
    float3 dir = mul(float4(ray.direction.xyz, 0), mesh.invModel).xyz;
    if (!CheckAABB(origin, 1.0 / dir, mesh.aabb))
        // if ((CheckAABB(ray, 1.0 / ray.direction.xyz, mesh.aabb) && !(mesh.aabb.max_pos.x > ray.origin.x && mesh.aabb.min_pos.x < ray.origin.x && mesh.aabb.max_pos.y > ray.origin.y && mesh.aabb.min_pos.y < ray.origin.y && mesh.aabb.max_pos.z > ray.origin.z && mesh.aabb.min_pos.z < ray.origin.z)))
        return;

    uint offset = uint(mesh.indices.x);
    uint count = offset + uint(mesh.indices.y);
    for (uint i = offset; i < count; i += 3)
    {
        float3 v0 = mul(mesh.model, float4(meshVertices[uint(meshIndices[i].x)].position.xyz, 1)).xyz;
        float3 v1 = mul(mesh.model, float4(meshVertices[uint(meshIndices[i + 1].x)].position.xyz, 1)).xyz;
        float3 v2 = mul(mesh.model, float4(meshVertices[uint(meshIndices[i + 2].x)].position.xyz, 1)).xyz;

        float3 n0 = mul(float4(meshVertices[uint(meshIndices[i].x)].normal.xyz, 0), (mesh.invModel)).xyz;
        float3 n1 = mul(float4(meshVertices[uint(meshIndices[i + 1].x)].normal.xyz, 0), (mesh.invModel)).xyz;
        float3 n2 = mul(float4(meshVertices[uint(meshIndices[i + 2].x)].normal.xyz, 0), (mesh.invModel)).xyz;

        float2 u0 = meshVertices[uint(meshIndices[i].x)].uv01.zw;
        float2 u1 = meshVertices[uint(meshIndices[i + 1].x)].uv01.zw;
        float2 u2 = meshVertices[uint(meshIndices[i + 2].x)].uv01.zw;

        float t, u, v;
        if (IntersectTriangle_MT97(ray, v0, v1, v2, t, u, v))
        {
            float w = 1 - u - v;
            if (t > 0 && t < bestHit.dist)
            {
                bestHit.dist = t;
                bestHit.position = ray.origin + t * ray.direction;
                bestHit.normal = normalize(u * n1 + v * n2 + w * n0);
                bestHit.albedo = float3(0.8);
                bestHit.specular = float3(0.6);
                bestHit.uv1 = u * u1 + v * u2 + w * u0;
            }
        }
    }
}