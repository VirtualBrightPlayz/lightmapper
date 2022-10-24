#line 2 "rayhit.glsl"

struct RayHit
{
    vec3 position;
    float dist;
    vec3 normal;
    vec3 albedo;
    vec3 specular;
    vec3 emission;
    vec2 uv1;
};

RayHit CreateRayHit()
{
    RayHit rayHit;
    rayHit.position = vec3(0);
    rayHit.dist = infinity;
    rayHit.normal = vec3(0);
    rayHit.albedo = vec3(0);
    rayHit.specular = vec3(0);
    rayHit.emission = vec3(0);
    rayHit.uv1 = vec2(-1);
    return rayHit;
}
