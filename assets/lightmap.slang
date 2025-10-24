struct ParamsType
{
    float4x4 view;
    float4x4 invProj;
    float4 inSeed;
    float4 offsetPixels;
}

// RWTexture2D tex;
layout(binding = 0, set = 1) RWTexture2D<float4> outTex;
// ConstantBuffer<ParamsType> Params;

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    outTex[id.xy] = float4(id.xy, 1.0, 1.0);
    // int2 sizeOut = 0;
    // float2 uv1 = (Params.offsetPixels.xy + id.xy);
}
