# Theme Pool — Per-Surface Random Theme Selection

**Date:** 2026-04-12
**Status:** Design approved, ready for implementation planning

## Summary

Ghostty users today can pick a single theme, optionally paired for light/dark mode (`theme = light:rose-pine-dawn,dark:rose-pine`). This spec adds a `theme-pool` config key that accepts a list of themes. When the pool is non-empty, every new **surface** (window, tab, or split) draws a random theme from the pool. Selection is "random without repeats" — every slot is visited once before any repeat — and each surface's slot assignment is sticky across config reload and system light↔dark switches.

## Motivation

Distinguishing many open terminals at a glance is hard. Letting each new surface pick its own theme gives users visual variety and immediate identification of which tab/window/split is which, without requiring per-surface manual configuration.

## Design Decisions

The following decisions were made during brainstorming and lock in the spec's scope.

| Question | Decision |
|---|---|
| Scope of "new surface" | Every surface — windows, tabs, *and* splits. |
| Selection strategy | Random without repeats; reshuffle when exhausted. |
| Config syntax | New repeatable `theme-pool` key; existing `theme` stays scalar and unchanged. |
| Mutual precedence | `theme` and `theme-pool` mutually clear each other. Load-order last-wins. |
| Persistence of surface's slot | Sticky across config reload and light/dark switch. Out-of-range slot clamps to last valid. |
| Shuffle scope | One dispenser per `App` instance — splits consume slots from the same queue as windows/tabs. |
| CLI override | `ghostty --theme=X` naturally clears any config-file pool (CLI is parsed after config files, and `theme` clears `theme-pool`). |

## Architecture

Ghostty already derives a per-surface config from a shared template via `Config.changeConditionalState` (src/Surface.zig:477). Each surface holds its own `config_conditional_state` (src/Surface.zig:621), and the conditional-state struct in `src/config/conditional.zig` is explicitly designed to grow. We extend it with a new `theme_slot: u16` field.

At surface creation, the `App` draws a slot index from a shuffle queue and injects it into the surface's conditional state before `changeConditionalState` runs. The existing replay/finalize machinery then loads the correct theme file for `(theme, theme_slot)`. Nothing else in the rendering, IO, or apprt layers needs to change — theme data continues to flow through `DerivedConfig` and the renderer uniforms exactly as today.

One shuffle queue lives on the `App` instance. When the pool size changes or the queue is exhausted, it reshuffles. Randomness is seeded from `std.crypto.random` at app init; no persistence across process restart.

## Data Model

### Config keys (src/config/Config.zig)

```zig
// Existing — unchanged
theme: ?Theme = null,

// New repeatable key
@"theme-pool": ThemePool = .{},
```

### `ThemePool` type

```zig
pub const ThemePool = struct {
    slots: std.ArrayListUnmanaged(Theme) = .{},

    pub fn parseCLI(
        self: *ThemePool,
        alloc: Allocator,
        input: ?[]const u8,
    ) !void {
        // Empty value resets the list (Ghostty idiom for repeatables).
        if (input == null or input.?.len == 0) {
            self.slots.clearRetainingCapacity();
            return;
        }
        // Per-slot parsing reuses existing Theme.parseCLI syntax
        // (single name OR light:X,dark:Y pair).
        var slot: Theme = undefined;
        try slot.parseCLI(alloc, input);
        try self.slots.append(alloc, slot);
    }

    // Standard clone/equal/deinit as Ghostty config convention requires.
};
```

Each slot is a `Theme` struct `{light: []const u8, dark: []const u8}`. A solo-theme slot just has both fields equal to the same name — same as today's scalar `Theme` for single-name inputs.

### Mutual-clear semantics

`theme` and `theme-pool` cannot cleanly clear each other from inside field-level `parseCLI` methods — those methods only see their own field, not the parent `Config`. Instead, mutual clearing happens in `Config.finalize()`:

1. After all replay steps have run, check whether both `self.theme != null` *and* `self.@"theme-pool".slots.len > 0`.
2. If both are set, scan `self._replay_steps.items` from the end and find the most recent `.arg` step whose argument starts with either `theme=` / `--theme=` or `theme-pool=` / `--theme-pool=`.
3. That latest step wins. The loser is cleared: either `self.theme = null` or `self.@"theme-pool".slots.clearRetainingCapacity()`.

An empty-value reset on `theme-pool` (`theme-pool =` alone) does not trigger mutual clearing, since it leaves the pool empty — there is nothing to reconcile with a set scalar.

This gives natural last-wins behavior across all load sources (defaults, config file, CLI, recursive config-file) without needing source-tracking metadata, because `_replay_steps` preserves chronological order.

