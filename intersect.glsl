#line 2 "intersect.glsl"

mat3 GetTangentSpace(vec3 normal)
{
    vec3 helper = vec3(1, 0, 0);
    if (abs(normal.x) > 0.99)
        helper = vec3(0, 0, 1);
    
    vec3 tangent = normalize(cross(normal, helper));
    vec3 binormal = normalize(cross(normal, tangent));
    return mat3(tangent, binormal, normal);
}

vec3 GetTangentFromNormal(vec3 normal)
{
    vec3 helper = vec3(1, 0, 0);
    if (abs(normal.x) > 0.99)
        helper = vec3(0, 0, 1);
    
    vec3 tangent = normalize(cross(normal, helper));
    return tangent;
}

vec3 SampleHemisphere(vec3 normal, float alpha)
{
    float cosTheta = pow(rand(), 1 / (alpha + 1));
    // float cosTheta = rand();
    float sinTheta = sqrt(1 - cosTheta * cosTheta);
    float phi = 2 * PI * rand();
    vec3 tangentSpaceDir = vec3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

    return tangentSpaceDir * GetTangentSpace(normal);
}

float energy(vec3 color)
{
    return dot(color, vec3(1.0 / 3.0));
}

float sdot(vec3 x, vec3 y, float f)
{
    return clamp(dot(x, y) * f, 0, 1);
}

float sdot(vec3 x, vec3 y)
{
    return sdot(x, y, 1);
}

void IntersectGroundPlane(Ray ray, inout RayHit bestHit)
{
    float t = -ray.origin.y / ray.direction.y;
    if (t > 0 && t < bestHit.dist)
    {
        bestHit.dist = t;
        bestHit.position = ray.origin + t * ray.direction;
        bestHit.normal = vec3(0, -1, 0);
        bestHit.albedo = vec3(0.8, 0.8, 0.8);
        bestHit.specular = vec3(0.6, 0.6, 0.6);
    }
}

void IntersectSphere(Ray ray, inout RayHit bestHit, Sphere sphere)
{
    vec3 d = ray.origin - sphere.position.xyz;
    float p1 = -dot(ray.direction, d);
    float p2sqr = p1 * p1 - dot(d, d) + sphere.radius.x * sphere.radius.x;
    if (p2sqr < 0)
        return;
    float p2 = sqrt(p2sqr);
    float t = p1 - p2 > 0 ? p1 - p2 : p1 + p2;
    if (t > 0 && t < bestHit.dist)
    {
        bestHit.dist = t;
        bestHit.position = ray.origin + t * ray.direction;
        bestHit.normal = normalize(bestHit.position - sphere.position.xyz);
        bestHit.albedo = sphere.albedo.xyz;
        bestHit.specular = sphere.specular.xyz;
        bestHit.emission = sphere.emission.xyz;
        bestHit.uv1 = vec2(-1);
    }
}

bool IntersectTriangle_MT97(Ray ray, vec3 vert0, vec3 vert1, vec3 vert2, inout float t, inout float u, inout float v)
{
    vec3 edge1 = vert1 - vert0;
    vec3 edge2 = vert2 - vert0;

    vec3 pvec = cross(ray.direction, edge2);

    float det = dot(edge1, pvec);

    if (det < EPSILON)
        return false;
    float inv_det = 1.0 / det;

    vec3 tvec = ray.origin - vert0;

    u = dot(tvec, pvec) * inv_det;
    if (u < 0.0 || u > 1.0)
        return false;
    vec3 qvec = cross(tvec, edge1);

    v = dot(ray.direction, qvec) * inv_det;
    if (v < 0.0 || u + v > 1.0)
        return false;
    
    t = dot(edge2, qvec) * inv_det;

    return true;
}

