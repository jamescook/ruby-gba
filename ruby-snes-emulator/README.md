# ruby-snes-emulator

A headless Super Nintendo for checking cartridges from Ruby. It plays a cartridge one frame at a
time in [bsnes](https://github.com/bsnes-emu/bsnes) and reads back what a test needs to know:

- the picture of the last frame, at the console's 256×224;
- work RAM (128K), video RAM (64K), the colour memory (256 colours) and the sprite table (544 bytes);
- the 65816's registers;
- the cartridge's battery-backed RAM;
- the manifest bsnes wrote for the cartridge from its header, and the board it names
  (`core.board`, such as `"LOROM-RAM#A"`).

```ruby
require "ruby_snes_emulator"

core = RubySNESEmulator::Core.new("game.sfc")
core.set_buttons(%i[right a])
60.times { core.run_frame }
core.wram_read16(0x0100)
core.colors.first # the top-left pixel, as a 15-bit colour
core.destroy
```

## The core

bsnes is built as a libretro core with `core/bsnes-vblank-probe.patch`. Its libretro front end
hands over no memory at all without it. The patch lets it hand over the console's memories,
read from the accurate PPU. `rake compile_core` clones bsnes at the revision the Rakefile names,
applies the patch and builds it into `core/build/` (git, make and a C++ compiler). Set
`VBLANK_SNES_CORE` to use a core built somewhere else.

The binding is pure Ruby over Fiddle: there is no C extension to compile. Each `Core` loads a
copy of the library of its own, so two of them in one process are two consoles.
