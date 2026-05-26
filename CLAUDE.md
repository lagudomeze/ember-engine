# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
zig build                          # Linux debug build
zig build -Doptimize=ReleaseFast   # Release build
zig build run                      # Build and run
zig build test                     # Run all 77 unit tests (src/tests.zig)
zig build test 2>&1 | grep FAIL    # See only failures

# Cross-compile for Windows (requires ./download_deps.sh first)
./download_deps.sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

Output: `zig-out/bin/ember-engine` (Linux) / `zig-out/bin/ember-engine.exe` + `SDL2.dll` (Windows).

## Architecture

### Plugin System (Compile-Time Fusion)

Each file in `src/plugins/` exports a `pub const manifest: PluginManifest` with components, systems, and events. `main.zig` collects all manifests into the `ALL_PLUGINS` tuple, and `PluginRegistry.collect()` generates a `SystemTable` at **comptime** — all system dispatch is zero-cost static dispatch with no vtables or string lookups.

To add a new plugin:
1. Create `src/plugins/core_xxx.zig` exporting `pub const manifest`
2. Import it in `src/main.zig` and add to `ALL_PLUGINS` tuple
3. Add component storage registration in `main.zig`'s `registerAllStorages()`
4. Assign unique component type IDs (firemage uses 0-8, stats 9-10, resources 11, talents 12-13, items 14-16)

### ECS Architecture

- **Component storage**: Sparse-set per type (`ecs.ComponentStorage(T)`). O(1) insert/get/remove, cache-friendly iteration. No archetypes — minimal and sufficient for roguelike entity counts (<10K).
- **Component type IDs**: Manually assigned `u16` constants, not auto-generated. Each plugin reserves a range.
- **World**: Central hub holding typed storages (keyed by type_id), entity generation counter, event queue, and command buffer.
- **Event system**: Type-erased events with comptime-generated destroy functions. Events are collected per frame, processed at frame end.

### Zig 0.16 Specifics

This project targets **Zig 0.16.0**. Key API differences from older Zig:

| Pattern | Old (0.11-0.13) | New (0.16) |
|---------|-----------------|------------|
| ArrayList default init | `= .{}` | `= .empty` |
| ArrayList (unmanaged) | `ArrayListUnmanaged(T)` | `ArrayList(T)` |
| ArrayList init | `ArrayList(T).init(alloc)` | Use `.empty`, methods take allocator |
| `@typeInfo` struct access | `.Struct.fields` | `.@"struct".fields` |
| `std.math.rotl` | `rotl(x, r)` | `rotl(T, x, r)` |
| `std.hash.Wyhash` | `Wyhash.hash(seed, input)` | Struct with method (avoid; use inline hash) |
| Allocator | `GeneralPurposeAllocator` | `DebugAllocator(.{})` |
| Build API | `exe.linkSystemLibrary()` | `module.linkSystemLibrary()` |
| `std.fmt.allocPrintZ` | Available | Removed (use `allocator.dupeZ`) |
| `std.rand` | `std.rand.DefaultPrng` | `std.Random.DefaultPrng` |
| Container init | `{}` works for all | `.empty` required for ArrayList/HashMap |

All memory allocations must pass allocator explicitly. ArrayList methods (`append`, `deinit`, `resize`) all require allocator as first argument.

### Renderer

SDL2 + OpenGL fixed-function pipeline. Uses `GL_QUADS` exclusively (no `glBitmap` — broken on modern Windows GL drivers). ASCII characters are rendered via an 8×8 bitmap font decomposed into small quads in `drawGlyph()`. Note: `glVertex2f` is declared separately from `glVertex2i` — both must be in the extern block.

### Test Infrastructure

- Test root: `src/tests.zig` (imports all modules' `test` blocks)
- Shared factory: `createTestWorld()` sets up a World with all 16 component storages registered
- Uses `page_allocator` to avoid leak detection noise from heap-allocated storages
- Tests that need ECS: call `createTestWorld()`, then `defer world.deinit()`

### Cross-Platform Windows Build

Windows deps live in `deps/win/` (downloaded via `download_deps.sh`). The build.zig conditionally links `opengl32`, `gdi32`, `user32`, etc. on Windows. SDL2.dll is automatically copied to `zig-out/bin/` alongside the exe. `deps/` is gitignored.
