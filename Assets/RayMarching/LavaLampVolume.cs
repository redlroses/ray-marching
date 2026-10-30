using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace RayMarching
{
    /// <summary>
    /// Volume component controlling lava lamp raymarching simulation parameters.
    /// Serialized field names correspond to parameters stored in Volume profiles.
    /// </summary>
    [Serializable]
    [VolumeComponentMenu("Post-processing/Lava Lamp")]
    [SupportedOnRenderPipeline(typeof(UniversalRenderPipelineAsset))]
    public class LavaLampVolume : VolumeComponent, IPostProcessComponent
    {
        public enum ParticleShape
        {
            Sphere = 0,
            Cube = 1,
            Torus = 2
        }

        [Serializable]
        public sealed class ParticleShapeParameter : VolumeParameter<ParticleShape>
        {
            public ParticleShapeParameter(ParticleShape value, bool overrideState = false)
                : base(value, overrideState)
            {
            }
        }

        [Tooltip("Legacy toggle parameter. Active state is managed by the VolumeComponent base class.")]
        public BoolParameter isActive = new(false);

        [Header("Simulation Settings")]
        [Tooltip("Geometric shape of procedural wax blobs (Sphere, Cube, Torus).")]
        public ParticleShapeParameter particleShape = new(ParticleShape.Sphere);

        [Tooltip("Smooth-minimum blending factor between SDF primitives.")]
        public ClampedFloatParameter smoothMinK = new(0.5f, 0.01f, 2.0f);

        [Tooltip("Number of animated floating particles inside the lamp.")]
        public ClampedIntParameter sphereCount = new(6, 1, 10);

        [Tooltip("Speed multiplier for the convective cycle animation.")]
        public FloatParameter speed = new(1.0f);

        [Tooltip("Height percentage of the heated bottom wax pool.")]
        public ClampedFloatParameter bottomPoolPercent = new(45f, 0f, 100f);

        [Tooltip("Height percentage of the cooling top wax pool.")]
        public ClampedFloatParameter topPoolPercent = new(35f, 0f, 100f);

        [Header("Cone Zone Limits")]
        [Tooltip("Horizontal radius percentage at the bottom of the container.")]
        public ClampedFloatParameter coneRadiusBottomPercent = new(100f, 0f, 150f);

        [Tooltip("Horizontal radius percentage at the top of the container.")]
        public ClampedFloatParameter coneRadiusTopPercent = new(80f, 0f, 150f);

        [Header("Particle Size Range")]
        [Tooltip("Minimum radius percentage for wax particles.")]
        public ClampedFloatParameter minParticlePercent = new(12f, 1f, 50f);

        [Tooltip("Maximum radius percentage for wax particles.")]
        public ClampedFloatParameter maxParticlePercent = new(24f, 1f, 50f);

        [Header("Smart Flight Control & Dispersal")]
        [Tooltip("Horizontal wander and dispersal percentage within the lamp chamber.")]
        public ClampedFloatParameter horizontalDispersalPercent = new(45f, 0f, 100f);

        [Tooltip("Vertical minimum travel boundary percentage.")]
        public ClampedFloatParameter verticalMinPercent = new(-75f, -100f, 100f);

        [Tooltip("Vertical maximum travel boundary percentage.")]
        public ClampedFloatParameter verticalMaxPercent = new(75f, -100f, 100f);

        [Tooltip("Buoyancy asymmetry factor simulating warm rise vs cool sink dynamics.")]
        public ClampedFloatParameter tempBuoyancySkew = new(40f, 0f, 100f);

        [Tooltip("Strength of lingering behavior at the top and bottom extremes.")]
        public ClampedFloatParameter lingerStrength = new(50f, 0f, 100f);

        public bool IsActive()
        {
            return active;
        }

        public bool IsTileCompatible()
        {
            return false;
        }
    }
}
