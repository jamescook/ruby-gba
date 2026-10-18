# A real GBC game to check our hardware understanding against

2026-10-18

**The question.** The GBC lowering's checked run holds a cartridge to the interpreter, which says
what a program MEANS. Nothing in that loop says whether we understood the hardware the way a real
game does: how it lays out its tiles and palettes, how it banks its code, how it keeps a save, what
a frame costs. Is there an open disassembly of a real GBC game that builds to the original
cartridge, to read and to run beside ours?

## The choice

**The Legend of Zelda: Oracle of Ages, from `github.com/Stewmath/oracles-disasm`**, with
**Pokémon Crystal, from `github.com/pret/pokecrystal`**, as a second.

- Ages is a GBC-only game (the CGB flag says so), on an MBC5 with battery-backed RAM: 64 ROM banks
  (1 MB) and one 8K bank of save memory, the controller our lowering uses. Its source is commented
  closely and builds in about 20 seconds.
- Crystal adds what Ages does not show: an MBC3 with its clock, a different save checksum and
  backup scheme, and much fuller written documentation (`pret.github.io/pokecrystal`).

Both were built on 2026-10-18, from shallow clones, in a scratch folder outside this repository.
Neither build needs the original cartridge: every byte comes from the repository.

| cartridge | sha1 of our build | the project's published checksum |
|---|---|---|
| Oracle of Ages | `880374fb978b18af4aa529e2e32f7ffb4d7dd2f4` | md5 `c4639cc61c049e5a085526bb6cac03bb` (`ages.md5`): matches |
| Oracle of Seasons | `6580b03121da78c0f789443a70dfcc78914e284a` | matches `seasons_emptyfill_0.md5`, not the plain `seasons.md5`: WLA-DX fills unused space differently, as the README says; it plays the same |
| Pokémon Crystal | `f4cd194bdee0d04ca4eac29e09b8e4e9d818c133` | `roms.sha1`: matches |
| Pokémon Crystal 1.1 | `f2f52230b536214ef7c9924f483392993e226cfb` | `roms.sha1`: matches |

## Building them

- **oracles-disasm** needs WLA-DX 10.6, Python 3 and PyYAML.
  `git clone --depth 1 --branch v10.6 https://github.com/vhelin/wla-dx`, then
  `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --target wla-gb wlalink`;
  then in the disassembly, with WLA's `build/binaries` on the path, `make ages seasons`.
- **pokecrystal** needs RGBDS 1.0.4 (its INSTALL.md pins it).
  `git clone --depth 1 --branch v1.0.4 https://github.com/gbdev/rgbds && make` (needs libpng and
  bison); then in the disassembly, with rgbds on the path, `make` and `make crystal11`.

## The licence, and what that allows

**Neither repository carries a licence**, so its code is all rights reserved by its authors — and
it is in any case a rendering of Nintendo's and Game Freak's copyrighted cartridges, graphics, text
and music. That decides how they are used:

**Use**, on a developer's own machine and never shipped:

- Read the source to learn how a real game drives the hardware — `include/rominfo.s` (the header),
  `code/loadGraphics.s` (VRAM banks and DMA), `code/fileManagement.s` (`calculateFileChecksum`) in
  Ages; `home/palettes.asm`, `engine/gfx/dma_transfer.asm` (HDMA), `engine/menus/save.asm` and
  `home/double_speed.asm` in Crystal — and then write our own code from that understanding and from
  Pan Docs.
- Build the cartridge locally and play it in mGBA through `ruby-gba-emulator`, to compare its
  palette memory, sprite table, VRAM banks, double speed, bank switching and save memory with what
  our lowering does, and to see what a frame of a shipped game costs.
- A test or tool that wants one finds it by a path the developer gives (an environment variable),
  checks its sha1 against the table above, and skips, saying why, when it is not there.

**Never copy into this repository**: any of their source, macros, constants or comments; any
graphics, tiles, palettes, text, music or the precompressed blobs; a built cartridge, its symbol or
map files, or anything cut from them — no cartridge fixtures and no pictures of their screens.
Register names and hardware facts, as Pan Docs states them, are fine: they are the hardware's, and
we write our own code around them.
