const PI: f32 = 3.141592653589793238462643383279502884197169399375105820974944592307816406286208998628034825342117067982148086513282306647093844;
const EPSILON: f32 = 1e-8;

struct Params {
    view: mat4x4<f32>,
    inv_proj: mat4x4<f32>,
    seed: vec4<f32>,
    offset_pixels: vec4<f32>,
};

struct Sphere {
    position: vec4<f32>,
    radius: vec4<f32>,
    albedo: vec4<f32>,
    specular: vec4<f32>,
    emission: vec4<f32>,
};

struct AABB {
    min_pos: vec4<f32>,
    max_pos: vec4<f32>,
};

struct BVHNode {
    aabb: AABB,
    index: vec4<f32>,
};

struct MeshObject {
    model: mat4x4<f32>,
    inv_model: mat4x4<f32>,
    indicies: vec4<f32>,
    aabb: AABB,
};

struct PointLightObject {
    position: vec4<f32>,
    color: vec4<f32>,
    data: vec4<f32>,
};

struct MeshVertex {
    position: vec4<f32>,
    normal: vec4<f32>,
    uv01: vec4<f32>,
}

struct Ray {
    origin: vec3<f32>,
    direction: vec3<f32>,
    energy: vec3<f32>,
    predicted_distance: f32,
};

struct RayHit {
    position: vec3<f32>,
    normal: vec3<f32>,
    albedo: vec3<f32>,
    specular: vec3<f32>,
    emission: vec3<f32>,
    uv: vec2<f32>,
    dist: f32,
};

@group(0) @binding(0)
var<uniform> params: Params;
@group(0) @binding(1)
var<storage, read> spheres: array<Sphere>;
@group(0) @binding(2)
var<storage, read> meshes: array<MeshObject>;
@group(0) @binding(3)
var<storage, read> vertices: array<MeshVertex>;
@group(0) @binding(4) 
var<storage, read> indicies: array<vec4<f32>>;
@group(0) @binding(5)
var<storage, read> point_lights: array<PointLightObject>;
@group(0) @binding(6)
var tex: texture_storage_2d<rgba32float, write>;
@group(0) @binding(7)
var out_tex: texture_storage_2d<rgba32float, read_write>;

var<private> last_shade: vec3<f32> = vec3<f32>(1.0, 1.0, 1.0);
var<private> seed: f32;

fn rand(workgroup_id: vec2<u32>) -> f32 {
    let result: f32 = fract(sin(seed / 100.0 * dot(vec2<f32>(workgroup_id), vec2<f32>(12.9898, 78.233))) * 43758.5453);
    seed = seed + 1.0;
    return result;
}

fn energy(color: vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(1.0 / 3.0, 0.0, 0.0));
}

fn sdot(x: vec3<f32>, y: vec3<f32>, f: f32) -> f32 {
    return clamp(dot(x, y) * f, 0.0, 1.0);
}

fn atten(
    light_position: vec4<f32>,
    position: vec3<f32>,
) -> f32 {
    var att: f32 = 0.0;

    let d: f32 = distance(light_position.xyz, position);
    if (d <= 0.0) {
        return att;
    }
    let v: f32 = clamp(1.0 - pow(d / light_position.w, 1.0), 0.0, 1.0);

    att = att + v;

    return att;
}

fn create_ray(origin: vec3<f32>, direction: vec3<f32>) -> Ray {
    var ray: Ray;
    ray.origin = origin;
    ray.direction = direction;
    ray.energy = vec3<f32>(1.0, 1.0, 1.0);
    ray.predicted_distance = 0.0;
    return ray;
}

fn get_barycentric(v1: vec2<f32>, v2: vec2<f32>, v3: vec2<f32>, p: vec2<f32>) -> vec3<f32> {
    var b: vec3<f32>;
    b.x = ((v2.y - v3.y)*(p.x-v3.x) + (v3.x - v2.x)*(p.y - v3.y)) /
        ((v2.y-v3.y)*(v1.x-v3.x) + (v3.x-v2.x)*(v1.y -v3.y));
    b.y = ((v3.y - v1.y)*(p.x-v3.x) + (v1.x - v3.x)*(p.y - v3.y)) /
        ((v3.y-v1.y)*(v2.x-v3.x) + (v1.x-v3.x)*(v2.y -v3.y));
    b.z = 1.0 - b.x - b.y;
    return b;
}

