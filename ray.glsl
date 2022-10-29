#line 2 "ray.glsl"

struct Ray
{
    vec3 origin;
    vec3 direction;
    vec3 energy;
    float predicted_distance;
};

Ray CreateRay(vec3 origin, vec3 direction)
{
    Ray ray;
    ray.origin = origin;
    ray.direction = direction;
    ray.energy = vec3(1, 1, 1);
    ray.predicted_distance = 0;
    return ray;
}

Ray CreateCameraRay(vec2 uv)
{
    vec3 origin = (view * vec4(0, 0, 0, 1)).xyz;
    vec3 dir = (invProj * vec4(uv.xy, 0, 1)).xyz;
    dir = (view * vec4(dir, 0)).xyz;
    dir = normalize(dir);

    return CreateRay(origin, dir);
}
