# What in the codebase assumes the GBA

2026-10-18

**The question.** A Game Boy Color lowering is coming: the same IR, built into a GBC cartridge. Which
parts of the library assume the Game Boy Advance where they are meant to be console-neutral, which
rightly belong to the GBA lowering and stay there, and in what order do the neutral ones get a seam
without changing a single GBA cartridge byte?

**The line.** Three kinds of thing, and every finding below is one of them:

- **A fact about the console** — how big the screen is, how many sprites it composes, how many
  backgrounds it stacks, which buttons it has, whether it can turn a layer or blend two. The DSL,
  the guardrails and the interpreter read these, and they read them today as GBA constants. They
  belong in a small **console description** that every reader asks, and that the program carries.
- **The GBA lowering's own business** — ARM, quick memory, DISPCNT bits, the cartridge header, the
  save chips, the profiler that reads ARM program counters. These stay GBA-only. A GBC counterpart
  is new code beside them, not a generalisation of them.
- **Machinery that picks one of the above** — the build pipeline, the CLI, the test runs. Each
  hard-codes the GBA lowering today where it should pick by console.

The screen is the centre of it. `IR::Screen` (240×160) and `Console::Hardware::SCREEN_WIDTH/HEIGHT`
are two separate sources of the same fact, tied together only by a test, and five more files carry
240 and 160 as literals of their own.

---

## The map

Paths are under `lib/ruby_gba/`. **C** marks a console fact, to be read from the description;
**L** the GBA lowering's own; **P** a picker that should choose by console.

### The screen size

| where | what | side |
|---|---|---|
| `ir/screen.rb:15` | `IR::Screen::WIDTH/HEIGHT`, "the GBA's bitmap-mode screen" | C — becomes the GBA's description, read through the program |
| `console/hardware.rb:416` | `SCREEN_WIDTH/HEIGHT`, the second source | L — the GBA lowering's register file; derive from the description |
| `ir/build.rb:679` | `MIDDLE_OF_THE_SCREEN`, from `Screen` | C |
| `ir/guardrails/off_screen_draw.rb:24`, `sprite_cleared_each_frame.rb:27` | screen bounds | C — read the program's console |
| `ir/backends/reference/framebuffer.rb:19`, `reference.rb:169,920,2022,2412,2431,2502,2550` | the interpreter's fake screen, every one made at the default size | C — the interpreter sizes its screen from the program |
| `dsl/sprite.rb:208,222`, `dsl/hardware_sprite.rb:213,231`, `dsl/pool.rb:889`, `dsl/bounds.rb:47,57`, `dsl/grid.rb:100` | clamp to the screen, centre on it, the edge tests, a grid bigger than the screen | C — read the builder's console |
| `builder/drawing.rb:270,397,661`, `builder/spotlights.rb:78`, `builder/text.rb:314`, `effects/packs/iris.rb:43` | a fade's rectangle, the light's centre, `validate_coords!`, centred text, the iris's middle | C |
| `testing/pictures.rb:32` | a third literal copy, `SCREEN_W = 240` | P — the picture size comes from the run |
| `ir/backends/native/runtime/rg_screen.h:23`, `js/runtime/rg_screen.js:17` | `RG_SCREEN_WIDTH 240` in C and JavaScript | stays: those runtimes draw the GBA picture, and a program built for another screen is refused by them |
| `playthroughs/*` (four files), `diagnostics/verifier.rb:72`, `diagnostics/tearing.rb`, `flicker.rb` | GBA cartridge readers | L for now; `Verifier` takes its size from the emulator (below) |
| `cartridge/test_patterns.rb` | test cartridges drawn at 240×160 | L |

### What the picture is made of

