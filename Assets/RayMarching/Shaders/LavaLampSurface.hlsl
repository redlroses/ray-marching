#ifndef LAVA_LAMP_SURFACE_INCLUDED
#define LAVA_LAMP_SURFACE_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

TEXTURECUBE(_GlossyEnvCube);
SAMPLER(sampler_GlossyEnvCube);
float4 _GlossyEnvCube_HDR;

/// <summary>
/// Parameters passed to the surface shading evaluator for lava lamp wax.
/// </summary>
struct LavaLampSurfaceParams
{
    float3 positionWS;
    float3 normalWS;
    float3 viewDirWS;
    float2 screenUV;

    float3 boxCenter;
    float3 boxSize;

    float4 baseColor;
    float4 topColor;
    float gradientPower;
    float opacity;

    float metallic;
    float smoothness;

    float4 translucencyColor;
    float translucencyStrength;
    float translucencyPower;
};

/// <summary>
/// Computes physically based lighting, reflections, emission, and subsurface translucency for the wax surface.
/// </summary>
half4 EvaluateLavaLampSurface(LavaLampSurfaceParams p)
{
    // -------------------------------------------------------------------------
    // 1. Vertical Color & Opacity Gradient
    // -------------------------------------------------------------------------
    float3 halfSize = p.boxSize * 0.5;
    float heightFactor = saturate((p.positionWS.y - (p.boxCenter.y - halfSize.y)) / max(0.001, p.boxSize.y));
    float gradientT = pow(heightFactor, max(0.01, p.gradientPower));
    float3 gradientColor = lerp(p.baseColor.rgb, p.topColor.rgb, gradientT);
    float alpha = saturate(lerp(p.baseColor.a, p.topColor.a, gradientT) * p.opacity);
    float3 albedo = min(gradientColor, 1.0);

    // -------------------------------------------------------------------------
    // 2. Input and Surface Data Initialization
    // -------------------------------------------------------------------------
    InputData inputData = (InputData)0;
    inputData.positionWS = p.positionWS;
    inputData.normalWS = NormalizeNormalPerPixel(p.normalWS);
    inputData.viewDirectionWS = GetWorldSpaceNormalizeViewDir(p.positionWS);
    inputData.shadowCoord = TransformWorldToShadowCoord(p.positionWS);
    inputData.normalizedScreenSpaceUV = p.screenUV;
    inputData.bakedGI = SampleSH(inputData.normalWS);
    inputData.shadowMask = half4(1.0, 1.0, 1.0, 1.0);

    SurfaceData surfaceData = (SurfaceData)0;
    surfaceData.albedo = albedo;
    surfaceData.metallic = saturate(p.metallic);
    surfaceData.specular = half3(0.0, 0.0, 0.0);
    surfaceData.smoothness = saturate(p.smoothness);
    surfaceData.normalTS = half3(0.0, 0.0, 1.0);
    surfaceData.occlusion = 1.0;
    surfaceData.emission = max(half3(0.0, 0.0, 0.0), gradientColor - half3(1.0, 1.0, 1.0));
    surfaceData.alpha = alpha;
    surfaceData.clearCoatMask = 0.0;
    surfaceData.clearCoatSmoothness = 0.0;

    BRDFData brdfData;
    InitializeBRDFData(surfaceData, brdfData);
    BRDFData brdfDataClearCoat = (BRDFData)0;

    // -------------------------------------------------------------------------
    // 3. Indirect Specular & Diffuse (Environment GI)
    // -------------------------------------------------------------------------
    half3 reflectVector = reflect(-inputData.viewDirectionWS, inputData.normalWS);
    half NoV = saturate(dot(inputData.normalWS, inputData.viewDirectionWS));
    half fresnelTerm = Pow4(1.0 - NoV);

    half mip = PerceptualRoughnessToMipmapLevel(brdfData.perceptualRoughness);
    half4 encodedIrradiance = half4(SAMPLE_TEXTURECUBE_LOD(_GlossyEnvCube, sampler_GlossyEnvCube, reflectVector, mip));
    half3 indirectSpecular = DecodeHDREnvironment(encodedIrradiance, _GlossyEnvCube_HDR);
    half3 indirectDiffuse = inputData.bakedGI;

    half3 giColor = EnvironmentBRDF(brdfData, indirectDiffuse, indirectSpecular, fresnelTerm);

    // -------------------------------------------------------------------------
    // 4. Direct Lighting (Main Light + Additional Lights)
    // -------------------------------------------------------------------------
    half4 shadowMask = CalculateShadowMask(inputData);
    AmbientOcclusionFactor aoFactor = CreateAmbientOcclusionFactor(inputData, surfaceData);
    Light mainLight = GetMainLight(inputData, shadowMask, aoFactor);

    half3 mainLightColor = LightingPhysicallyBased(
        brdfData,
        brdfDataClearCoat,
        mainLight,
        inputData.normalWS,
        inputData.viewDirectionWS,
        0.0,
        false
    );

    half3 additionalLightsColor = half3(0.0, 0.0, 0.0);
#if defined(_ADDITIONAL_LIGHTS)
    uint pixelLightCount = GetAdditionalLightsCount();
    for (uint lightIndex = 0; lightIndex < pixelLightCount; lightIndex++)
    {
        Light light = GetAdditionalLight(lightIndex, inputData, shadowMask, aoFactor);
        additionalLightsColor += LightingPhysicallyBased(
            brdfData,
            brdfDataClearCoat,
            light,
            inputData.normalWS,
            inputData.viewDirectionWS,
            0.0,
            false
        );
    }
#endif

    // -------------------------------------------------------------------------
    // 5. Subsurface Scattering / Translucency Approximation
    // -------------------------------------------------------------------------
    half3 sssColor = half3(0.0, 0.0, 0.0);
    if (p.translucencyStrength > 0.001)
    {
        float sssDot = saturate(dot(-inputData.viewDirectionWS, mainLight.direction));
        float sssFactor = pow(sssDot, max(0.1, p.translucencyPower)) * p.translucencyStrength;
        float3 sssTint = albedo * p.translucencyColor.rgb;
        float attenuation = mainLight.distanceAttenuation * mainLight.shadowAttenuation;
        sssColor = sssTint * (sssFactor * mainLight.color * attenuation);
    }

    half3 finalColor = giColor + mainLightColor + additionalLightsColor + surfaceData.emission + sssColor;
    return half4(finalColor, surfaceData.alpha);
}

#endif // LAVA_LAMP_SURFACE_INCLUDED