fn create_ray_from_triangle(model: mat4x4<f32>, inv_model: mat4x4<f32>, v0: MeshVertex, v1: MeshVertex, v2: MeshVertex, uvw: vec3<f32>) -> Ray {
    var pos: vec3<f32> = uvw.x * v0.position.xyz + uvw.y * v1.position.xyz + uvw.z * v2.position.xyz;
    pos = (model * vec4<f32>(pos, 1.0)).xyz;
    var nor: vec3<f32> = uvw.x * v0.normal.xyz + uvw.y * v1.normal.xyz + uvw.z * v2.normal.xyz;
    nor = (vec4<f32>(nor, 0.0) * inv_model).xyz;
    return create_ray(pos, nor);
}

fn create_camera_ray(uv: vec2<f32>) -> Ray {
    let origin: vec3<f32> = (params.view * vec4<f32>(0.0, 0.0, 0.0, 1.0)).xyz;
    let dir: vec3<f32> = normalize((params.view * vec4<f32>((params.inv_proj * vec4<f32>(uv, 0.0, 1.0)).xyz, 0.0)).xyz);
    return create_ray(origin, dir);
}

fn create_ray_hit() -> RayHit {
    var out: RayHit;
    out.position = vec3<f32>();
    out.normal = vec3<f32>();
    out.albedo = vec3<f32>();
    out.specular = vec3<f32>();
    out.emission = vec3<f32>();
    out.uv = vec2<f32>(-1.0, 0.0);
    out.dist = (1.0 / 0.0);
    return out;
}

fn check_aabb(ray: Ray, dir_inv: vec3<f32>, aabb: AABB) -> bool {
    var tmin: f32 = 0.0;
    var tmax: f32 = (1.0 / 0.0);

    for (var i: i32 = 0; i < 3; i++) {
        let t1: f32 = (aabb.min_pos[i] - ray.origin[i]) * dir_inv[i];
        let t2: f32 = (aabb.max_pos[i] - ray.origin[i]) * dir_inv[i];

        tmin = max(tmin, min(min(t1, t2), tmax));
        tmax = min(tmax, max(max(t1, t2), tmin));
    }

    return tmin < tmax;
}

fn get_tangent_space(normal: vec3<f32>) -> mat3x3<f32> {
    var helper: vec3<f32> = vec3<f32>(1.0, 0.0, 0.0);
    if (abs(normal.x) > 0.99) {
        helper = vec3<f32>(0.0, 0.0, 1.0);
    }

    let tangent = normalize(cross(normal, helper));
    let binormal = normalize(cross(normal, tangent));
    return mat3x3<f32>(tangent, binormal, normal);
}