| where | what | side |
|---|---|---|
| `ir/modes.rb:25`, `builder/drawing.rb:18` | the screen kinds: bitmap, tear-free bitmap, tiled, rotozoom; and the DISPCNT bits behind each | C for which kinds a console has; L for the bits, which belong in the lowering |
| `ir/guardrails/too_many_background_layers.rb:41` | four scrolling layers, two beside a turning one, one turning | C |
| `ir/guardrails/too_many_sprites.rb:32`, `effects/packs/menu.rb:540` | `MAX_SPRITES` = 128 | C — the GBC composes 40, ten to a line |
| `ir/backends/sprite_cut.rb:23` | the twelve GBA sprite shapes, a 64-pixel side | C — the GBC has 8×8 and 8×16 only. Shared by the interpreter and native |
| `builder/tile_runs.rb:21,87`, `dsl/canvas.rb:66`, `reference.rb:1438` | a painted tile is 32 bytes, two pixels a byte; the twelve picture sizes | C, and the deepest one: the 4-bit pixel is in the IR's own `TileRun` contract. A GBC lowering reads it and converts; the IR keeps it |
| `builder/images.rb:593`, `builder/tile_runs.rb:184` | a colour list holds 16 places, place 0 see-through | C — the GBC holds four, place 0 see-through on a sprite |
| `ir/tile_map.rb:24` | a background grid is 32 or 64 cells a side | C — the GBC's is 32 |
| `ir/affine.rb`, `ir/see_through.rb:18`, `ir/backends/blocks.rb:18`, `ir/backends/fade_steps.rb:22` | turning and resizing, blending, mosaic, the display's 16 fade steps | C, as whether the console HAS each: the GBC has none of the four |
| `ir/palette.rb:40` | 256 colours on a tear-free bitmap | L |

### Memory

| where | what | side |
|---|---|---|
| `builder.rb:112,1387` | the builder hands every variable a GBA address in quick memory | L, and in the wrong place: an address is the lowering's to choose. Left alone for now, since the GBC lowering places variables itself |
| `ir/guardrails/iwram_budget.rb:34`, `builder/composition.rb:29,363` | 32K quick memory, 256K roomy memory, `fast:` pools | L — the GBC has 8K of work memory and the build places everything there |
| `ir/guardrails/frame_from_cartridge.rb:68` | a generic guardrail that names `GBA::Placement` | L |
| `ir/save_layout.rb:78-129` | save memory sizes; **the chip is inferred from the size** (8K is the EEPROM, 32K the battery SRAM) | C, and a correctness hazard: an 8K GBC battery save would be read as the GBA's EEPROM. The kind has to be said, not inferred |

### Sound

| where | what | side |
|---|---|---|
| `audio/sound.rb:344` | `Sound::Registers`, the GBA's `REG_SOUND*` writes, in `audio/` | L — the GBC's sound registers are the GBA's legacy ones at other addresses, so a GBC lowering writes its own |
| `audio/sound.rb:58,81,284` | 16 mixer voices, the mixing rate | C, as whether the console mixes recordings at all: the GBC does not |
| `audio/music.rb:90` | two square parts, one wave, one noise | the same on both |
| `reference.rb:1005`, `native/sound.rb:93` | `GBA::Timers.sample_clock` read by the interpreter and native | L reached from outside; fine while only consoles that mix need it |

### Buttons and time

| where | what | side |
|---|---|---|
| `ir/buttons.rb:18` | ten buttons, L and R among them | C — the GBC has eight |
| `js/runtime/*`, `native/runtime/rg_pacing.h` | 280,896 cycles at 2^24 Hz a frame | stays: the frame rate is the same (70,224 cycles at 2^22 Hz) |
| `diagnostics/analyzer.rb:32`, `ruby-gba-emulator/lib/.../probe.rb:636` | 228 lines a frame | L — the GBC has 154 |

### The cartridge and the build

| where | what | side |
|---|---|---|
| `lib/ruby_gba.rb:171,193` | `RubyGBA.build` names `Backends::GBA` and `Cartridge::ROM` | P — the checking steps above them are neutral |
| `testing/pictures.rb:178`, `test/test_helper.rb:108`, `diagnostics/analyzer.rb:421`, `ir/dump.rb:130` | four more places that make a GBA cartridge by name | P where they serve tests of the game; L where they serve the profiler |
| `cartridge/rom.rb`, `header.rb`, `game_code.rb`, `rom_validator.rb` | the GBA header, entry branch, checksum, logo, four-character code | L — a GBC cartridge has its own header (0x100–0x14F), its own two checksums and a memory bank controller; it is a class of its own beside `ROM` |
| `cartridge/options.rb:25` | `fast_cartridge`, `fast_code`, `stack_room`, `save_memory` | L for the first three; `save_memory` is neutral once the kind is explicit |
| `cartridge/game.rb:117` | `default_filename` ends in `.gba` | C |
| `cli.rb:80,106` | `--format game/ir/native/web`; `--target` already means a desktop OS | P — a console is a separate axis, `--console` |
| `diagnostics/cartridge_file.rb:24` | refuses a file without the GBA's fixed byte | L, with a GBC counterpart when `play` learns GBC cartridges |
| `diagnostics/profiler.rb`, `build_report.rb`, `inspector.rb`, `tearing.rb`, `flicker.rb`, `sound_drops.rb`, `tick_rate.rb`, `video_memory.rb`, `sprite_row.rb`, `split_hints.rb`, `routine_profile.rb` | ARM program counters, quick memory, page flips, the mixer | L — the GBC gets its own profiler; only the report's shape and the CLI are shared |
| `diagnostics/verifier.rb` | the cartridge reader tests use; 240×160 from `Console::Hardware`, 32-bit `var`, 128 OAM rows, a GBA palette | the core (pixels, frames, stepping, saves, sound energy) is neutral once its size comes from the emulator; the rest is L |

