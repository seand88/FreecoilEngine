# Skeletal (glTF) animation in Recoil, alongside COB/LUS piece animation

Assessment date: 2026-09-15. Engine studied: RecoilEngine master at commit `0fee554`
("Fix GLTF piece axes to match S3O animations", PR #3321), cloned to
`recoil_animation/RecoilEngine`. Upstream prototype studied: branch `embedAnim`
(fetched as `FETCH_HEAD`, head `c52ef97`, 2026-04-08).

## 1. Verdict

Feasible, and most of the hard part already exists in the engine or in an upstream
prototype. The work is an engine change (C++), not a Lua-only or content-only change,
because piece transforms are synced gameplay state: weapons aim and fire from pieces,
per-piece collision volumes are hit-tested, and Lua reads piece positions. Any
skeletal player therefore has to run inside the synced simulation.

Both animation kinds can coexist on the same unit. Existing S3O + COB/LUS units are
untouched: a model with no clips has an empty animation table and the new code
early-outs.

## 2. Does the engine have modules?

No plugin system. Recoil is a monolithic C++ engine layered by directory, and the two
supported extension surfaces are Lua (gadgets, widgets, Lua unit scripts) and the
engine source itself. The seams that matter here already exist and are the right
places to hang this work:

| Seam | Where | Role in this plan |
| --- | --- | --- |
| Model parsers registered per file extension | `rts/Rendering/Models/IModelParser.cpp` (`3do`, `s3o`, `gltf`, `glb`, then Assimp) | glTF parser gains clip loading |
| Immutable shared model | `S3DModel` / `S3DModelPiece` (`3DModel.hpp`, `3DModelPiece.hpp`) | Owns clip data (asset layer) |
| Per-unit instance | `LocalModel` / `LocalModelPiece` (`LocalModelPiece.hpp`) | Synced piece pos / euler rot / scale that everything downstream reads |
| Script backends | `CUnitScript` with `CCobInstance`, `CLuaUnitScript`, `CNullUnitScript` (`rts/Sim/Units/Scripts/`) | Owns per-unit animation state; ticked by `CUnitScriptEngine::Tick` |
| Render upload | `ModelDrawerData.h::UpdateObjectTrasform` and `TransformsMemStorage` | Copies model-space piece transforms (prev + curr) into one SSBO |
| Shaders | `cont/base/springcontent/shaders/GLSL/ModelVertProgGL4.glsl`, `ShadowGenVertProgGL4.glsl` | Already do linear-blend skinning from that SSBO |

## 3. What master already has

- **glTF/GLB loading via fastgltf** (`GLTFParser.cpp`). Node hierarchy becomes the piece
  tree. Scene "extras" or a `<model>.lua` metafile supply `tex1`, `tex2`, bounds,
  `s3ocompat`.
- **Skinning is already wired end to end.** `SVertexData` carries four 16-bit bone
  IDs and four 8-bit weights per vertex (`VertexData.hpp`). The glTF parser reads
  `JOINTS_0/1` and `WEIGHTS_0/1`, maps joints to pieces, reparents skinned meshes onto
  their dominant joint piece (`ModelUtils.cpp`, `Skinning::` namespace) and moves
  vertices into bone space using the inverse bind pose. Bones are just pieces, so the
  same per-piece transform slots drive both rigid pieces and skinned vertices.
- **The GL4 vertex shader blends bones** against the per-unit transform SSBO with
  prev/curr frame interpolation. Latent bug: the blend loop is `for (bi = 1; bi < 3)`,
  so only three of the four influences are used. Same loop in the shadow shader.
- **Procedural animation** lives in `CUnitScript`: `AnimInfo` entries (Turn / Move /
  Spin / Scale, per piece per axis) ticked once per sim frame (30 Hz) in
  `CUnitScriptEngine::Tick` (multithreaded tick, single-threaded completion, hashed
  into the sync checksum). They write `LocalModelPiece` pos, euler rot and uniform
  scale. Piece-space transform is composed as
  `T(offset + script) * R(baked) * R_euler(script) * S` (`3DModelPiece.cpp`).
- **Axis conversion is baked at the parser boundary** since PR #3321
  (`GLTFModelAxisConversion.hpp`): vertices, offsets and rest rotations are converted
  to the engine frame while loading, so script axes are identical for S3O and glTF.
- **Not loaded:** `asset.animations`. The parser requests the fastgltf `Animations`
  category and then ignores it. The docs say so explicitly: "Skinning is supposed to
  be supported, but was never tested"; "Embedded animation is not supported".
- `Spring.SetUnitPieceMatrix` sets `blockScriptAnims`, which freezes a piece against
  script animation (open upstream issue #2275 wants this loosened).

## 4. The upstream prototype: branch `embedAnim` (issue #2444)

The engine maintainer (lhog) built a working proof of concept in April 2026, 13
commits on top of `49fa150`. It is unmerged and about five months behind master.
What it contains:

- `rts/Rendering/Models/3DModelAnimation.hpp/.cpp`: `ModelAnimation::Map` stored on
  `S3DModel`. Per clip, per piece: a `TypedSequence` for translation (`float3`),
  rotation (`CQuaternion`) and uniform scale (`float`), each with keyframe times and
  Linear / Step / CubicSpline interpolation. `SampleSequence` samples a track at a time.
- `GLTFParser.cpp`: loads every clip, mapping each channel's node to a piece index.
- `CUnitScript`: an `EmbeddedAnimPlayer` per clip (time, speed, loop mode, weight,
  additive flag, per-piece weight mask, wait flag). `TickEmbeddedAnim` runs before the
  procedural anims each frame, blends all active clips (normalized weighted sum,
  quaternion nlerp with hemisphere correction, bind pose fills the remaining weight),
  converts the blended rotation to euler relative to the baked rest rotation and
  writes pos / rot / scale into the `LocalModelPiece`.
- **Coexistence rule (the key design decision, already made):** per piece per axis,
  a live COB/LUS Turn / Move / Spin / Scale owns that axis and the clip leaves it
  alone. New `RestoreTurn / RestoreMove / RestoreScale` ease a script-claimed axis
  back to the clip's pose (a NaN destination sentinel in `AnimInfo`). So a glTF walk
  cycle on the legs and a LUS `AimWeapon` turret turn run together.
- Lua (Lua unit scripts only): `Spring.UnitScript.PlayAnimation(name, {speed,
  loopMode|loop, weight, wait, additive}) -> id`, `StopAnimation`,
  `SetAnimationSpeed/Time/Weight/PieceWeights`, `GetAnimationTime/Duration/Id`,
  `IsAnimationPlaying`, plus the `AnimationFinished(animId, animName)` callin.
- creg registration for save/load; channel pointer cache and a per-piece claim bitmap
  for speed (the last commit is a performance pass).

Gaps in the prototype (things the port has to add):

1. **Keyframe axis conversion.** The branch predates PR #3321 and applied the Blender
   Z-up flip as a rotation on the synthetic root piece, so raw glTF keyframes were
   correct. Master bakes the conversion into piece data, so translation and rotation
   keyframes must go through `gltfmodel::ToEngineSpace` (swizzle the vector, conjugate
   the quaternion). Scale is unaffected. `GLTFParser.cpp` will conflict on rebase.
2. **Sync checksum.** `TickAllAnims` hashes `AnimInfo` entries only; `animPlayers`
   state should be folded into `checksum` so desyncs in clip playback are caught.
3. **Determinism.** `std::floor` in the loop wrap and any `acos` in slerp must use the
   engine's `math::` (streflop) versions.
4. No read API for gadgets and widgets, no COB access, no docs, no tests, no fade-in
   or fade-out on clip weights.

## 5. Recommended approach

Port `embedAnim` onto master and finish it, rather than designing from scratch. The
prototype's shape is what any clean design would arrive at anyway (asset-level clip
data, sim-level player inside the script object, per-axis arbitration), it already
answers the review questions raised on #2444, and finishing it keeps the door open to
upstreaming, which matters because a private engine fork is a long-term maintenance
cost.

Architecture decision to keep: the player state lives inside `CUnitScript`, not as a
separate component on `CUnit`. Rationale: `CUnitScript` already owns the script piece
list and the piece mapping (COB pieces are remapped by name, LUS is 1:1), the tick loop
and the sync checksum, and the Lua `activeScript` context that the callouts need. A
separate animator would duplicate all of that for no gain.

## 6. Work plan

### Phase 0. Stand up the Freecoil fork (see section 9)

Official Recoil ships no macOS binaries; the machine runs benbreen's Apple-silicon
fork through the BAR launcher. Freecoil is a fork assembled from three layers:
upstream master, the replayed macOS layer, and the animation layer. Deliverables,
all required before any animation code is considered verified:

1. A reproducible **macOS build** of `main` via the fork's `make engine`.
2. A reproducible **Windows build** of the same commit via upstream's Docker
   cross-build (`docker-build-v2/build.sh windows`), and a Linux build for headless
   sim tests. The macOS layer is `__APPLE__`-gated and must not change the Windows
   or Linux code paths; the Windows build is how that is proven, not assumed.
3. The Recoil Frenzy game repo running against the Mac build.

Freecoil is cross-platform only if a Mac client and a Windows client simulate
bit-identically. So the cross-platform sync gate (section 10) is part of the
definition of done for every phase that touches synced code, starting here with the
unmodified engine to establish the baseline.

### Phase 1. Port the prototype onto master

- `.gltf` (JSON + external buffers) and `.glb` (single binary container) are the same
  format and share one code path: both extensions register the same `CGLTFParser` in
  `IModelParser.cpp`, and `fastgltf::Parser::loadGltf` detects the container type from
  the bytes. Clip loading is added once, in `CGLTFParser::Load`, and applies to both.
  Only the metafile lookup differs in name (`<model>.glb.lua` vs `<model>.gltf.lua`).
- Cherry-pick `e9cf23c..c52ef97` (the 13 animation commits) onto `0fee554`.
- Resolve `GLTFParser.cpp` conflicts against PR #3321. Convert keyframes with
  `gltfmodel::ToEngineSpace` in the clip loader, using the same `sourceConvention` as
  the piece data. Cubic-spline tangents get the same conversion as values.
- Confirm the euler write-back still matches master's `ComposeTransform` order.

### Phase 2. Correctness and sync

- Hash `animPlayers` into the animation checksum in `TickAllAnims`.
- Replace non-streflop math in the tick and sampler.
- Verify creg save/load round-trips a mid-clip unit and that `wait` +
  `AnimationFinished` resumes a Lua thread.
- Add headless unit tests under `test/` for `SampleSequence` (all three interpolation
  modes) and for the blend / claim arbitration.
- Decide and document how `blockScriptAnims` (from `SetUnitPieceMatrix`) interacts
  with clips; simplest is that it blocks both.

### Phase 3. Renderer

- Fix the three-of-four bone blend loop in both GL4 shaders.
- Validate skinning with a real rigged Blender export, since upstream admits it was
  never tested. Check bounds: `LocalModel::UpdateBoundingVolume` already follows piece
  movement.
- Note the parser asserts uniform scale on nodes; rigs must not use non-uniform scale.

### Phase 4. API polish

- Keep the branch's `Spring.UnitScript.*` surface. Add clip weight fade-in / fade-out
  (a per-player ramp) since blending without fades looks bad on state changes.
- Add synced read functions (`Spring.GetUnitAnimationList`, `...AnimationState`) in
  `LuaSyncedRead.cpp` so gadgets and widgets can query without a script context.
  Gadgets can already drive playback via `Spring.UnitScript.CallAsUnit`.
- COB scripts get no clip access in the first cut; document that units using clips
  should use LUS scripts (Recoil Frenzy already does).
- Add Lua type definitions in `rts/Lua/library/` so the docs generator picks them up.

### Phase 5. Content pipeline and a test unit

- Extend `doc/site/.../blender-gltf-import` with a rigging section: armature as a node
  tree, one Blender Action per clip pushed to NLA tracks, export with animations and
  the "group by NLA track" option so clip names survive, uniform scale only, in-place
  walk cycles (no root motion support).
- One Recoil Frenzy unit with a rigged `.glb` and a LUS script that maps engine callins
  to clips: `StartMoving -> walk (loop)`, `StopMoving -> idle`, `FireWeapon -> attack
  (wait)`, `Killed -> death`. Keep its turret or weapon piece on procedural
  `AimWeapon` turns to exercise the coexistence rule.

### Phase 6. Upstream

- Open a PR against RecoilEngine referencing #2444 and coordinate with lhog. Even if
  the private fork ships first, upstream review is the cheapest way to catch
  determinism mistakes.

## 7. Files this touches

New or heavily changed:

- `rts/Rendering/Models/3DModelAnimation.hpp`, `.cpp` (new)
- `rts/Rendering/Models/3DModel.hpp` (owns `animationMap`)
- `rts/Rendering/Models/GLTFParser.cpp`, `.h`
- `rts/Sim/Units/Scripts/UnitScript.h`, `.cpp`
- `rts/Sim/Units/Scripts/LuaUnitScript.h`, `.cpp`, `LuaScriptNames.h`, `.cpp`
- `rts/Lua/LuaSyncedRead.cpp` (read API), `rts/Lua/library/` types
- `cont/base/springcontent/shaders/GLSL/ModelVertProgGL4.glsl`,
  `ShadowGenVertProgGL4.glsl`
- `doc/site/content/docs/guides/getting-started/blender-gltf-import/_index.md`
- `test/` new unit tests

Untouched: S3O, 3DO and COB paths, `LocalModelPiece`, the transform upload, the
Assimp parser (it could later populate the same clip table).

## 8. Risks and limits

- **Multiplayer determinism** is the risk that matters most. Every client must sample
  identical floats; keep all math in the engine's `math::` namespace and test with the
  two-client sync script already in the game repo.
- **Cost per unit per frame** is clips x pieces samples. The prototype's caches make
  this cheap, but a 60-bone rig on hundreds of units should be profiled.
- **SSBO slots** are two per piece per unit; a 60-bone rig uses about 122 transforms
  per unit. Fine, but larger than the 16-piece average the pools assume.
- **Skinning fidelity**: four influences, 8-bit weights, uniform scale only.
- **No root motion**; walk cycles must be authored in place.
- **Features (wrecks) do not tick scripts**, so no clip playback on features in this
  phase.
- **Legacy GL path** (display lists in `LocalModelPiece::Draw`) does not skin; only the
  GL4 path is supported. The Mac port runs GL4 via Zink, so this is fine here.
- **Licensing**: none of this changes the BAR model situation; those stay S3O + COB.

## 9. Fork strategy: Freecoil

Decision: build a named fork ("Freecoil", after the Death Knight's Death Coil) rather
than patch a binary. The GPL v2-or-later licence permits forking and renaming provided
the licence text, existing copyright notices and source availability are kept.

### What the macOS fork actually is

benbreen's `RecoilEngine-AppleSilicon` (branch `main`, v0.13, last push 2026-08-08)
is not a divergent engine. Its own `docs/MAINTENANCE.md` states the design: a thin,
rebasable patch series replayed onto an upstream release tag, with a written
version-bump procedure (branch from the new upstream tag, cherry-pick the layer,
resolve conflicts only at the macOS seams, re-run the sync gates). Measured against
upstream master on 2026-09-15:

| Fact | Value |
| --- | --- |
| Fork base (merge base with upstream) | upstream `9bec68d` (2026-07-31, the 2026.07 release prep) |
| Fork-only commits | 117 |
| Upstream commits the fork lacks | 89, including PR #3321 (glTF axis fix) that the animation port depends on |
| Fork files changed | 193, mostly `rts/System` (Mac platform layer), `rts/Rendering` (present path, GL shims), `patches/mesa`, `packaging` |
| Overlap with animation files | none: the fork does not touch `Rendering/Models`, `Units/Scripts` or the model shaders |
| Fork changes under `rts/Sim` | five small undefined-behaviour fixes (float-to-short truncation, `math::floor` semantics), enumerated in its `SYNC_VALIDATION.md` Appendix A |

Upstream files changed on both sides since the fork base, so the only expected
conflicts when replaying the macOS layer onto master: one-line UB fixes in
`LuaSyncedRead.cpp`, `LuaSyncedCtrl.cpp`, `LuaUnitScript.cpp`, `UnitScriptEngine.cpp`.
Trivial.

### Base choice

Base Freecoil on **upstream master** (or the next upstream release tag), and replay
the macOS layer onto it, exactly as the fork's own procedure prescribes. Do not base
on the fork's branch tip: it is 89 commits behind and lacks the glTF axis fix, and
building on top of it would mean carrying the fork's future rebases as merges of
merges.

### Branch model

```
upstream/master  (beyond-all-reason/RecoilEngine, tracked read-only)
   |
   +-- macos-layer          rebasable: the 117 fork commits, replayed
   |
   +-- feature/embedded-animation   rebasable: embedAnim port + fixes; also the upstream PR
   |
   `-- main  =  upstream pin + macos-layer + feature/embedded-animation + branding
```

Keep each layer rebasable and single-concern so a bump to the next upstream tag is
mechanical, and so the animation layer can be offered upstream independently of the
Mac work. Record the pinned upstream commit in a `docs/VERSIONS.md` like the fork's.

### Build on this Mac

The fork's `make engine` runs `scripts/build-engine.sh`, which first builds the pinned
Mesa Zink + KosmicKrisp driver (`scripts/build-mesa-kk.sh`, cached after the first
run) and then the engine against it. Prerequisites from the fork's README: Apple
silicon, macOS 26 or newer (KosmicKrisp needs Metal 4), Xcode Command Line Tools,
Homebrew; the script installs the rest, including an LLVM 19 toolchain built from
source for Mesa's CLC step. Expect the first build to take a long time; engine-only
rebuilds afterwards are a normal CMake incremental build. `make app` produces the
signed launcher bundle and is only needed for distribution.

### Determinism rules the animation layer inherits

The fork's golden rule is that nothing under `rts/Sim` changes behaviour except
enumerated UB fixes, because it must stay bit-identical to the BAR fleet. Freecoil
does not need fleet parity (Recoil Frenzy runs its own engine and servers), but it
does need all Freecoil clients to agree with each other, and the animation code is
new synced code under `rts/Sim`. So:

- Use `math::` (streflop) functions only; no `std::floor`, `std::fmod`, `acos` etc.
- No float-to-integer casts on values that can be out of range (the UB class the
  fork's audit found).
- Run the fork's streflop cross-architecture sync test and the game repo's two-client
  sync test after every animation change.

### Branding and licensing checklist

- Keep `COPYING`, `LICENSE`, `gpl-*.txt` and all copyright headers; add a Freecoil
  `NOTICE` stating it is a fork of Recoil (itself a Spring fork) and where the source
  lives. The fork's `packaging/NOTICE` is a good template.
- Replace the Recoil logo and icon files (`rts/RecoilEngine_*.png`, `.svg`,
  `installer/`) and the fork's packaging icons, which are BAR's artwork and are
  covered by BAR's no-reuse licence. Do not imply endorsement by Recoil or BAR.
- Death Knight logo: commission or draw original art. "Death Knight" and "Death Coil"
  are Warcraft names, so keep the mark to the word "Freecoil" plus original imagery,
  and do not copy Blizzard's art or use its names in the logo itself.
- The fork's "online play disabled" release gating exists because its builds join BAR
  public servers. Freecoil builds only ever talk to Freecoil clients, so that gate does
  not apply, but a Freecoil client must never advertise itself as a BAR-compatible
  engine version.

## 10. Cross-platform sync gate

Freecoil must run on macOS and Windows, and lockstep multiplayer means every client
must compute identical synced state regardless of platform or CPU architecture. One
differing bit desyncs the game. This gate is therefore mandatory, not optional:

1. **Build both**: the same commit built for macOS (arm64, Apple clang, the fork's
   streflop NEON path) and for Windows (x86-64, the upstream Docker cross-build).
2. **Streflop cross-architecture test**: the fork's `scripts/run-synctest.sh` must
   report bit-exact against the committed references on the Mac build.
3. **Cross-platform two-client sync test**: the game repo's two-client test run with
   one client on the Mac build and one on the Windows build (a Windows machine or VM
   on the LAN), with a scenario that exercises the changed feature. For animation
   work: units playing clips while moving, firing and dying, mixed with S3O+COB
   units. Both logs must be free of `sync error`, `desync` and `checksum mismatch`
   and the joiner must stay within a few hundred frames of the host.
4. **Replay determinism**: a demo recorded on one platform must replay with
   `REPLAY_SYNC_OK` on the other.

When to run it: at the end of Phase 0 on the unmodified engine (baseline), after
Phase 1 (port), after Phase 2 (sync fixes), and after any later change under
`rts/Sim`, synced Lua, streflop, or model loading. Record each run's result and the
commit it tested in `docs/freecoil/VERSIONS.md`.

Until a Windows machine is available, the Windows build still gets produced by the
Docker pipeline as a compile check, and the cross-platform test is listed as not run
rather than assumed to pass.