void IntersectMeshObject(Ray ray, inout RayHit bestHit, MeshObject mesh, vec4 color)
{
    uint offset = uint(mesh.indices.x);
    uint count = offset + uint(mesh.indices.y);
    for (uint i = offset; i < count; i += 3)
    {
        vec3 v0 = (mesh.model * vec4(meshVertices[uint(meshIndices[i].x)].position.xyz, 1)).xyz;
        vec3 v1 = (mesh.model * vec4(meshVertices[uint(meshIndices[i+1].x)].position.xyz, 1)).xyz;
        vec3 v2 = (mesh.model * vec4(meshVertices[uint(meshIndices[i+2].x)].position.xyz, 1)).xyz;

        vec3 n0 = (vec4(meshVertices[uint(meshIndices[i].x)].normal.xyz, 0) * transpose(mesh.invModel)).xyz;
        vec3 n1 = (vec4(meshVertices[uint(meshIndices[i+1].x)].normal.xyz, 0) * transpose(mesh.invModel)).xyz;
        vec3 n2 = (vec4(meshVertices[uint(meshIndices[i+2].x)].normal.xyz, 0) * transpose(mesh.invModel)).xyz;

        vec2 u0 = meshVertices[uint(meshIndices[i].x)].uv01.zw;
        vec2 u1 = meshVertices[uint(meshIndices[i+1].x)].uv01.zw;
        vec2 u2 = meshVertices[uint(meshIndices[i+2].x)].uv01.zw;

        float t, u, v;
        if (IntersectTriangle_MT97(ray, v0, v1, v2, t, u, v))
        {
            float w = 1 - u - v;
            if (t > 0 && t < bestHit.dist)
            {
                bestHit.dist = t;
                bestHit.position = ray.origin + t * ray.direction;
                bestHit.normal = normalize(u * n1 + v * n2 + w * n0);
                // bestHit.normal = normalize(cross(v1 - v0, v2 - v0));
                bestHit.albedo = vec3(0.8);
                bestHit.specular = vec3(0.4);
                bestHit.uv1 = u * u1 + v * u2 + w * u0;
                // bestHit.specular = vec3(1, 0.4, 0.2);
                if (color.w != 0)
                {
                    ivec2 sizeOut = imageSize(outTex);
                    // imageStore(outTex, ivec2(bestHit.uv1.x * sizeOut.x, bestHit.uv1.y * sizeOut.y), vec4(color.xyz, 1));
                }
            }
        }

    }
}

RayHit Trace(Ray ray, vec3 color, bool canShade)
{
    RayHit bestHit = CreateRayHit();
    // IntersectGroundPlane(ray, bestHit);
    /*
    vec3 v0 = vec3(-15, 0, -15);
    vec3 v1 = vec3(15, 0, -15);
    vec3 v2 = vec3(0, 15, -15);
    float t, u, v;
    if (IntersectTriangle_MT97(ray, v0, v1, v2, t, u, v))
    {
        if (t > 0 && t < bestHit.dist)
        {
            bestHit.dist = t;
            bestHit.position = ray.origin + t * ray.direction;
            bestHit.normal = normalize(cross(v1 - v0, v2 - v0));
            bestHit.albedo = vec3(1);
            bestHit.specular = vec3(1, 0.4, 0.2);
        }
    }
    */
    for (uint i = 0; i < meshes.length(); i++)
    {
        IntersectMeshObject(ray, bestHit, meshes[i], vec4(color, 0));
    }
    for (uint i = 0; i < spheres.length(); i++)
    {
        Sphere sph = spheres[i];
        IntersectSphere(ray, bestHit, sph);
    }
    if (canShade)
    {
        // Ray r = CreateRay(bestHit.position, bestHit.normal);
        // vec3 s = Shade(r, bestHit);
        // ivec2 sizeOut = imageSize(outTex);
        // imageStore(outTex, ivec2(bestHit.uv1.x * sizeOut.x, bestHit.uv1.y * sizeOut.y), vec4(s.xyz, 1));
    }
    return bestHit;
}

RayHit Trace(Ray ray)
{
    return Trace(ray, vec3(0), false);
}

