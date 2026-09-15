# Freecoil pinned versions

| Layer | Pin | Notes |
| --- | --- | --- |
| Upstream engine | `beyond-all-reason/RecoilEngine` master `0fee554` (2026-09-15, PR #3321) | Branch `main` is this pin + the two layers below |
| macOS layer | `benbreen/RecoilEngine-AppleSilicon` main `a49a8ecc` (v0.13, 2026-08-08), replayed as branch `macos-layer` | 117 commits replayed, 5 dropped as already upstream, 1 dropped as superseded by upstream #3289 (views::enumerate compat) |
| Animation layer | `beyond-all-reason/RecoilEngine` branch `embedAnim` head `c52ef97` (2026-04-08, issue #2444), replayed as branch `feature/embedded-animation` | 13 prototype commits + 2 Freecoil fixes (keyframe axis conversion, checksum + streflop floor) |
| pr-downloader submodule | ExaDev fork `e6510b3d` (macOS HTTP/1.1 fix) | Upstream moved to `185cfba7` (#3236); follow-up: rebase the ExaDev fix onto it |
| BARb submodule | rlcevg/CircuitAI `7b9339da` (AppleClang/arm64 fixes) | Upstream pin `f4a6ca3a` is 23 commits newer but lacks the arm64 fix; follow-up: rebase the fix. Not needed by Recoil Frenzy |

## Conflict resolutions made while replaying the macOS layer

| Commit | Resolution |
| --- | --- |
| testMutex.cpp (Platform/Mac files) | upstream structure (`lock` type, OpenBSD futex) + Apple `os_unfair_lock` branch; futex syscall helper excluded on Apple |
| float->short UB sweep (synced) | upstream's `FloatToHeading` kept at the two sites upstream fixed in #3342; fork's defined-truncation casts kept at the four sites upstream did not touch |
| SDL audio device add/remove | upstream #3340 logic kept; fork's "ignore capture devices" guard kept in the event handler |
| Cmd+Q guard | fork's double-press guard kept, falls through to upstream's `RequestQuit()` so the Lua `AllowQuit` veto still applies |
| RangesCompat.h | upstream #3289 header kept, fork commit dropped |
