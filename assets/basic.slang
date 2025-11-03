struct PerView
{
    float4x4 uWorld;
    float4x4 uInvWorld;
    float4x4 uView;
    float4x4 uInvView;
    float4x4 uProjection;
    float4x4 uInvProjection;
    float3 uViewPos;
};

layout(binding = 0, set = 1) ConstantBuffer<PerView> gPerView;
layout(binding = 0, set = 2) Sampler2D<float4> ColorTex;

struct VertexInput
{
    uint VertexIndex : SV_VertexID;
    float4 Position : TEXCOORD0;
    float4 Normal : TEXCOORD1;
    float4 UV01 : TEXCOORD5;
};

struct FragmentInput
{
    float4 Position : SV_Position;
    float4 UV01 : TEXCOORD0;
    float3 WorldPosition : TEXCOORD1;
    float3 Normal : TEXCOORD2;
    float3 ViewPos : TEXCOORD3;
};

[shader("vertex")]
FragmentInput vertexMain(VertexInput input) {
    FragmentInput output;
    float4 worldPos = mul(gPerView.uWorld, float4(input.Position.xyz, 1.0));
    float3 worldNormal = mul(float3x3(transpose(gPerView.uInvWorld)), input.Normal.xyz);
    float3 normal = mul(float3x3(transpose(gPerView.uInvView)), worldNormal);

    output.Position = mul(gPerView.uProjection, mul(gPerView.uView, worldPos));
    output.UV01 = input.UV01;
    output.WorldPosition = worldPos.xyz;
    output.Normal = normal;
    output.ViewPos = gPerView.uViewPos;
    return output;
}

[shader("fragment")]
float4 fragmentMain(FragmentInput input) : SV_Target {
    return ColorTex.Sample(input.UV01.zw);
}
