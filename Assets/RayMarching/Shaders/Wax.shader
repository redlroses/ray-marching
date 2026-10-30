Shader "Wax"
{
    Properties
    {
        [Header(Vertical Color Gradient)]
        [HDR] _BaseColor("Bottom Color (Heater Base)", Color) = (1, 1, 1, 1)
        [HDR] _TopColor("Top Color (Cool Top)", Color) = (1, 1, 1, 1)
        _GradientPower("Gradient Falloff Power", Range(0.1, 5.0)) = 1.0
        _Opacity("Wax Opacity", Range(0, 1)) = 1.0

        [Header(Standard Lit PBR Settings)]
        _Metallic("Metallic", Range(0, 1)) = 0.0
        _Smoothness("Smoothness", Range(0, 1)) = 0.5

        [Header(Subsurface Scattering and Translucency)]
        _TranslucencyColor("Translucency Tint", Color) = (1, 1, 1, 1)
        _TranslucencyStrength("Translucency Strength", Range(0, 5)) = 0.0
        _TranslucencyPower("Translucency Power", Range(0.5, 10)) = 3.0
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType" = "Opaque"
        }

        ZWrite On
        ZTest Always
        Cull Off
        Blend SrcAlpha OneMinusSrcAlpha, SrcAlpha One

        Pass
        {
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _SCREEN_SPACE_OCCLUSION
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BLENDING
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BOX_PROJECTION
            #pragma multi_compile_fragment _ _ENVIRONMENTREFLECTIONS_OFF
            #pragma multi_compile _ _LIGHT_LAYERS
            #pragma multi_compile _ _FORWARD_PLUS

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "LavaLampSurface.hlsl"

            #define MAX_SPHERES 10
            #define RAYMARCH_MAX_STEPS 120

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseColor;
                float4 _TopColor;
                float _GradientPower;
                float _Opacity;

                float _Metallic;
                float _Smoothness;

                float4 _TranslucencyColor;
                float _TranslucencyStrength;
                float _TranslucencyPower;

                float3 _BoxCenter;
                float3 _BoxSize;
                int _ParticleShape;
                float _SmoothMinK;
                int _SphereCount;
                float _Speed;
                float _BottomPoolPercent;
                float _TopPoolPercent;
                float _ConeRadiusBottomPercent;
                float _ConeRadiusTopPercent;
                float _HorizontalDispersalPercent;
                float _VerticalMinPercent;
                float _VerticalMaxPercent;
                float _MinParticlePercent;
                float _MaxParticlePercent;
                float _TempBuoyancySkew;
                float _LingerStrength;
            CBUFFER_END

            SAMPLER(sampler_BlitTexture);

            struct FragOutput
            {
                float4 color : SV_Target;
                float depth : SV_Depth;
            };

            // -------------------------------------------------------------------------
            // Ray-Box Intersection
            // -------------------------------------------------------------------------
            bool RayBoxIntersect(float3 ro, float3 rd, float3 boxMin, float3 boxMax, out float tMin, out float tMax)
            {
                float3 invDir = 1.0 / (rd + 1e-6);
                float3 t0 = (boxMin - ro) * invDir;
                float3 t1 = (boxMax - ro) * invDir;

                float3 tNear = min(t0, t1);
                float3 tFar = max(t0, t1);

                tMin = max(max(tNear.x, tNear.y), tNear.z);
                tMax = min(min(tFar.x, tFar.y), tFar.z);

                return (tMin <= tMax) && (tMax > 0.0);
            }

            // -------------------------------------------------------------------------
            // SDF Primitives & Helpers
            // -------------------------------------------------------------------------
            float sdBox(float3 p, float3 b)
            {
                float3 q = abs(p) - b;
                return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
            }

            float sdTorus(float3 p, float2 t)
            {
                float2 q = float2(length(p.xz) - t.x, p.y);
                return length(q) - t.y;
            }

            float3 rotateX(float3 p, float angle)
            {
                float s = sin(angle);
                float c = cos(angle);
                return float3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
            }

            float3 rotateY(float3 p, float angle)
            {
                float s = sin(angle);
                float c = cos(angle);
                return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
            }

            float sdParticle(float3 p, float radius, int shapeType, float time, float idx)
            {
                if (shapeType == 1)
                {
                    return sdBox(p, float3(radius, radius, radius));
                }
                else if (shapeType == 2)
                {
                    float3 rotated = rotateX(p, time * 0.8 + idx);
                    rotated = rotateY(rotated, time * 0.5);
                    return sdTorus(rotated, float2(radius, radius * 0.4));
                }

                return length(p) - radius;
            }

            float smin(float a, float b, float k)
            {
                float h = max(k - abs(a - b), 0.0) / k;
                return min(a, b) - h * h * h * k * (1.0 / 6.0);
            }

            // -------------------------------------------------------------------------
            // Lava Lamp Signed Distance Field
            // -------------------------------------------------------------------------
            float sdLavaLamp(float3 p)
            {
                float3 localP = p - _BoxCenter;
                float3 halfSize = _BoxSize * 0.5;
                float time = _Time.y * _Speed;

                float scaleRef = max(0.0001, _BoxSize.y * 0.25);
                float effectiveK = _SmoothMinK * scaleRef;
                float maxDim = max(_BoxSize.x, max(_BoxSize.y, _BoxSize.z));

                float bottomThickness = _BoxSize.y * (_BottomPoolPercent / 100.0);
                float topThickness = _BoxSize.y * (_TopPoolPercent / 100.0);

                float minRadius = maxDim * (_MinParticlePercent / 100.0);
                float maxRadius = maxDim * (_MaxParticlePercent / 100.0);

                float maxRadiusXZ = max(halfSize.x, halfSize.z);
                float rBottom = maxRadiusXZ * (_ConeRadiusBottomPercent / 100.0);
                float rTop = maxRadiusXZ * (_ConeRadiusTopPercent / 100.0);

                // Polar coordinates for cylindrical/conical container
                float rXZ = length(localP.xz);
                float theta = atan2(localP.z, localP.x);
                float rNormBot = saturate(rXZ / max(0.001, rBottom));
                float rNormTop = saturate(rXZ / max(0.001, rTop));

                // Layer 1 (Macro): Bottom Heated Meniscus & Rotating Convection Lobes (2 lobes, CCW)
                float domeBot = (1.0 - rNormBot * rNormBot) * (scaleRef * 0.10);
                float meniscusBot = (rNormBot * rNormBot * rNormBot * rNormBot) * (scaleRef * 0.08);
                float envelopeBot = 4.0 * rNormBot * (1.0 - rNormBot);
                float rotLobeBot = envelopeBot * (scaleRef * 0.09) * sin(2.0 * theta + time * 1.2);
                float dBottom = (localP.y - (-halfSize.y + bottomThickness)) - (domeBot + meniscusBot + rotLobeBot);

                // Layer 1 (Macro): Top Cooling Crust & Sluggish Convection Lobes (3 lobes, CW, 2x slower)
                float sagTop = (1.0 - rNormTop * rNormTop) * (scaleRef * 0.06);
                float meniscusTop = (rNormTop * rNormTop * rNormTop * rNormTop) * (scaleRef * 0.05);
                float envelopeTop = 4.0 * rNormTop * (1.0 - rNormTop);
                float rotLobeTop = envelopeTop * (scaleRef * 0.07) * cos(3.0 * theta - time * 0.6);
                float dTop = ((halfSize.y - topThickness) - localP.y) - (sagTop + meniscusTop + rotLobeTop);

                // Layer 2 (Micro): Bottom Sub-Surface Anchor Blob (Breeder Mound)
                float rAnchorBot = lerp(minRadius, maxRadius, 0.55);
                float3 pAnchorBot = float3(
                    cos(time * 0.75) * (rBottom * 0.30),
                    (-halfSize.y + bottomThickness) - (rAnchorBot * 0.35) + sin(time * 1.4) * (rAnchorBot * 0.25),
                    sin(time * 0.65) * (rBottom * 0.30)
                );
                float dAnchorBot = length(localP - pAnchorBot) - rAnchorBot;
                dBottom = smin(dBottom, dAnchorBot, effectiveK);

                // Layer 2 (Micro): Top Sub-Surface Anchor Blob (Cooling Sag Droplet)
                float rAnchorTop = lerp(minRadius, maxRadius, 0.50);
                float3 pAnchorTop = float3(
                    sin(time * 0.45 + 1.57) * (rTop * 0.25),
                    (halfSize.y - topThickness) + (rAnchorTop * 0.15) - cos(time * 0.85) * (rAnchorTop * 0.25),
                    cos(time * 0.55) * (rTop * 0.25)
                );
                float dAnchorTop = length(localP - pAnchorTop) - rAnchorTop;
                dTop = smin(dTop, dAnchorTop, effectiveK);

                float d = smin(dBottom, dTop, effectiveK);

                float horizScale = _HorizontalDispersalPercent / 100.0;
                float minY = halfSize.y * (_VerticalMinPercent / 100.0);
                float maxY = halfSize.y * (_VerticalMaxPercent / 100.0);

                float skewVal = (_TempBuoyancySkew / 100.0) * 0.6;
                float lingerExponent = lerp(1.0, 0.4, _LingerStrength / 100.0);

                [loop]
                for (int i = 0; i < MAX_SPHERES; i++)
                {
                    if (i >= _SphereCount)
                    {
                        break;
                    }

                    float idx = float(i);
                    float speedScale = 0.5 + idx * 0.15;
                    float phaseOffset = idx * 1.57;

                    float basePhase = time * speedScale + phaseOffset;
                    float skewedPhase = basePhase + skewVal * cos(basePhase);

                    float rawSin = sin(skewedPhase);
                    float shapedSin = sign(rawSin) * pow(abs(rawSin), lingerExponent);

                    float y = lerp(minY, maxY, shapedSin * 0.5 + 0.5);
                    float x = cos(time * (speedScale * 0.8) + phaseOffset * 1.2) * halfSize.x * horizScale;
                    float z = sin(time * (speedScale * 0.6) + phaseOffset * 2.3) * halfSize.z * horizScale;

                    float sizeT = frac(idx * 0.618);
                    float radius = lerp(minRadius, maxRadius, sizeT);

                    float3 pOffset = localP - float3(x, y, z);
                    float dPart = sdParticle(pOffset, radius, _ParticleShape, time, idx);
                    d = smin(d, dPart, effectiveK);
                }

                return d;
            }

            float SceneSDF(float3 p)
            {
                float3 localP = p - _BoxCenter;
                float3 halfSize = _BoxSize * 0.5;
                float yNorm = saturate((localP.y + halfSize.y) / _BoxSize.y);
                float maxRadiusXZ = max(halfSize.x, halfSize.z);

                float rBottom = maxRadiusXZ * (_ConeRadiusBottomPercent / 100.0);
                float rTop = maxRadiusXZ * (_ConeRadiusTopPercent / 100.0);
                float coneRadius = lerp(rBottom, rTop, yNorm);
                float dCone = length(localP.xz) - coneRadius;

                return max(sdLavaLamp(p), dCone);
            }

            // -------------------------------------------------------------------------
            // Raymarching Intersection Routine
            // -------------------------------------------------------------------------
            bool RayMarch(float3 ro, float3 rd, float maxDist, out float3 hit)
            {
                float3 boxMin = _BoxCenter - _BoxSize * 0.5;
                float3 boxMax = _BoxCenter + _BoxSize * 0.5;
                float tMin, tMax;

                if (!RayBoxIntersect(ro, rd, boxMin, boxMax, tMin, tMax))
                {
                    hit = float3(0.0, 0.0, 0.0);
                    return false;
                }

                float t = max(0.0, tMin);
                float tEnd = min(maxDist, tMax);
                if (tEnd <= t)
                {
                    hit = float3(0.0, 0.0, 0.0);
                    return false;
                }

                float scaleRef = max(0.0001, _BoxSize.y * 0.25);
                float hitEps = 0.0005 * scaleRef;

                [loop]
                for (int i = 0; i < RAYMARCH_MAX_STEPS; i++)
                {
                    float3 p = ro + rd * t;
                    float d = SceneSDF(p);
                    if (d < hitEps)
                    {
                        hit = p;
                        return true;
                    }

                    t += d;
                    if (t > tEnd)
                    {
                        break;
                    }
                }

                hit = float3(0.0, 0.0, 0.0);
                return false;
            }

            // -------------------------------------------------------------------------
            // Fragment Shader
            // -------------------------------------------------------------------------
            FragOutput Frag(Varyings IN)
            {
                float2 uv = IN.texcoord;
                float2 ndcUV = uv * 2.0 - 1.0;

                #if UNITY_UV_STARTS_AT_TOP
                if (_ProjectionParams.x > 0.0)
                {
                    ndcUV.y = -ndcUV.y;
                }
                #endif

                float4 clipPos = float4(ndcUV, 1.0, 1.0);
                float4 viewPos = mul(unity_CameraInvProjection, clipPos);
                viewPos.xyz /= viewPos.w;

                float3 ro = _WorldSpaceCameraPos;
                float3 rd = normalize(mul((float3x3)UNITY_MATRIX_I_V, viewPos.xyz));

                float maxDist = _ProjectionParams.z;
                float rawDepth = SampleSceneDepth(uv);

                #if UNITY_REVERSED_Z
                bool isSky = rawDepth <= 0.00001;
                #else
                bool isSky = rawDepth >= 0.99999;
                #endif

                if (!isSky)
                {
                    float sceneLinearDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
                    float3 camForward = normalize(mul((float3x3)UNITY_MATRIX_I_V, float3(0.0, 0.0, -1.0)));
                    float cosTheta = max(0.0001, dot(rd, camForward));
                    float sceneDist = sceneLinearDepth / cosTheta;
                    maxDist = min(maxDist, sceneDist);
                }

                float3 hit;
                if (RayMarch(ro, rd, maxDist, hit))
                {
                    float scaleRef = max(0.0001, _BoxSize.y * 0.25);
                    float normEps = 0.001 * scaleRef;

                    float3 normal = normalize(float3(
                        SceneSDF(hit + float3(normEps, 0.0, 0.0)) - SceneSDF(hit - float3(normEps, 0.0, 0.0)),
                        SceneSDF(hit + float3(0.0, normEps, 0.0)) - SceneSDF(hit - float3(0.0, normEps, 0.0)),
                        SceneSDF(hit + float3(0.0, 0.0, normEps)) - SceneSDF(hit - float3(0.0, 0.0, normEps))
                    ));

                    LavaLampSurfaceParams sParams;
                    sParams.positionWS = hit;
                    sParams.normalWS = normal;
                    sParams.viewDirWS = -rd;
                    sParams.screenUV = uv;
                    sParams.boxCenter = _BoxCenter;
                    sParams.boxSize = _BoxSize;
                    sParams.baseColor = _BaseColor;
                    sParams.topColor = _TopColor;
                    sParams.gradientPower = _GradientPower;
                    sParams.opacity = _Opacity;
                    sParams.metallic = _Metallic;
                    sParams.smoothness = _Smoothness;
                    sParams.translucencyColor = _TranslucencyColor;
                    sParams.translucencyStrength = _TranslucencyStrength;
                    sParams.translucencyPower = _TranslucencyPower;

                    FragOutput output;
                    output.color = EvaluateLavaLampSurface(sParams);

                    float4 hitCS = TransformWorldToHClip(hit);
                    output.depth = hitCS.z / hitCS.w;
                    return output;
                }

                discard;
                return (FragOutput)0;
            }
            ENDHLSL
        }
    }
}