vec3 Shade(inout Ray ray, RayHit hit)
{
    vec4 dirLight = vec4(0, 1, 0, 1);
    if (hit.dist < infinity)
    {
        vec3 albedo = min(1 - hit.specular, hit.albedo);
        // float att = atten(hit.position);
        vec3 att = vec3(0);
        for (uint i = 0; i < lights.length(); i++)
        {
            vec3 dirLight2 = normalize(lights[i].position.xyz - hit.position);
            // dirLight2 = GetTangentFromNormal(dirLight2);
            // dirLight2 = SampleHemisphere(dirLight2, 0.1);
            vec3 lightOffset = (lights[i].position.xyz + dirLight2 * -0.25);
            Ray shadowRay = CreateRay(hit.position + hit.normal * 0.001, dirLight2.xyz);
            RayHit shadowHit = Trace(shadowRay);
            uint k = 0;
            for (float j = 0; j <= lights[i].position.w; j+=lights[i].position.w/4.0)
            {
                vec3 rng = normalize((vec3(rand(), rand(), rand()) - 0.5) * 2);
                // vec3 rng = normalize(dirLight2 * rand());
                // vec3 rng = dirLight2;
                lightOffset = (lights[i].position.xyz + rng * -j);
                vec3 dirLight5 = normalize(lightOffset - hit.position);
                // dirLight5 = SampleHemisphere(dirLight5, 0);
                // dirLight5 = cross(dirLight5, dirLight2);
                Ray shadowRay2 = CreateRay(hit.position + hit.normal * 0.001, dirLight5.xyz);
                RayHit shadowHit2 = Trace(shadowRay2);
                if (shadowHit2.dist < infinity)
                {
                    vec3 v = lights[i].color.rgb * atten(hit.position) * lights[i].color.a;
                    // vec3 dirLight3 = normalize(lights[i].position.xyz - shadowHit2.position);
                    vec3 dirLight3 = normalize(lightOffset - shadowHit2.position);
                    v *= clamp(dot(-dirLight5.xyz, dirLight3.xyz), 0, 1);
                    att += v;
                    att /= 2;
                }
                k++;
            }
            // att /= 4.0;
            // att /= k;
            dirLight2 = normalize(lightOffset - hit.position);
            Ray shadowRay2 = CreateRay(hit.position + hit.normal * 0.001, dirLight2.xyz);
            RayHit shadowHit2 = Trace(shadowRay2);
            // if (shadowHit.dist < lights[i].position.w)
            if (shadowHit.dist < infinity && false /*&& dot(dirLight2.xyz, shadowHit.normal) < 0*/)
            {
                vec3 v = lights[i].color.rgb * atten(hit.position) * lights[i].color.a;
                vec3 dirLight3 = normalize(lights[i].position.xyz - shadowHit.position);
                v *= clamp(dot(-dirLight2.xyz, dirLight3.xyz), 0, 1);
                // att += v / 2;
            }
            if (shadowHit2.dist < infinity && false)
            {
                vec3 v = lights[i].color.rgb * atten(hit.position) * lights[i].color.a;
                // vec3 dirLight3 = normalize(lights[i].position.xyz - shadowHit2.position);
                vec3 dirLight3 = normalize(lightOffset - shadowHit2.position);
                v *= clamp(dot(-dirLight2.xyz, dirLight3.xyz), 0, 1);
                // att += v / 2;
            }
        }
        // float att = (1.0 / (hit.dist * hit.dist));
        // albedo *= att;
        // ray.energy *= att;
        float specChance = energy(hit.specular);
        float diffChance = energy(albedo);
        float sum = specChance + diffChance;
        specChance /= sum;
        diffChance /= sum;

        float roulette = rand();
        if (roulette < specChance)
        {
            float alpha = 15.0;
            // float alpha = pow(1000, 1);
            // float alpha = 0.0;
            ray.origin = hit.position + hit.normal * 0.001;
            // ray.direction = reflect(ray.direction, hit.normal);
            ray.direction = SampleHemisphere(reflect(ray.direction, hit.normal), alpha);
            float f = (alpha + 2) / (alpha + 1);
            ray.energy *= (1.0 / specChance) * hit.specular * sdot(hit.normal, ray.direction, f);
        }
        else if (diffChance > 0 && roulette < specChance + diffChance)
        {
            ray.origin = hit.position + hit.normal * 0.001;
            ray.direction = SampleHemisphere(hit.normal, 1);
            ray.energy *= (1.0 / diffChance) * albedo;// * sdot(hit.normal, ray.direction);
        }
        else
        {
            ray.energy = vec3(0);
        }
        return hit.emission + att;


        ray.origin = hit.position + hit.normal * 0.001;
        ray.direction = SampleHemisphere(hit.normal, 1);
        ray.energy *= 2 * hit.albedo * sdot(hit.normal, ray.direction);
        return hit.emission;


        ray.origin = hit.position + hit.normal * 0.001;
        ray.direction = reflect(ray.direction, hit.normal);
        // return hit.normal * 0.5 + 0.5;
        ray.energy *= hit.specular.xyz;
        Ray shadowRay = CreateRay(hit.position + hit.normal * 0.001, -1 * dirLight.xyz);
        RayHit shadowHit = Trace(shadowRay);
        if (shadowHit.dist < infinity)
        {
            ray.direction = SampleHemisphere(hit.normal, 1);
            ray.energy *= 2 * hit.albedo * sdot(hit.normal, ray.direction);
            return vec3(0);
            return hit.emission;
        }
        vec3 val = clamp(dot(hit.normal, dirLight.xyz) * -1, 0, 1) * dirLight.w * hit.albedo.xyz;
        return val + hit.emission.xyz;
    }
    else
    {
        ray.energy = vec3(0);
        float theta = acos(ray.direction.y) / -PI;
        float phi = atan(ray.direction.x, -ray.direction.z) * 2 / -PI * 0.5;
        // return vec3(1);
        // return ray.direction * 0.5 + 0.5;
        return vec3(0);
    }
}
