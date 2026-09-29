# Engine Evaluation — CAIRNS AFTER DARK

Evaluated against the *actual* build machine, not an abstract one.

## Build machine (measured, not assumed)

| Property | Value |
|---|---|
| CPU | 8 cores, x86_64 |
| RAM | 29 GiB |
| Disk free | 698 GiB |
| GPU | `virtio-gpu` (PCI 1AF4:1050) — **2D only, no 3D acceleration** |
| Working GL/Vulkan | Mesa **lavapipe** (llvmpipe, Vulkan 1.4.318) — CPU rasteriser |
| Display | Xvfb `:99` @ 1280x900 |

## Candidate: Unreal Engine 5 — REJECTED (unbuildable here)

The brief suggests UE5 for Nanite / Lumen / World Partition. On paper it fits the
visual target. It does not fit the build machine, for four independent hard blockers:

1. **Licensing wall.** UE5 source is behind EULA click-through. There is no
   anonymous download. There are no Epic credentials in this environment, so
   the engine literally cannot be obtained.
2. **Disk/time.** A full engine + project is 150–250 GiB and a first shader-compile
   of Lumen/Nanite/volumetric-fog on 8 CPU cores is measured in *hours*, with no
   GPU to validate on.
3. **No GPU.** Nanite and Lumen require a real Vulkan 1.2+ GPU. Here the only
   device is a CPU rasteriser (`PHYSICAL_DEVICE_TYPE_CPU`). Lumen software
   fallback does not exist in UE5. The renderer would be non-functional.
4. **Iteration cost.** Every gameplay tweak would cost a C++ rebuild + shader
   recompile. For a project whose stated #1 quality bar item is *driving feel* —
   which needs a tight edit/run loop — that is the wrong trade.

## Candidate: Unity — REJECTED (license-gated, wrong fit)

1. **Licensing wall.** Unity Hub requires account sign-in and a Personal licence
   activation against an online service. No credentials available; cannot install.
2. **No GPU.** Same story — Burst/URP would fall back to software GL on a CPU
   rasteriser. URP's screen-space effects (the whole wet-road/volumetric look) are
   unusable at software-rasteriser fill rates.
3. **Vehicle physics.** Unity's `WheelCollider` is notoriously hard to tune into a
   believable 1990s drift car, and the Chaos vehicle package is newer and less
   scriptable than a model we own outright.

## Chosen: Godot 4.3 — MIT licence, no account, no gate

**Why it wins on the actual constraints:**

| Requirement | Godot 4.3 |
|---|---|
| Obtainable without credentials | Yes — anonymous 50 MB download |
| Licence risk on a commercial-style game | MIT. Permissive, no royalties, no revenue share |
| Footprint | ~150 MB, boots in seconds |
| Iteration loop | GDScript hot-reload; **no C++ rebuild, no shader recompile** |
| Renderer | Forward+ (Vulkan) + Compatibility (GL3) + Mobile |
| Large world | `MultiMesh`, `VisibilityRange` LOD, occlusion culling, chunk streaming |
| 2D UI | Mature Control-node system, ideal for a menu/garage-heavy game |
| Testability | Scriptable in `--headless`; a test runner is ~30 lines, no framework |
| CI/self-hosting | Trivial — this repo runs and self-verifies with one command |

**Where UE5 was actually better, and what we do about it**

UE5's real advantages were Nanite (micro-polygon detail) and Lumen (real-time GI).
We accept the loss and substitute with techniques that work on our renderer:

- Nanite → **procedural instancing**. All streetlights, palms, power poles, fences,
  kerbs and houses are generated at load time and drawn with `MultiMeshInstance3D`,
  giving effectively unlimited instance counts for a handful of draw calls. Detail
  budget is spent where the player is actually looking.
- Lumen → **baked-style lighting authored at generation time**: emissive surfaces
  (windows, signs, shopfronts) + a curated set of dynamic sodium/moon lights +
  fog and a cheap screen-space wetness/specular response. Night streets are
  actually *cheaper* to light than day scenes, which suits this project.
- World Partition → **chunked world**: the Manunda block is divided into streamed
  chunks that build/unbuild on demand.

**Vehicle physics — the decisive factor.**
Driving feel is the single highest-priority quality bar item, and this project
demands meaningfully different FWD / RWD / AWD behaviour. Godot ships no
raycast-vehicle model; we write one (~1 physics file) with a real slip-curve tyre
model. We *own* the model, so tuning `Hayate Turbo`'s power-over-steer on
oversteer is an edit and a re-run, not a plugin-config archaeology dig. In UE5
that would mean the Chaos Wheeled Vehicle template plus Blueprints we cannot
visually iterate on without a GPU.

**Honest cost of this choice:** no Nanite, no hardware ray tracing, no Lumen GI,
and a smaller asset ecosystem. We trade maximum-fidelity rendering for shipping
an actual, testable, playable game — which is the correct trade for a prototype
whose first milestone is *"the player can launch, drive Manunda-inspired streets
at night, and finish a race."*

## Verified toolchain

```
godot 4.3.stable.official.77dcf97d8
Vulkan 1.4.318 - Forward+ - llvmpipe (LLVM 20.1.2, 256 bits)   [render verified]
python3 3.12 + numpy + pillow                                  [frame verification]
```

Gotcha worth recording: the Vulkan loader must be pinned to lavapipe via
`VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json`. Without it the loader
probes the non-functional `virtio_icd.json` and **hangs forever** at engine init.
`./run.sh` bakes this in.
