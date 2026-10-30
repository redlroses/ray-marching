using System;
using RayMarching;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.RenderGraphModule;
using UnityEngine.Rendering.Universal;
using UnityEngine.Serialization;

/// <summary>
///     Universal Render Pipeline ScriptableRendererFeature that renders SDF raymarching volumes (such as lava lamp wax)
///     as a post-opaque or pre-transparent full-screen raster pass using the RenderGraph API.
/// </summary>
public class RayMarchFeature : ScriptableRendererFeature
{
    [Serializable]
    public class Settings
    {
        [Tooltip("URP injection point for the raymarching pass.")]
        public RenderPassEvent RenderPassEvent = RenderPassEvent.BeforeRenderingTransparents;

        [Tooltip("Optional source material whose properties and keywords are copied to the runtime instance.")]
        public Material Material;
    }

    public Settings SettingsData = new();

    private Material _runtimeMaterial;
    private RayMarchPass _pass;

    public override void Create()
    {
        UpdateMaterial();
        _pass = new RayMarchPass();
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        UpdateMaterial();

        if (_runtimeMaterial == null)
        {
            return;
        }

        _pass.Setup(SettingsData, _runtimeMaterial);
        renderer.EnqueuePass(_pass);
    }

    protected override void Dispose(bool disposing)
    {
        if (_runtimeMaterial != null)
        {
            CoreUtils.Destroy(_runtimeMaterial);
            _runtimeMaterial = null;
        }
    }

    private void UpdateMaterial()
    {
        var targetShader = SettingsData.Material.shader;

        if (targetShader == null)
        {
            if (_runtimeMaterial != null)
            {
                CoreUtils.Destroy(_runtimeMaterial);
                _runtimeMaterial = null;
            }

            return;
        }

        if (_runtimeMaterial == null || _runtimeMaterial.shader != targetShader)
        {
            if (_runtimeMaterial != null)
            {
                CoreUtils.Destroy(_runtimeMaterial);
            }

            _runtimeMaterial = CoreUtils.CreateEngineMaterial(targetShader);
        }

        if (SettingsData.Material != null)
        {
            _runtimeMaterial.CopyPropertiesFromMaterial(SettingsData.Material);
        }
    }

    private sealed class RayMarchPass : ScriptableRenderPass
    {
        private static readonly int s_BoxCenterId = Shader.PropertyToID("_BoxCenter");
        private static readonly int s_BoxSizeId = Shader.PropertyToID("_BoxSize");
        private static readonly int s_ParticleShapeId = Shader.PropertyToID("_ParticleShape");
        private static readonly int s_SmoothMinKId = Shader.PropertyToID("_SmoothMinK");
        private static readonly int s_SphereCountId = Shader.PropertyToID("_SphereCount");
        private static readonly int s_SpeedId = Shader.PropertyToID("_Speed");
        private static readonly int s_BottomPoolPercentId = Shader.PropertyToID("_BottomPoolPercent");
        private static readonly int s_TopPoolPercentId = Shader.PropertyToID("_TopPoolPercent");
        private static readonly int s_ConeRadiusBottomPercentId = Shader.PropertyToID("_ConeRadiusBottomPercent");
        private static readonly int s_ConeRadiusTopPercentId = Shader.PropertyToID("_ConeRadiusTopPercent");
        private static readonly int s_HorizontalDispersalPercentId = Shader.PropertyToID("_HorizontalDispersalPercent");
        private static readonly int s_VerticalMinPercentId = Shader.PropertyToID("_VerticalMinPercent");
        private static readonly int s_VerticalMaxPercentId = Shader.PropertyToID("_VerticalMaxPercent");
        private static readonly int s_MinParticlePercentId = Shader.PropertyToID("_MinParticlePercent");
        private static readonly int s_MaxParticlePercentId = Shader.PropertyToID("_MaxParticlePercent");
        private static readonly int s_TempBuoyancySkewId = Shader.PropertyToID("_TempBuoyancySkew");
        private static readonly int s_LingerStrengthId = Shader.PropertyToID("_LingerStrength");
        private static readonly int s_GlossyEnvCubeId = Shader.PropertyToID("_GlossyEnvCube");
        private static readonly int s_GlossyEnvCubeHdrId = Shader.PropertyToID("_GlossyEnvCube_HDR");

        private Material _material;

        private Volume _cachedVolume;
        private BoxCollider _cachedBoxCollider;
        private Collider _cachedCollider;
        private int _lastSearchFrame = -1;

        private sealed class PassData
        {
            internal Material Material;
        }

        public void Setup(Settings s, Material m)
        {
            _material = m;
            renderPassEvent = s.RenderPassEvent;
            ConfigureInput(ScriptableRenderPassInput.Depth | ScriptableRenderPassInput.Color);
        }

        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            var stack = VolumeManager.instance.stack;

            if (!TryGetVolumeData(stack, out var customVolume, out var boundingBoxCenter, out var boundingBoxSize))
            {
                return;
            }

            var resourceData = frameData.Get<UniversalResourceData>();

