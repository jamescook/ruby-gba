# The emulator — `Diagnostics::Verifier` over ruby-gba-emulator

Runs the real ROM and reads real pixels and sound. It is required: without it these tests fail
loudly. They really run — a passing `v.green?` is a genuine hardware assertion, and a
differential test green with 0 skips means the console really drew those pixels, however fast
it ran. On the native and JavaScript runs a test that reaches for it skips itself.

```ruby
include EmulatorSupport                    # from test/test_helper.rb
require_emulator!                          # ensure the emulator; fails loud if it isn't built

rom = VBlank::Cartridge::ROM.assemble(VBlank::IR::Backends::GBA.new.lower(prog), title: "NAME")

v = assert_emulator_loads_rom(rom, frames: 6, keys: KEY_LEFT)  # returns a Verifier
v.red?(x, y) / v.white? / v.blue? / v.green? / v.black?     # named-colour checks
v.pixel_is?(x, y, :red)                    # colour by name or 15-bit value
v.pixel_gba(x, y)                          # the raw 15-bit BGR555 (good in failure messages)
v.region_color?(x, y, w, h, :blue)
v.audio_energy / v.silent? / v.sound?      # "did the speaker do anything?"

v.only_color                               # the one colour every pixel is, or nil for a picture
v.brightness                               # every pixel's red, green and blue added up, each 0..31
v.frame_colors                             # the whole screen as one string, two bytes a pixel
v.frame_gba                                # ...and as a list of 15-bit numbers, to look pixels up in
v.same_picture_as?(other)                  # another reader, or a `v.picture` kept from earlier
v.difference_from(other)                   # { count:, box: [x, y, w, h], at: [x, y], colors: [here, there] } or nil

v.sprites(:hero) / v.sprites               # the console's own rows, by name or all
v.step                                     # play one more frame; everything after reads it
v.step(4, keys: KEY_RIGHT)                 # ...or four, holding a button

v.var(:hurt)                               # a variable the program computed, by name (vars: needed)
v.mem32(address) / v.mem16 / v.mem8        # the raw word/halfword/byte at an address

v.palette(:sprites, row.palette)           # the sixteen colours that sprite row is wearing
v.palette                                  # the whole table: 512, backgrounds first then sprites
v.showing(only: :sprites) { v.step; ... }  # draw the picture without some of it
v.hearing(without: :wave) { v.step(40); ... }  # mix the sound without some of it
v.layers / v.channels                      # the names those two can be given
```

`keys:` is an active-high `KEY_*` bitmask (OR them together), or `->(frame) { mask }` for input
that changes. `frames:` frames run before you read — a couple for a static blit, enough for a
moving sprite to settle.

## Whole-screen questions are cheap; `frame_gba` is dear

`only_color`, `brightness`, `frame_colors`, `same_picture_as?` and `difference_from` are one pass
over the picture, cheap enough to ask every frame of a long run. `frame_gba` builds 38,400
numbers and costs several frames' time: keep it for looking pixels up; to keep a still or ask
whether the screen changed, use `frame_colors` or `same_picture_as?`. All answer at five bits a
channel, the console's precision. The emulator holds eight bits and works brightened, darkened
or blended colours at eight, so one five-bit colour can be two numbers there. `all_black?` asks
at eight bits: a nearly black screen is black to `only_color` a frame before `all_black?`.

## One reader over one cartridge

Read everything off the same Verifier. A second reader over the same ROM is two readings of one
frame that can disagree, and they do: the emulator's low-level handle
(`VBlank::Diagnostics::Emulator.probe`) reports where a sprite's tiles were put, not where its
picture starts. Use that handle only for what the Verifier does not do (cost and timing, watching
an address, profiling).

`probe.sound_feed(frames: 1, keys:)` is one of those. For every sample the recorded-sound channel
played it gives the address its byte came from, its value, and when it fell due (`sample.due`);
silence where the queue ran dry (`sample.silence?`); and where the copy engine read each word it
queued. It sits between the mixer's buffers and the speaker, so it rules out faults that show in
neither, and it reads emulator state so the cartridge's timing is untouched. Compare two runs by
what was played, not by the speaker: the speaker places a sample a few cycles after it fell due,
behind whatever instruction was running (`sample.late`), so identical samples with different code
around them come out slightly different.

