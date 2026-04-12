# Theme Pool Manual Verification — 2026-04-12

Feature branch: `theme-pool`
Code tasks 1-9 completed and tested via `zig build test -Dtest-filter="theme"` (exit 0).

The automated test suite covers:
- Config parsing of `theme-pool` (single, light/dark pair, accumulation, reset)
- Mutual-clear between `theme` and `theme-pool` (all orderings, interleaved case)
- `loadTheme` pool resolution with clamp-to-last-valid + debug log
- `changeConditionalState` switching between slots (end-to-end replay test)
- `ThemeSlotDispenser` shuffle invariants (every slot visited once before repeats, reshuffle on exhaustion, reshuffle on pool size change)

The manual verification below is the only coverage gap for the full Surface→renderer path.

## Prerequisites

- Full macOS build: `zig build` from repo root (requires Xcode 26 with `xcode-select --switch /Applications/Xcode.app`)
- Launch via: `open zig-out/macos-app/Debug/Ghostty.app` (or wherever the build produces the bundle)

## Test configs

Two pre-written test config files:

- `/tmp/ghostty-theme-pool-test.conf` — 5-slot flat pool (Dracula, Nord, Gruvbox Dark, TokyoNight, Solarized Dark - Patched)
- `/tmp/ghostty-theme-pool-light-dark.conf` — 2-slot pool with light/dark pairs (Gruvbox, TokyoNight)

## Verification Steps

### Step 1 — Distinct themes across multiple surfaces

1. Launch Ghostty with `--config-file=/tmp/ghostty-theme-pool-test.conf`
2. Open 5 new surfaces (Cmd+N / Cmd+T / Cmd+D in any combination)
3. Observe: all 5 surfaces should be visibly different themes (one per slot, shuffled order)
4. Open a 6th surface — the dispenser reshuffles and picks one of the 5 again
5. After 10 surfaces total, every slot should have been seen at least twice

**Expected:** ✅ distinct themes, shuffle covers the pool before repeating, no crashes
**Result:** _PASS / FAIL_
**Notes:** _

### Step 2 — Light/dark stickiness

1. Relaunch Ghostty with `--config-file=/tmp/ghostty-theme-pool-light-dark.conf`
2. Open 2 new surfaces — one should pick slot 0 (Gruvbox), one slot 1 (TokyoNight)
3. Toggle macOS system appearance: System Settings → Appearance → Light/Dark
4. Observe: each surface stays on *its* slot's other mode (Gruvbox Light ↔ Gruvbox Dark, TokyoNight Day ↔ TokyoNight Night)
5. Do NOT let the surfaces swap slots — slot identity is sticky

**Expected:** ✅ each surface keeps its slot, light/dark flips within the slot
**Result:** _PASS / FAIL_
**Notes:** _

### Step 3 — Out-of-range clamp with config reload

1. With 3+ surfaces open using the 5-slot pool from Step 1, the surfaces have slots 0..4 distributed among them
2. Edit `/tmp/ghostty-theme-pool-test.conf` to remove 3 slots (leave only 2: Dracula + Nord)
3. Reload config via Cmd+Shift+, on macOS, or send SIGUSR2 to the process on Linux
4. Observe:
   - Surfaces that had slot 0 or 1 are unchanged
   - Surfaces that had slot 2, 3, or 4 now show slot 1 (last valid — clamp fallback)
   - No crashes
5. Check the log for clamp debug messages: on macOS, `sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"' | grep theme_slot`
   - Expect entries like: `theme_slot 3 out of range (pool size 2), falling back to slot 1`

**Expected:** ✅ clamped surfaces render to slot 1; debug log present
**Result:** _PASS / FAIL_
**Notes:** _

### Step 4 — CLI override clears pool

1. Launch Ghostty with `--config-file=/tmp/ghostty-theme-pool-test.conf --theme=Nord`
2. Open several new surfaces
3. Observe: ALL surfaces use Nord (not the pool). The CLI `--theme=Nord` is parsed after the config file, and the `resolveThemeVsThemePool` helper clears the pool because `theme=` was the most-recently-assigned key

**Expected:** ✅ all surfaces use Nord, pool is ignored
**Result:** _PASS / FAIL_
**Notes:** _

## Summary

- Step 1 (distinct themes across 6+ surfaces): _PASS / FAIL_
- Step 2 (light/dark stickiness): _PASS / FAIL_
- Step 3 (out-of-range clamp + debug log): _PASS / FAIL_
- Step 4 (CLI override clears pool): _PASS / FAIL_

**Overall:** _PASS / FAIL_

**Verifier notes:**
_Fill in any observations, edge cases encountered, or issues to fix before merge._
