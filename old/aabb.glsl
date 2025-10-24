#line 2 "aabb.glsl"

struct AABB
{
    vec4 min_pos;
    vec4 max_pos;
};

struct BVHNode
{
    AABB aabb;
    vec4 index;
};