### Conditional state (src/config/conditional.zig)

```zig
pub const State = struct {
    theme: Theme = .light,
    os: std.Target.Os.Tag = builtin.target.os.tag,
    theme_slot: u16 = 0,   // NEW — index into theme-pool.slots

    pub const Theme = enum { light, dark };
};
```

The existing `State.match` implementation uses `inline else` with `@tagName(raw)`, which only works for enum fields. Since `theme_slot` is an integer, `match` needs a small extension to format integer fields as strings before comparing against the `Conditional.value` string. The implementation is shown in the "`State.match` extension" subsection below.

### Slot-dispenser state (src/App.zig)

```zig
pub const ThemeSlotDispenser = struct {
    queue: std.ArrayListUnmanaged(u16) = .{},
    cursor: usize = 0,
    pool_len: u16 = 0,
    rng: std.Random.DefaultPrng,

    pub fn init() ThemeSlotDispenser {
        return .{
            .rng = std.Random.DefaultPrng.init(std.crypto.random.int(u64)),
        };
    }

    pub fn deinit(self: *ThemeSlotDispenser, alloc: Allocator) void {
        self.queue.deinit(alloc);
    }

    /// Returns the next slot index. For pool_len <= 1, always returns 0
    /// (no shuffle, no allocation).
    pub fn next(self: *ThemeSlotDispenser, alloc: Allocator, pool_len: u16) !u16 {
        if (pool_len <= 1) return 0;
        if (self.pool_len != pool_len or self.cursor >= self.queue.items.len) {
            try self.reshuffle(alloc, pool_len);
        }
        const slot = self.queue.items[self.cursor];
        self.cursor += 1;
        return slot;
    }

    fn reshuffle(self: *ThemeSlotDispenser, alloc: Allocator, pool_len: u16) !void {
        self.queue.clearRetainingCapacity();
        try self.queue.ensureTotalCapacity(alloc, pool_len);
        var i: u16 = 0;
        while (i < pool_len) : (i += 1) self.queue.appendAssumeCapacity(i);
        std.Random.shuffle(self.rng.random(), u16, self.queue.items);
        self.cursor = 0;
        self.pool_len = pool_len;
    }
};
```

## Data Flow

### Surface creation (src/Surface.zig:467-493)

Current code:

```zig
pub fn init(
    self: *Surface,
    alloc: Allocator,
    config_original: *const configpkg.Config,
    app: *App,
    // ...
) !void {
    var config_: ?configpkg.Config = config_original.changeConditionalState(
        app.config_conditional_state,
    ) catch |err| err: { ... };
    // ...
    self.* = .{
        // ...
        .config_conditional_state = app.config_conditional_state,
    };
}
```

Modified code:

```zig
pub fn init(
    self: *Surface,
    alloc: Allocator,
    config_original: *const configpkg.Config,
    app: *App,
    // ...
) !void {
    // Draw a slot from the app's dispenser for this surface.
    const pool_len: u16 = @intCast(
        config_original.@"theme-pool".slots.items.len,
    );
    const slot = try app.theme_dispenser.next(alloc, pool_len);

    // Build this surface's conditional state: inherit app-wide state,
    // override theme_slot.
    var surface_state = app.config_conditional_state;
    surface_state.theme_slot = slot;

    var config_: ?configpkg.Config = config_original.changeConditionalState(
        surface_state,
    ) catch |err| err: { ... };
    // ...
    self.* = .{
        // ...
        .config_conditional_state = surface_state,
    };
}
```

### Theme resolution (src/config/Config.zig:4393 `loadTheme`)

Current:

```zig
fn loadTheme(self: *Config, theme: Theme) !void {
    const name: []const u8 = switch (self._conditional_state.theme) {
        .light => theme.light,
        .dark => theme.dark,
    };
    // ... open file, replay, tag args as conditional
}
```

Modified:

```zig
fn loadTheme(self: *Config) !void {
    // Pick which Theme struct to load: pool slot if pool is non-empty,
    // else scalar theme.
    const theme: Theme = theme: {
        if (self.@"theme-pool".slots.items.len > 0) {
            const max_slot = self.@"theme-pool".slots.items.len - 1;
            const requested = self._conditional_state.theme_slot;
            const slot_idx = @min(requested, max_slot);
            if (requested > max_slot) {
                log.debug(
                    "theme_slot {d} out of range (pool size {d}), " ++
                    "falling back to slot {d}",
                    .{ requested, self.@"theme-pool".slots.items.len, slot_idx },
                );
            }
            break :theme self.@"theme-pool".slots.items[slot_idx];
        }
        if (self.theme) |t| break :theme t;
        return;
    };

    const name: []const u8 = switch (self._conditional_state.theme) {
        .light => theme.light,
        .dark => theme.dark,
    };
    // ... rest unchanged: open file, replay, tag args as conditional
}
```