### The emulator gem

`ruby-gba-emulator` opens a cartridge with `mCoreFind`, which tells a GB/GBC file from a GBA one by
its contents, and asks the core for its screen size after reset, so **it already boots and draws a
GBC cartridge**: `run_frame`, `video_buffer`, `width`/`height`, `set_keys`, `bus_read8/16/32`,
`audio_buffer`, save states and the rewind buffer all go through mGBA's generic core. What is GBA-only
is the introspection: `sprites` (128 `GBAObj`), `palette` (512 entries), `scroll`, `profile`,
`registers`, `cpu_cycles`, the sound feed and `run_until`, each of which says so when asked of a GB
core. `Probe`'s 228-line frame and its layer and voice names are the GBA's.

### The test runs

`Testing::Lowering` names three runs and `Testing::PLAYERS` hands each its player. The GBA run is
"the interpreter, with the cartridge checked in the emulator"; the native and JavaScript runs are
"the game lowered, checked against the interpreter on every frame". A GBC run is a fourth of the
second kind with a cartridge where the others have a program: the cartridge played in the emulator,
read back after every pass, and checked against the interpreter given the GBC's screen.
`Testing::RakeTasks#define_lowering_tasks` writes the three tasks out by hand rather than from
`NAMES`.

---

## The refactors, in order

Each is small enough to land on its own with `rake test` green, and none changes a GBA cartridge:
the check for that is every example built before and after, byte for byte.

1. **`Console::Description`, and the GBA's.** Screen size, buttons, how many sprites and how many
   to a line, the sprite shapes, background layers (scrolling, turning), colours in a list, whether
   it turns, blends, mosaics, fades on the display and mixes recordings, the cartridge's file
   extension. `IR::Screen` stays as the GBA's numbers for the code that has nothing else to ask.
2. **The program says which console it was built for.** `program` carries a `console` operand,
   `:gba` unless a build says otherwise, and `Cartridge::Options` carries the console a build is
   for. Everything after the builder asks the program.
3. **The DSL asks the builder's console** for the screen: clamping and centring sprites and pools,
   the edge tests, grids, centred text, coordinates checked as they are written, the fade
   rectangle, the light's centre, the iris.
4. **The guardrails ask the program's console**: drawing off the screen, sprites cleared every
   frame, too many sprites, too many background layers.
5. **The interpreter sizes its screen from the program**, and every `Screen::HEIGHT` inside it
   becomes the screen's own height.
6. **`RubyGBA.build` picks its lowering and cartridge by console** — the GBA's are the only ones
   until the GBC lowering exists — and `Game#default_filename` takes the console's extension.
7. **The save layout says its kind** — and, as it turned out, need not yet. A Game Boy Color
   cartridge's battery-backed memory is written a byte at a time, as the Advance's 32K is, so the
   GBC lowering keeps exactly that 32K layout (four banks of 8K) and refuses the other sizes. The
   kind becomes worth saying the day a console offers a flash or an EEPROM of its own.
8. **The test runs come from one table.** `RakeTasks` makes a task for each name in
   `Lowering::NAMES`, so a new run is a row and not three edits.
9. **`Verifier` takes its picture size from the emulator**, not from `Console::Hardware`.

What stays GBA-only, deliberately: the profiler and the build report and everything they read
(quick memory, ARM, page flips, the mixer), the inspector, the playthrough tools, `Sound::Registers`,
the builder's variable addresses, and the native and JavaScript runtimes, which draw the GBA's
picture and are told to refuse any other.