## `showing` and `hearing`

They change the console, not the reading, so the block must `v.step` before reading. Layers and
voices go back when the block ends. Taking a voice out under a held note is a cut, not a rest —
the mix steps and drifts back over about half a second — so step well past that before asking
whether it went quiet. Sound readers cover the whole run, so inside a block use
`audio_energy_by_frame.last(n)`.

## Long runs of sound

A reader holds a minute of sound in memory; past that it appends it to a scratch file in the
machine's temporary files and starts again, removed when the reader is collected or the program
ends. Every reader still answers for the whole run. The energy readers (`audio_energy`,
`audio_energy_by_frame`, `silent?`, `sound?`) work each frame out once, so asking after every
frame is cheap: `v.step.audio_energy_by_frame.last` is that frame. `audio_samples` returns every
sample at once, read from the file each time — ask it once. To change either:
`Verifier.new(rom, sound: VBlank::Diagnostics::RecordedSound.new(frames_in_memory: 600, folder: "scratch"))`.

## `v.var` versus `v.mem32`

`v.var` is the number the program counted to, a signed whole number, matching `i[:hurt]` for the
same frame. `v.mem32` is the raw word: minus one reads as four billion, and `count > 0` then
reads true.

## `v.sprites` — ask where a sprite is

It reads the table the console composes from, so it tells a hidden sprite from one in the
backdrop colour, one behind a background, one a pixel off the edge. Each row is a `SpriteRow`:
`name`, `x`, `y`, `slot`, `tile`, `palette`, `color_count`, `colors`, `priority`, `shape`, `size`,
`mirrored_across`, `mirrored_down`, `turned`, `piece_x`, `piece_y`. A sprite switched off is
absent. `row[:x]` does not work, deliberately: as a Hash a misspelt field read back nil and the
test passed.

- **`x`/`y` are where the picture starts** — where the game put the sprite, the same number
  `i.sprites` gives. The console's own number differs: a pose is stored trimmed, and a pose drawn
  backwards is trimmed from the other side. `piece_x`/`piece_y` carry the hardware number.
- **`colors` are the colours it is wearing**, ready to compare, whichever way the picture is
  stored (16-colour group or all 256; `color_count` says which). `v.palette(:sprites, row.palette)`
  is meaningless for a 256-colour picture.
- **Off screen is not absent.** A sprite reads at its own place wherever the table can say it (up
  to 96 rows above the screen or 32 below, and well past either side), and just past the bottom
  or right edge otherwise — row 160 or column 240 for a picture stored as drawn, a little less for
  a trimmed pose. A 64-pixel-tall sprite that turns or resizes, parked there, reads `turned` false.
  `i.sprites` gives the game's own place, so compare the two while the sprite is near.
- **Name it, and only its rows come back.** Never identify one by slot number, by position, or by
  its colours. A picture too big for one hardware sprite is several rows with one name; every live
  slot of a `pool` comes back under the pool's name; tiled text letters have a nil name.
- Needs a ROM assembled with its build record (`assemble_rom` and `VBlank.build` both do);
  `rom.built.sprite_slots` is the raw map.

## `v.step` — when something is HAPPENING

Use it when the question is about change, not where things ended up: which picture shows on each
frame of a knockback, how many frames a flash lasts, whether something vanishes and comes back.
It plays on from where the run stopped, and everything read after it is the frame it stopped on.

## Counting passes of the game loop

```ruby
v = assert_emulator_loads_rom(rom, frames: 20, count_passes: true)
v.passes                                   # passes FINISHED; nil for a program with no loop
```

The console runs the loop once per frame it has time for, so a game too slow for a frame plays
less game per frame — which is why a console run is lined up against the interpreter on passes,
never frames (`.claude/testing/differential.md`). It watches for the loop's own instructions, so
the cartridge measured is the one that ships. It is off by default because it costs a little
more the busier the cartridge is.