The caller in `finalize()` that currently passes `self.theme.?` as an argument is updated to call `self.loadTheme()` without the argument, since `loadTheme` now resolves the theme itself.

### Conditional replay tagging

The existing loop (Config.zig:4438-4465) tags each replayed theme arg with a single `Conditional{ key: .theme, op: .eq, value: "light"|"dark" }`. With a pool, a replayed arg from slot N in light mode needs **two AND-ed conditions**:

1. `theme == light` (or dark)
2. `theme_slot == N`

The `conditional_arg` struct already supports a `conditions: []Conditional` array, so we extend the tagging loop to emit both predicates when `theme-pool` is non-empty:

```zig
// Change our arg to be conditional on both theme AND theme_slot.
.arg => |v| {
    const alloc_arena = new_config._arena.?.allocator();
    const using_pool = self.@"theme-pool".slots.items.len > 0;
    const conds = try alloc_arena.alloc(
        Conditional,
        if (using_pool) 2 else 1,
    );
    conds[0] = .{
        .key = .theme,
        .op = .eq,
        .value = @tagName(self._conditional_state.theme),
    };
    if (using_pool) {
        conds[1] = .{
            .key = .theme_slot,
            .op = .eq,
            .value = try std.fmt.allocPrint(
                alloc_arena,
                "{d}",
                .{self._conditional_state.theme_slot},
            ),
        };
    }
    item.* = .{ .conditional_arg = .{
        .conditions = conds,
        .arg = v,
    } };
},
```

The existing `conditional_arg` branch that already handles multi-condition args needs the same extension.

### `State.match` extension

The current match logic uses `@tagName` which only works for enum fields. For `theme_slot: u16`, we need to format the integer as a string. Extending match:

```zig
pub fn match(self: State, cond: Conditional) bool {
    switch (cond.key) {
        inline else => |tag| {
            const raw = @field(self, @tagName(tag));
            const FieldType = @TypeOf(raw);

            // Format raw to a string buffer for comparison.
            var buf: [32]u8 = undefined;
            const value: []const u8 = switch (@typeInfo(FieldType)) {
                .@"enum" => @tagName(raw),
                .int => std.fmt.bufPrint(&buf, "{d}", .{raw}) catch return false,
                else => @compileError(
                    "unsupported conditional state field type: " ++
                    @typeName(FieldType),
                ),
            };

            return switch (cond.op) {
                .eq => std.mem.eql(u8, value, cond.value),
                .ne => !std.mem.eql(u8, value, cond.value),
            };
        },
    }
}
```

## Error Handling

| Case | Behavior |
|---|---|
| Empty pool and scalar `theme` unset | No theme loaded; built-in defaults apply. Unchanged from today. |
| Pool with one slot | `dispenser.next()` returns 0; no allocation, no shuffle. Behaviorally identical to a scalar `theme`. |
| Slot points to a missing theme file | `themepkg.open` appends a diagnostic; built-in defaults apply for that surface. Same as today's scalar behavior. |
| Malformed per-slot syntax | `Theme.parseCLI` appends a diagnostic; bad slot is skipped; other slots still loaded. |
| Config reload shrinks pool; surface's slot is now out of range | `loadTheme` clamps to last valid slot via `@min`. Debug log emitted. |
| Config reload grows pool | Existing surfaces keep their current slot. New surfaces draw from the freshly-reshuffled queue. |
| User sets `theme` and `theme-pool` in the same file | Whichever appears later wins (mutual clear at parse time). |
| CLI `--theme=X` + config-file `theme-pool` | CLI parsed after config files → clears pool → scalar wins. All surfaces get X. |
| CLI `--theme-pool= --theme-pool=X` | Empty value resets; X is the only slot. |

**Deliberately not handled:**

- No automatic retry/re-roll when a slot's theme file is missing — opens a rat hole (what if all slots are broken?). User fixes the config.
- No persistence of shuffle queue across process restart — fresh shuffle each launch.
- No keybind or action to manually re-roll a surface's theme — can add later if demand exists (YAGNI).

## Testing

Follows Ghostty's convention of colocated Zig test blocks. Run with `zig build test -Dtest-filter=<name>`.

### `src/config/Config.zig` (existing theme test block)