fn sample_hemisphere(workgroup_id: vec2<u32>, normal: vec3<f32>, alpha: f32) -> vec3<f32> {
    let cosTheta: f32 = pow(rand(workgroup_id), 1.0 / (alpha + 1.0));
    let sinTheta: f32 = sqrt(1.0 - cosTheta * cosTheta);
    let phi: f32 = 2.0 * PI * rand(workgroup_id);
    let tangent_space_dir: vec3<f32> = vec3<f32>(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

    return tangent_space_dir * get_tangent_space(normal);
}

fn intersect_triangle_mt97(
    ray: Ray,
    vert0: vec3<f32>,
    vert1: vec3<f32>,
    vert2: vec3<f32>,
    t: ptr<function, f32>,
    u: ptr<function, f32>,
    v: ptr<function, f32>,
    ) -> bool {
        let edge1: vec3<f32> = vert1 - vert0;
        let edge2: vec3<f32> = vert2 - vert0;

        let pvec: vec3<f32> = cross(ray.direction, edge2);
        let det: f32 = dot(edge1, pvec);

        if (det < EPSILON) {
            return false;
        }
        let inv_det: f32 = 1.0 / det;

        let tvec: vec3<f32> = ray.origin - vert0;

        *u = dot(tvec, pvec) * inv_det;
        if (*u < 0.0 || *u > 1.0) {
            return false;
        }
        let qvec = cross(tvec, edge1);

        *v = dot(ray.direction, qvec) * inv_det;
        if (*v < 0.0 || *u + *v > 1.0) {
            return false;
        }
        *t = dot(edge2, qvec) * inv_det;

        return true;
    }

fn intersect_mesh_object(ray: Ray, best_hit: ptr<function, RayHit>, mesh: MeshObject, color: vec4<f32>) {
    if (!check_aabb(ray, 1.0 / ray.direction.xyz, mesh.aabb)) {
        return;
    }

    let offset = u32(mesh.indicies.x);
    let count = offset + u32(mesh.indicies.y);
    for (var i: u32 = offset; i < count; i += 3u) {
        let v0: vec3<f32> = (mesh.model * vec4<f32>(vertices[u32(indicies[i].x)].position.xyz, 1.0)).xyz;
        let v1: vec3<f32> = (mesh.model * vec4<f32>(vertices[u32(indicies[i + 1u].x)].position.xyz, 1.0)).xyz;
        let v2: vec3<f32> = (mesh.model * vec4<f32>(vertices[u32(indicies[i + 2u].x)].position.xyz, 1.0)).xyz;

        let n0: vec3<f32> = (vec4<f32>(vertices[u32(indicies[i].x)].normal.xyz, 0.0) * mesh.inv_model).xyz;
        let n1: vec3<f32> = (vec4<f32>(vertices[u32(indicies[i + 1u].x)].normal.xyz, 0.0) * mesh.inv_model).xyz;
        let n2: vec3<f32> = (vec4<f32>(vertices[u32(indicies[i + 2u].x)].normal.xyz, 0.0) * mesh.inv_model).xyz;

        let uv0: vec2<f32> = vertices[u32(indicies[i].x)].uv01.zw;
        let uv1: vec2<f32> = vertices[u32(indicies[i + 1u].x)].uv01.zw;
        let uv2: vec2<f32> = vertices[u32(indicies[i + 2u].x)].uv01.zw;

        var t: f32;
        var u: f32;
        var v: f32;
        if (intersect_triangle_mt97(ray, v0, v1, v2, &t, &u, &v))
        {
            let w: f32 = 1.0 - u - v;
            if (t > 0.0 && t < (*best_hit).dist)
            {
                (*best_hit).dist = t;
                (*best_hit).position = ray.origin + t * ray.direction;
                (*best_hit).normal = normalize(u * n1 + v * n2 + w * n0);
                (*best_hit).albedo = vec3<f32>(0.8, 0.0, 0.0);
                (*best_hit).specular = vec3<f32>(0.6, 0.0, 0.0);
                (*best_hit).uv = u * uv1 + v * uv2 + w * uv0;
            }
        }
    }
}

fn intersect_sphere(ray: Ray, best_hit: ptr<function, RayHit>, sphere: Sphere) {
    let d: vec3<f32> = ray.origin - sphere.position.xyz;
    let p1: f32 = -dot(ray.direction, d);
    let p2sqr: f32 = p1 * p1 - dot(d, d) + sphere.radius.x * sphere.radius.x;
    if (p2sqr < 0.0) {
        return;
    }
    let p2: f32 = sqrt(p2sqr);
    var t: f32;
    if (p1 - p2 > 0.0) {
        t = p1 - p2;
    } else {
        t = p1 + p2;
    }
    if (t > 0.0 && t < (*best_hit).dist) {
        (*best_hit).dist = t;
        (*best_hit).position = ray.origin + t * ray.direction;
        (*best_hit).normal = normalize((*best_hit).position - sphere.position.xyz);
        (*best_hit).albedo = sphere.albedo.xyz;
        (*best_hit).specular = sphere.specular.xyz;
        (*best_hit).emission = sphere.emission.xyz;
        (*best_hit).uv = vec2<f32>(-1.0, 0.0);
    }
}

fn shade(workgroup_id: vec2<u32>, ray: ptr<function, Ray>, hit: RayHit, normal: ptr<function, vec3<f32>>) -> vec3<f32> {
    let dir_light: vec4<f32> = vec4<f32>(0.0, 1.0, 0.0, 1.0);
    if (hit.dist < (1.0 / 0.0)) {
        let albedo: vec3<f32> = min(1.0 - hit.specular, hit.albedo);
        var spec_chance: f32 = energy(hit.specular);
        var diff_chance: f32 = energy(albedo);
        let sum = spec_chance + diff_chance;
        if (sum > 0.0) {
            spec_chance /= sum;
            diff_chance /= sum;
        }

        let roulette: f32 = rand(workgroup_id);
        if (roulette < spec_chance) {
            let alpha: f32 = 15.0;
            (*ray).origin = hit.position + hit.normal * 0.001;
            (*ray).direction = sample_hemisphere(workgroup_id, reflect((*ray).direction, hit.normal), alpha);
            let f = (alpha + 2.0) / (alpha + 1.0);
            (*ray).energy *= (1.0 / spec_chance) * hit.specular * sdot(hit.normal, (*ray).direction, f);
        }
        else if (diff_chance > 0.0 && roulette < spec_chance + diff_chance) {
            (*ray).origin = hit.position + hit.normal * 0.001;
            (*ray).direction = sample_hemisphere(workgroup_id, hit.normal, 1.0);
            (*ray).energy *= (1.0 / diff_chance) * albedo;
        }
        else {
            (*ray).energy = vec3<f32>();
        }
        return hit.emission + vec3<f32>();
    } else {
        (*ray).energy = vec3<f32>();
        let theta: f32 = acos((*ray).direction.y) / -PI;
        let phi: f32 = atan((*ray).direction.x / -(*ray).direction.z) * 2.0 / -PI * 0.5;
        let d = vec3<f32>();
        return d;
    }
}

fn trace_rayhit(ray: Ray, color: vec3<f32>) -> RayHit {
    var best_hit: RayHit = create_ray_hit();

    for (var i: u32 = 0u; i < arrayLength(&meshes); i++) {
        intersect_mesh_object(ray, &best_hit, meshes[i], vec4<f32>(color, 0.0));
    }

    for (var i: u32 = 0u; i < arrayLength(&spheres); i++) {
        intersect_sphere(ray, &best_hit, spheres[i]);
    }
    return best_hit;
}

fn trace_mesh(workgroup_id: vec2<u32>, mesh: MeshObject, uv1: vec2<f32>, add: bool) {
    let offset: u32 = u32(mesh.indicies.x);
    let count: u32 = offset + u32(mesh.indicies.y);
    for (var i: u32 = offset; i < count; i += 3u) {
        let v0: MeshVertex = vertices[u32(indicies[i].x)];
        let v1: MeshVertex = vertices[u32(indicies[i+1u].x)];
        let v2: MeshVertex = vertices[u32(indicies[i+2u].x)];
        let uvw: vec3<f32> = get_barycentric(v0.uv01.zw, v1.uv01.zw, v2.uv01.zw, uv1);
        let uvmax: vec2<f32> = max(max(v0.uv01.zw, v1.uv01.zw), v2.uv01.zw);
        let uvmin: vec2<f32> = min(min(v0.uv01.zw, v1.uv01.zw), v2.uv01.zw);
        var minmax: f32 = 0.25;
        if (!(uvw.x >= -minmax && uvw.x <= 1.0+minmax && uvw.y >= -minmax && uvw.y <= 1.0+minmax && uvw.z >= -minmax && uvw.z <= 1.0+minmax))
        {
            continue;
        }
        if (uv1.x < uvmin.x || uv1.x > uvmax.x || uv1.y < uvmin.y || uv1.y > uvmax.y)
        {
            continue;
        }
        var ray: Ray = create_ray_from_triangle(mesh.model, mesh.inv_model, v0, v1, v2, uvw);
        let wpos: vec3<f32> = ray.origin.xyz;
        let wnorm: vec3<f32> = ray.direction.xyz;
        var normal: vec3<f32> = vec3<f32>();
        var result: vec3<f32> = vec3<f32>();
        var alpha: f32 = 0.0;
        var amax: f32 = 0.0;
        for (var k: u32 = 0u; k < arrayLength(&point_lights); k++) {
            amax += point_lights[k].data.x;
            let d: f32 = distance(point_lights[k].position.xyz, wpos + wnorm * 0.001);
            if (d > point_lights[k].position.w * 2.0) {
                continue;
            }

            var result2: vec3<f32> = vec3<f32>();
            for (var l: f32 = 0.0; l < 4.0; l += 1.0) {
                let rng: vec3<f32> = normalize((vec3<f32>(rand(workgroup_id), rand(workgroup_id), rand(workgroup_id)) - 0.5) * 2.0);
                ray.origin = point_lights[k].position.xyz + rng * (point_lights[k].data.x);
                let d2: f32 = distance(ray.origin, wpos + wnorm * 0.001);
                ray.direction = normalize(wpos + wnorm * 0.001 - ray.origin);
                ray.energy = vec3<f32>(1.0, 0.0, 0.0);
                ray.predicted_distance = d;
                for (var j : i32 = 0; j < 1; j++) {
                    let hit: RayHit = trace_rayhit(ray, vec3<f32>());
                    let e: vec3<f32> = ray.energy;
                    if (hit.dist <= d2)
                    {
                        continue;
                    }
                    let val: vec3<f32> = e * point_lights[k].color.rgb * atten(point_lights[k].position, wpos) * point_lights[k].color.a;
                    result2 += val;
                    if (ray.energy.x <= 0.0 && ray.energy.y <= 0.0 && ray.energy.z <= 0.0) {
                        break;
                    }
                }
            }
            result = result2 / 4.0;
        }
        minmax = 0.0;
        // let j: i32 = 0;
        var km: i32 = (0 * 2 + 1);
        km *= km;
        for (var y: i32 = -0; y <= 0; y++)
        {
            for (var x: i32 = -0; x <= 0; x++)
            {
                let size_out: vec2<i32> = textureDimensions(out_tex);
                let size: vec2<i32> = textureDimensions(tex);
                let pos1: vec2<i32> = vec2<i32>(vec2<f32>(floor(uv1.x * f32(size_out.x)), floor(uv1.y * f32(size_out.y)))) + vec2<i32>(x, y);
                let pos2: vec2<i32> = vec2<i32>(vec2<f32>(floor(uv1.x * f32(size_out.x)), ceil(uv1.y * f32(size_out.y)))) + vec2<i32>(x, y);
                let pos3: vec2<i32> = vec2<i32>(vec2<f32>(ceil(uv1.x * f32(size_out.x)), floor(uv1.y * f32(size_out.y)))) + vec2<i32>(x, y);
                let pos4: vec2<i32> = vec2<i32>(vec2<f32>(ceil(uv1.x * f32(size_out.x)), ceil(uv1.y * f32(size_out.y)))) + vec2<i32>(x, y);
                let color = textureLoad(out_tex, pos1);
                if (color.a <= 0.0) {
                    textureStore(out_tex, pos1, vec4<f32>(result, 1.0));
                    textureStore(out_tex, pos2, vec4<f32>(result, 1.0));
                    textureStore(out_tex, pos3, vec4<f32>(result, 1.0));
                    textureStore(out_tex, pos4, vec4<f32>(result, 1.0));
                }
            }
        }
    }
}

@compute @workgroup_size(8, 8)
fn main_raytrace(
    @builtin(workgroup_id) workgroup_id: vec3<u32>,
) {
    seed = params.seed.x;
    let size: vec2<i32> = textureDimensions(tex);
    let size_out: vec2<i32> = textureDimensions(out_tex);
    let pixel_offset: vec2<f32> = vec2<f32>(rand(workgroup_id.xy) - 0.5, rand(workgroup_id.xy) - 0.5);
    let uv: vec2<f32> = vec2<f32>((vec2<f32>(workgroup_id.xy) + pixel_offset) / vec2<f32>(size.xy) * 2.0 - 1.0);
    var ray: Ray = create_camera_ray(uv);
    var result: vec3<f32> = vec3<f32>();
    var uv1: vec2<f32> = vec2<f32>(-1.0, 0.0);
    for (var i: i32 = 0; i < 2; i++) {
        let hit: RayHit = trace_rayhit(ray, ray.energy);
        if (i == 0 || (hit.uv.x >= 0.0 && hit.uv.y >= 0.0 && uv1.x < 0.0 && uv.y < 0.0)) {
            uv1 = hit.uv;
        }
        let e: vec3<f32> = ray.energy;
        var normal = vec3<f32>();
        let s: vec3<f32> = shade(workgroup_id.xy, &ray, hit, &normal);
        result += e * s;
        if (uv1.x >= 0.0 && uv1.y >= 0.0) {
            let uv2: vec2<i32> = vec2<i32>(i32(uv1.x) * size_out.x, i32(uv1.y) * size_out.y);
            let cur: vec4<f32> = textureLoad(out_tex, uv2);
            textureStore(out_tex, uv2, vec4<f32>(cur.xyz + e * s, 1.0));
        }

        if (ray.energy.x <= 0.0 && ray.energy.y <= 0.0 && ray.energy.z <= 0.0) {
            break;
        }
    }
    textureStore(tex, workgroup_id.xy, vec4<f32>(result, 1.0));
}

@compute @workgroup_size(8, 8)
fn main_lightmap(
    @builtin(workgroup_id) workgroup_id: vec3<u32>,
) {
    let id: vec2<u32> = workgroup_id.xy;
    seed = params.seed.x;
    let size_out: vec2<i32> = textureDimensions(out_tex);
    let uv1: vec2<f32> = (params.offset_pixels.xy + vec2<f32>(id)) / vec2<f32>(size_out);

    for (var i: u32 = 0u; i < arrayLength(&meshes); i++) {
        if (meshes[i].indicies.z < 1.0) {
            continue;
        }

        let j: u32 = 0u;

        trace_mesh(id, meshes[i], uv1, i != 0u && j != 0u);
    }
}
