# AGENTS.md — Freecoil (Recoil engine fork with glTF skeletal animation)

This directory holds the engine fork work. `RecoilEngine/` is the engine source (a
clone of `beyond-all-reason/RecoilEngine`; its own `AGENTS.md` covers upstream build
commands). `PLAN.md` is the design and phased plan. The game that consumes this
engine is the sibling repo `../recoil_frenzy2`.

## Rule 1: deterministic networked simulation is the most important property

Recoil is a lockstep engine. Every client runs the full simulation and only inputs are
sent over the network. If any two clients compute one different bit in synced state,
the game desyncs and is unplayable. Nothing else we build matters if this breaks.

**Every change must be checked for determinism before it is considered done.** This
is not optional and not deferred to "later". A change is not complete until the
checks below have been run and reported.

### What counts as synced code

- Everything under `RecoilEngine/rts/Sim/`, including `Sim/Units/Scripts/` where the
  animation player lives.
- Synced Lua bindings: `rts/Lua/LuaSynced*.cpp`, `LuaUnitScript.cpp`, `LuaHandleSynced`.
- Model loading that feeds sim state: `rts/Rendering/Models/*Parser*.cpp`,
  `ModelUtils.cpp`, `3DModelPiece.cpp`, `LocalModelPiece.cpp`, and the new
  `3DModelAnimation.*`. Piece offsets, bind poses, collision volumes and animation
  keyframes are read by the simulation, so the loader must produce bit-identical
  output on every client. (The glTF parser already avoids fastgltf's
  `DecomposeNodeMatrices` option for this reason.)
- `rts/lib/streflop/` and anything that changes float semantics or compiler flags.

### Rules for writing synced code

1. Use the engine's `math::` (streflop) functions only. Never `std::floor`,
   `std::fmod`, `std::sin`, `acos`, `sqrt` etc. in synced code.
2. No float-to-integer casts on values that can be out of range; that is undefined
   behaviour and x86 and arm64 disagree. Clamp first or use the engine's defined
   truncation helpers.
3. No wall-clock time, no thread-ordering dependence, no unordered container
   iteration order leaking into results, no uninitialised memory.
4. Any new per-unit animation state must be hashed into the animation checksum in
   `CUnitScript::TickAllAnims` so the engine's sync check can catch it.
5. Keep synced changes small and single-concern so they can be reviewed for this.

### Checks that must run after every change touching synced code

1. **Engine sync test**: the fork's streflop cross-architecture test
   (`scripts/run-synctest.sh` once the macOS layer is in place; it must report
   bit-exact against the committed references).
2. **Two-client sync test in the game repo**: `make sync-test` in `../recoil_frenzy2`
   launches a host and a joiner on this machine and greps both logs for
   `sync error`, `desync` and `checksum mismatch`. It must pass with the new engine
   binary, and the test scenario must exercise the changed feature (for animation
   work: units playing clips while moving and firing).
3. **Replay determinism** when available: record a demo and confirm the fork's
   replay check reports `REPLAY_SYNC_OK`.
4. **Cross-platform sync gate**: Freecoil targets macOS and Windows, and a Mac
   client and a Windows client must simulate bit-identically. Build the same commit
   for both (fork `make engine` for macOS, upstream `docker-build-v2/build.sh
   windows` for Windows) and run the two-client sync test with one client on each.
   If no Windows machine is available, still produce the Windows build as a compile
   check and report the cross-platform test as NOT RUN, never as passed. Details in
   `PLAN.md` section 10.
5. **Report the result explicitly.** State which checks ran and their output. If a
   check could not be run, say so; do not report the change as done.

If a conflict during a rebase or merge forces a change under `rts/Sim/` or streflop,
stop and treat it as a determinism risk to be reviewed, not a merge chore.

## Rule 2: keep the fork rebasable

Freecoil is three rebasable layers on an upstream pin: upstream master, the replayed
macOS layer from `benbreen/RecoilEngine-AppleSilicon`, and the animation layer. Keep
commits single-concern and on the right layer. Record the upstream pin in
`docs/VERSIONS.md`. See `PLAN.md` section 9.

## Rule 3: existing animation must keep working

S3O models with COB and Lua unit scripts (all of the BAR imports in the game) are the
regression baseline. Any change to piece animation must be verified against a unit
with no clips as well as one with clips.