1. `test "theme-pool parses single entry"` — `theme-pool = nord` yields one slot with both fields = `"nord"`.
2. `test "theme-pool parses light/dark pair"` — `theme-pool = light:rose-pine-dawn,dark:rose-pine` yields one slot with distinct fields.
3. `test "theme-pool accumulates across repeated lines"` — three lines yield `slots.len == 3` in order.
4. `test "theme-pool empty value resets"` — after two appends, `theme-pool =` clears the list.
5. `test "theme clears theme-pool"` — set pool, then scalar → pool empty after parse.
6. `test "theme-pool clears theme"` — set scalar, then pool → scalar null after parse.
7. `test "empty theme-pool does not clear theme"` — set scalar, then `theme-pool =` → scalar remains.
8. `test "CLI theme overrides config pool"` — simulate file-loaded pool + CLI `--theme=X`; assert pool empty, scalar set.
9. `test "loadTheme uses slot when pool set"` — pool with 2 slots, `_conditional_state.theme_slot = 1`; assert resolved theme's distinguishing config value matches slot 1.
10. `test "loadTheme clamps out-of-range slot"` — pool with 2 slots, `theme_slot = 5`; assert resolved to slot 1.
11. `test "changeConditionalState reloads on theme_slot change"` — start slot 0, switch to slot 1; verify config's background (or other theme-specific field) matches slot 1.
12. `test "changeConditionalState reloads on theme_slot + theme mode together"` — flip both `theme_slot` and light/dark in one call; verify correct file loaded.
13. `test "single-slot pool equivalent to scalar"` — pool with one slot and `theme_slot = 0`; assert resolved state matches setting the same theme as scalar.

### `src/config/testdata/` fixtures

Three new theme files with distinguishing values:
- `theme_pool_a` — sets `background = #aa0000`
- `theme_pool_b` — sets `background = #00bb00`
- `theme_pool_c` — sets `background = #0000cc`

### `src/config/conditional.zig`

14. `test "State.match handles theme_slot"` — state with `theme_slot = 2` matches `Conditional{ key: .theme_slot, op: .eq, value: "2" }` and does not match `value: "3"`.

### `src/App.zig` (new test block for `ThemeSlotDispenser`)

15. `test "ThemeSlotDispenser returns 0 for empty pool"` — `next(alloc, 0)` → 0, no allocation.
16. `test "ThemeSlotDispenser returns 0 for single-slot pool"` — `next(alloc, 1)` → 0.
17. `test "ThemeSlotDispenser visits every slot before repeating"` — pool of 4; call `next` 4 times; assert results are a permutation of `{0,1,2,3}`.
18. `test "ThemeSlotDispenser reshuffles when queue exhausted"` — pool of 3; call `next` 4 times; assert 4th call does not panic and cursor reset correctly.
19. `test "ThemeSlotDispenser reshuffles on pool size change"` — pool of 3, draw twice; switch to pool of 5; next call should have `pool_len = 5` internally and continue serving from a new queue.

### Manual integration verification (documented in plan, not automated)

- Build debug Ghostty with a config containing `theme-pool = dracula`, `theme-pool = nord`, `theme-pool = solarized-dark`. Open 6 surfaces; visually confirm every slot is seen once before repeats start.
- With a `light:X,dark:Y` pool, toggle system appearance; confirm each surface keeps its slot and swaps modes.
- Reload config with a shrunk pool; confirm clamped surfaces re-render and debug log is emitted.
- Run `ghostty --theme=nord` with a pool in config; confirm nord wins and all surfaces use it.

## Files Affected

**Created:**
- `src/config/testdata/theme_pool_a`
- `src/config/testdata/theme_pool_b`
- `src/config/testdata/theme_pool_c`

**Modified:**
- `src/config/Config.zig` — add `@"theme-pool"` field, `ThemePool` struct, update `loadTheme`, update `Theme.parseCLI` to clear pool, update conditional replay tagging. Add new tests.
- `src/config/conditional.zig` — add `theme_slot: u16` to `State`, extend `match` to handle integer fields. Add new test.
- `src/App.zig` — add `ThemeSlotDispenser` struct, add `theme_dispenser` field to `App`, init and deinit. Add new tests.
- `src/Surface.zig` — draw slot in `Surface.init`, inject into surface's conditional state before calling `changeConditionalState`.

**Untouched:** renderer, apprt (gtk, embedded, macos), termio, font. All theme data flows through existing mechanisms.

## Out of Scope

- UI for theme selection (CLI/config only, consistent with today).
- Persistence of slot assignments across process restart.
- Per-surface "re-roll" command / keybind.
- Changes to the existing `+list-themes` CLI.
- Documentation rewrites beyond adding `theme-pool` to the config reference.

## Open Questions

None at design time. All design decisions were resolved during brainstorming.
