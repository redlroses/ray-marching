# Unity URP Raymarching — Procedural Lava Lamp

<p align="center">
  <img src="Docs/preview.gif" alt="Real-Time Lava Lamp Simulation" />
  <br>
  <em>Real-time procedural SDF fluid simulation.</em>
</p>

<p align="center">
  <img src="Docs/preview.jpg" alt="Environment & Lighting" />
  <br>
  <em>PBR lit shading and scene depth occlusion in Unity 6 URP.</em>
</p>

A real-time procedural lava lamp simulation built on **Signed Distance Fields (SDF)** and **Sphere Tracing (Raymarching)** inside **Unity 6 (URP 17+ / RenderGraph)**.

Unlike polygonal mesh approaches, the fluid wax is mathematically evaluated per-pixel in a custom fragment shader pass, integrating natively with URP's **PBR Lit** lighting model, scene depth occlusion, and hardware Z-buffer writing.

---

## Key Features

- **Procedural SDF Fluid:** Dynamic wax metaballs blended with polynomial smooth minimum (`smin`), confined within a conical flask boundary with convective flow and buoyancy kinematics.
- **Ray-AABB Acceleration:** Oriented bounding box intersection discards empty space to keep sphere tracing performant.
- **Depth Occlusion & Hardware Z-Buffer:** Fully occluded by scene geometry and writes exact surface depth to `SV_Depth`, allowing transparent glass to correctly depth-test against the wax.
- **PBR Surface Shading:** Evaluated with URP's GGX lighting, shadows, ambient reflections, HDR temperature gradients, and subsurface scattering.
- **URP Volume Workflow:** Real-time simulation settings (fluid speed, particle counts, buoyancy skew, pool sizes) are driven via URP Volume profiles.

---

## Project Structure

The implementation is divided into three core components:

- **Raymarching & Shading (`Wax.shader`, `LavaLampSurface.hlsl`)** — Evaluates distance fields and sphere tracing inside an oriented bounding box, outputs hardware depth (`SV_Depth`), and calculates Cook-Torrance GGX surface shading with HDR gradients and subsurface translucency.
- **Pipeline Integration (`RayMarchFeature.cs`)** — Injects the raymarching pass into URP's RenderGraph before transparent objects (`BeforeRenderingTransparents`), passing scene matrices, bounding bounds, and volume parameters.
- **Simulation Controls (`LavaLampVolume.cs`)** — A custom URP Volume component allowing real-time tuning of fluid speed, sphere count, buoyancy, and pool levels directly in the Inspector.

---

## Credits & Attribution

- **Japanese Room Environment:** 3D scene ["Low Poly Scene of Japanese Room at Night"](https://sketchfab.com/3d-models/low-poly-scene-of-japanese-room-at-night-10830bb450bc459593a7920643ce460a) via Sketchfab (used for environment staging, props, and lighting showcase; not created by the project author).