            _material.SetVector(s_BoxCenterId, boundingBoxCenter);
            _material.SetVector(s_BoxSizeId, boundingBoxSize);
            _material.SetInt(s_ParticleShapeId, (int) customVolume.particleShape.value);
            _material.SetFloat(s_SmoothMinKId, customVolume.smoothMinK.value);
            _material.SetInt(s_SphereCountId, customVolume.sphereCount.value);
            _material.SetFloat(s_SpeedId, customVolume.speed.value);
            _material.SetFloat(s_BottomPoolPercentId, customVolume.bottomPoolPercent.value);
            _material.SetFloat(s_TopPoolPercentId, customVolume.topPoolPercent.value);
            _material.SetFloat(s_ConeRadiusBottomPercentId, customVolume.coneRadiusBottomPercent.value);
            _material.SetFloat(s_ConeRadiusTopPercentId, customVolume.coneRadiusTopPercent.value);
            _material.SetFloat(s_HorizontalDispersalPercentId, customVolume.horizontalDispersalPercent.value);
            _material.SetFloat(s_VerticalMinPercentId, customVolume.verticalMinPercent.value);
            _material.SetFloat(s_VerticalMaxPercentId, customVolume.verticalMaxPercent.value);
            _material.SetFloat(s_MinParticlePercentId, customVolume.minParticlePercent.value);
            _material.SetFloat(s_MaxParticlePercentId, customVolume.maxParticlePercent.value);
            _material.SetFloat(s_TempBuoyancySkewId, customVolume.tempBuoyancySkew.value);
            _material.SetFloat(s_LingerStrengthId, customVolume.lingerStrength.value);

            _material.SetTexture(s_GlossyEnvCubeId, ReflectionProbe.defaultTexture);
            _material.SetVector(s_GlossyEnvCubeHdrId, ReflectionProbe.defaultTextureHDRDecodeValues);

            using var builder = renderGraph.AddRasterRenderPass<PassData>("RayMarch Pass", out var passData);

            passData.Material = _material;
            builder.SetRenderAttachment(resourceData.activeColorTexture, 0);

            if (resourceData.activeDepthTexture.IsValid())
            {
                builder.SetRenderAttachmentDepth(resourceData.activeDepthTexture);
            }

            builder.SetRenderFunc(static (PassData data, RasterGraphContext ctx) =>
            {
                Blitter.BlitTexture(ctx.cmd, Vector2.one, data.Material, 0);
            });
        }

        private bool TryGetVolumeData(
            VolumeStack stack,
            out LavaLampVolume volumeComponent,
            out Vector3 center,
            out Vector3 size)
        {
            center = new Vector3(0f, 0f, 3f);
            size = new Vector3(2f, 4f, 2f);
            volumeComponent = null;

            if (_cachedVolume != null && _cachedVolume.isActiveAndEnabled && !_cachedVolume.isGlobal)
            {
                var profile = _cachedVolume.HasInstantiatedProfile()
                    ? _cachedVolume.profile
                    : _cachedVolume.sharedProfile;

                if (profile != null && profile.TryGet(out volumeComponent) && volumeComponent.active)
                {
                    if (_cachedBoxCollider != null)
                    {
                        center = _cachedBoxCollider.transform.TransformPoint(_cachedBoxCollider.center);
                        size = Vector3.Scale(_cachedBoxCollider.size, _cachedBoxCollider.transform.lossyScale);
                        return true;
                    }

                    if (_cachedCollider != null)
                    {
                        var bounds = _cachedCollider.bounds;
                        center = bounds.center;
                        size = bounds.size;
                        return true;
                    }
                }
            }

            _cachedVolume = null;
            _cachedBoxCollider = null;
            _cachedCollider = null;

            var currentFrame = Time.frameCount;
            var shouldSearchScene = _lastSearchFrame != currentFrame;

            if (shouldSearchScene)
            {
                _lastSearchFrame = currentFrame;
                var volumes = FindObjectsByType<Volume>(FindObjectsSortMode.None);

                for (var i = 0; i < volumes.Length; i++)
                {
                    var candidate = volumes[i];

                    if (candidate.isGlobal || !candidate.enabled)
                    {
                        continue;
                    }

                    var profile = candidate.HasInstantiatedProfile() ? candidate.profile : candidate.sharedProfile;

                    if (profile != null && profile.TryGet<LavaLampVolume>(out var vol) && vol.active)
                    {
                        var colliderComponent = candidate.GetComponent<Collider>();

                        if (colliderComponent != null)
                        {
                            _cachedVolume = candidate;
                            _cachedCollider = colliderComponent;
                            _cachedBoxCollider = colliderComponent as BoxCollider;
                            volumeComponent = vol;

                            if (_cachedBoxCollider != null)
                            {
                                center = _cachedBoxCollider.transform.TransformPoint(_cachedBoxCollider.center);
                                size = Vector3.Scale(_cachedBoxCollider.size, _cachedBoxCollider.transform.lossyScale);
                            }
                            else
                            {
                                var bounds = colliderComponent.bounds;
                                center = bounds.center;
                                size = bounds.size;
                            }

                            return true;
                        }
                    }
                }
            }

            var stackVolume = stack.GetComponent<LavaLampVolume>();

            if (stackVolume != null && stackVolume.active)
            {
                volumeComponent = stackVolume;
                return true;
            }

            return false;
        }
    }
}
