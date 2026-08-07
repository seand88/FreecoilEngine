# Zink-on-Metal performance work — review guide

BAR on this stack went from 6.8 fps to 54.4 fps on a 2,162-unit battle (8.0×),
rendering pixel-identical output. Nothing below touches simulation math.

The stack is Recoil (OpenGL 4.6 compat) → Zink → KosmicKrisp → Metal. Most of
the wins came from the engine doing something that costs nothing on a native GL
driver and a lot on a translation layer. Two are driver patches.

Measurements are on an M2 Ultra unless stated. Cell names: "arena" is a
2,162-unit spawned battle; "long1" is a 45,000-frame late-game replay.

## Summary

| # | Change | Win | Where |
|---|--------|-----|-------|
| 1 | Stop enabling primitive restart on list topologies | 6.8 → 23.1 fps (3.4×) | [LuaVAOImpl.cpp](https://github.com/benbreen/RecoilEngine-AppleSilicon/blob/main/rts/Lua/LuaVAOImpl.cpp#L205-L220) |
| 2 | Present via GPU-pack PBO ring instead of a blocking readback | present 30 ms → 1.3 ms; 23.1 → 30.8 fps | [MetalPresent.mm](https://github.com/benbreen/RecoilEngine-AppleSilicon/blob/main/rts/System/Platform/Mac/MetalPresent.mm) |
| 3 | Move present off the render thread (nextDrawable pacing) | removed a hard 60 fps cap on a 120 Hz panel | [MetalPresent.mm#L410-L440](https://github.com/benbreen/RecoilEngine-AppleSilicon/blob/main/rts/System/Platform/Mac/MetalPresent.mm#L410-L440) |
| 4 | Deeper upload rings + blocking fence waits | removed ~10 ms/frame of `glClientWaitSync` spin | [ModelsDataUploader.cpp#L38-L50](https://github.com/benbreen/RecoilEngine-AppleSilicon/blob/main/rts/Rendering/ModelsDataUploader.cpp#L38-L50) |
| 5 | Fast shader math mode on the driver | 32.1 → 51.5 fps (+60%) | [patch 0012](https://github.com/benbreen/RecoilEngine-AppleSilicon/blob/main/patches/mesa/0012-kosmickrisp-KK_MATH_MODE-knob-safe-relaxed-fast.patch), [default set here](https://github.com/benbreen/RecoilEngine-AppleSilicon/blob/main/rts/System/Platform/Mac/MacPresentBackend.mm#L260-L270) |
| 6 | Present shader reads the mapped ring directly | +1.1–1.4 fps; min 40 → 59 on live scenes | [MetalPresent.mm#L500-L525](https://github.com/benbreen/RecoilEngine-AppleSilicon/blob/main/rts/System/Platform/Mac/MetalPresent.mm#L500-L525) |
| 7 | QoS for frame-critical threads | +1.2–1.3 fps; worst-case floor 13 → 17 fps | [ThreadPool.cpp#L30-L60](https://github.com/benbreen/RecoilEngine-AppleSilicon/blob/main/rts/System/Threading/ThreadPool.cpp#L30-L60) |
| 8 | Enable zink renderpass tracking for KosmicKrisp | +4.8% (M2 Air, long1) | [patch 0013](https://github.com/benbreen/RecoilEngine-AppleSilicon/blob/main/patches/mesa/0013-zink-enable-renderpass-tracking-for-kosmickrisp.patch) |
| 9 | Cap render density to the panel and a per-core pixel budget | ~31% fewer pixels on an M2 Air | [commit 93254b0](https://github.com/benbreen/RecoilEngine-AppleSilicon/commit/93254b0e09045a9a3571afe46ac1f4b58374ca1f) |

Link note: the port's history was squashed when it was published, so items 1–7
have no individual public commit. The links go to the shipped code; item 8 is a
patch file and item 9 is a real commit.

## 1. Primitive restart forced a compute prepass on 94% of draws

`LuaVAOImpl` enabled `GL_PRIMITIVE_RESTART` around every indexed draw,
including `Submit()`, which is hard-coded `GL_TRIANGLES` multi-draw-indirect.

Why that is free on desktop GL and expensive here: native drivers ignore
restart on list topologies. Metal's restart index is fixed all-ones, so a
Vulkan-on-Metal driver honouring `primitiveTopologyListRestart` has to unroll
the index buffer in a compute prepass — per draw. 94% of BAR's draws paid for a
feature that cannot affect a triangle list.

Fix: enable restart only for strip/loop/fan topologies. Engine and game meshes
never encode a sentinel in list index streams. `SPRING_LUAVAO_FORCE_RESTART=1`
restores the old behaviour.

**6.8 → 23.1 fps.** No-op on native drivers, so it should help ANGLE and other
portability stacks too. Upstream candidate.

## 2. Present-path readback serialized against the whole frame

Zink has no macOS window-system path, so the port presents by reading the
default framebuffer back and compositing to a `CAMetalLayer`. `SwapBuffers` was
~66% of a heavy frame (~114 ms mean swap in a 2,700-unit scene).

Why: any `glReadPixels` of the just-rendered frame falls back to a synchronous
CPU map that waits for the entire GPU pipeline to drain. The read is not slow
because of bandwidth; it is slow because of where it forces a sync point.

Fix, in layers: read into an IOSurface-backed `MTLTexture` (no CPU
intermediate, no CPU Y-flip — a one-triangle Metal pass flips during
compositing); route reads through a PBO ring on Mesa's GPU-pack path, which
compute-packs into a linear buffer that can be mapped without a GPU round-trip;
run it two frames deep.

**Present 30 ms → ~1.3 ms at 5120×2160; 23.1 → 30.8 fps.** The gating
requirements for the fast pack path (pack buffer bound, non-swizzling format
pair) are worth documenting upstream — they are easy to miss and the fallback
is silent.

## 3. nextDrawable paced light scenes to exactly half refresh

Early-game scenes sat at exactly 60 fps on a 120 Hz panel, with ~12 ms/frame
blocked inside `nextDrawable`.

Why: calling `nextDrawable` on the render thread paces an under-refresh
workload to refresh/2. `maximumDrawableCount = 3` does not change that — the
thread still blocks on the compositor.

Fix: present on a serial dispatch queue with a budget-2 semaphore and a
double-buffered IOSurface source. The main thread never waits on the
compositor; presents drop (never tear) when the compositor is two behind.

**The 60 fps cap disappeared and early game reached the panel limit.** This
pattern probably applies to any translation-layer present path on macOS, which
is why it is written up rather than just fixed.

## 4. Upload rings were sized for native completion latency

~10 ms/frame spinning in `glClientWaitSync` under `TransformsUploader::Update`
— about 30% of the main thread at 31 fps.

Why: upstream's triple-buffered persistent-mapped rings assume the GPU is ≤2
frames behind. Zink → KosmicKrisp → Metal legitimately runs deeper, so the ring
wrapped onto a slot the GPU still owned. The wait loop made it worse by using
1 ns `glClientWaitSync` timeouts — thousands of driver round-trips per frame
against an unsignaled fence.

Fix: ring depth is configurable, defaulting to 6 on macOS
(`SPRING_MAC_UPLOAD_BUFFERING`); waits use 250 µs blocking timeouts, which are
semantically identical and vastly cheaper. Left as knobs because the right
depth differs by GPU tier.

**The uploader wait left the profile entirely.**

## 5. Shader math mode

With the above fixed, fragment work dominated and the shader compiler reported
1,598 register-spill events in a 30 s trace.

Why: KosmicKrisp compiles MSL with `MTLMathModeSafe` and precise float
functions. That is the correct default for Vulkan conformance, but GL content
is written and tuned against native GL drivers, which effectively run fast
math. The content is not asking for that precision; it is paying for it.

Fix: a driver knob (`KK_MATH_MODE=safe|relaxed|fast`), which the engine
defaults to `fast` on macOS and the user can override. Shaders never feed the
synced simulation, so lockstep is unaffected.

**32.1 → 51.5 fps (+60%), screenshot-identical output.**

## 6. Direct present

After #2, the present still cost a per-frame `glMapBufferRange` plus a 44 MB
`memcpy` into an IOSurface (~1.5–2 ms at 5K), plus IOSurface locking.

Why it can be avoided: Apple GPUs are unified-memory. If the pack ring is
allocated with `ARB_buffer_storage` and persistently mapped on page-aligned
slots, each mapped pointer can be wrapped once as an `MTLBuffer`
(`newBufferWithBytesNoCopy`) and sampled by the present fragment shader. The
copy existed only to hand the data to Metal, and it did not need to.

Slot reuse is fenced, and that fence doubles as pipeline backpressure. An
earlier version that skipped presents when the GPU ran behind reported high
"rendered" fps with a stale display, so it was rejected — worth knowing if you
try the same thing. `MacPresentDirect=0` falls back.

**+1.1–1.4 fps de-trended on a main-thread-bound late-game cell** (n=10
overnight ABAB, zero sign flips, 4–7× the 0.3 fps noise floor), with larger
tail gains on live scenes: min 40 → 59, light frames 77 → 114. Neutral when the
GPU is the limiter.

## 7. Thread QoS

Worst-case frame dips in sim-heavy scenes.

Why: macOS has no thread affinity, and child threads do not inherit QoS
promotion, so ThreadPool workers ran at `QOS_CLASS_DEFAULT` and the scheduler
was free to place them on efficiency cores. In a parallel-for, the slowest
worker gates the group, so one E-core placement sets the frame time.

Fix: sync-pool workers request `QOS_CLASS_USER_INITIATED` (async pool stays
default); the Metal present queue is `QOS_CLASS_USER_INTERACTIVE`. Promotions
are logged at startup.

**+1.2–1.3 fps de-trended on the sim-bound cell, worst-case floor 13–14 →
17–18 fps (~+30%).** Applying the same treatment to Mesa's internal queues
measured flat, so it was dropped — promote only what measures.

## 8. Renderpass tracking was off for KosmicKrisp

Zink keeps a list of tile-based drivers that benefit from renderpass
optimization. KosmicKrisp is tile-based and was not on it — the only tiler
omitted.

Why it costs: without tracking, zink cannot coalesce the load/store actions of
adjacent color-only and color+depth passes, and on a TBDR GPU each boundary is
a full-resolution tile store and reload.

Fix: add `KOSMICKRISP` to the list. Same code path already validated on
Honeykrisp and turnip, and equivalent to `ZINK_DEBUG=rp`.

**Render-encoder round-trips ~20 → ~11.5 per frame, submits 44 → 28/s, +4.8%
on the M2 Air long1 cell** (interleaved n=3/arm, clean separation). Output
byte-identical. This one is a clean upstream MR.

## 9. Render density cap

Scaled-desktop Retina made the engine render the full oversized backing — on an
M2 Air, 2940×1912 for a 2560×1664 panel, 31% more pixels than the panel can
show, which the window server then downsamples.

Fix: cap render density at physical panel-native and at a ~0.6 MP per GPU core
budget. Window points and configured resolutions are untouched; only render
density changes. `SPRING_MAC_FULL_BACKING=1` restores the raw scale.

**~31% fewer pixels on an M2 Air.** I have not A/B'd this one as an fps number
— it is arithmetic plus a GPU-bound machine, not a measurement.

## What is left

- **True zero-copy present.** Render the engine's FBO directly into the
  IOSurface Metal samples, so there is no readback at all. Needs
  `VK_EXT_external_memory_metal` to grow IOSurface/MTLTexture handle support in
  KosmicKrisp, plus a Zink consumer for the resulting VkImage. Roughly a month
  of upstream work.
- **Late-game ceiling.** At ~44 fps late-game the main thread is ~38% synced
  sim + game Lua and ~21% Lua widgets. What is left is engine draw-thread
  decoupling or game-side work, not driver-side. Profiles available.
- **`primitiveTopologyListRestart` cost cliff** (§1). Whether advertising the
  feature is worth a 10–100× per-draw penalty for clients that leave restart
  enabled is a real upstream question. The KosmicKrisp code comments show the
  authors anticipated exactly this client behaviour.

Method, determinism testing and the full change list are in
[IMPROVEMENTS.md](IMPROVEMENTS.md) and [SYNC_VALIDATION.md](SYNC_VALIDATION.md).
