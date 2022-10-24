#line 2 "meshobject.glsl"

struct MeshObject
{
    mat4 model;
    mat4 invModel;
    vec4 indices;
};

struct MeshVertex
{
    vec4 position;
    vec4 normal;
    vec4 uv01;
};
