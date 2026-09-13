# ruby-gba-emulator

A lean, **headless** binding to [libmgba](https://mgba.io)'s `mCore` — boot a GBA
ROM, step it a frame at a time, and read back video, audio, and memory as plain
Ruby data. No UI of any kind.

It is a gem of its own rather than part of ruby-gba, because building a cartridge is pure Ruby
and running one is not: this half needs a C compiler and a system libmgba, and only somebody
verifying or profiling a ROM needs it at all. It lives in the ruby-gba repository for now, and
is taken as a gem from git.

## What it's for

Answering *"what is this ROM actually doing, frame by frame?"* — the same
question the ruby-gba `Verifier` answers, but through a minimal dependency you
can build in seconds.

```ruby
require "ruby_gba_emulator"

probe = RubyGBAEmulator.open("game.gba")
probe.step(6)                 # advance 6 frames
probe.pixel(120, 80)          # => [255, 0, 0]   (r, g, b)
probe.read16(0x04000000)      # => 0x403          DISPCNT: Mode 3 + BG2
probe.snapshot                # => {frame: 6, width: 240, lit_pixels: 38400, ...}
probe.step(10, keys: :right)  # hold RIGHT for 10 frames
probe.audio_energy            # => rough loudness of the last step
probe.close
```

`RubyGBAEmulator::Core` is the thin native wrapper (`run_frame`, `video_buffer`,
`audio_buffer`, `bus_read8/16/32`, `set_keys`, …). `RubyGBAEmulator::Probe` sits on
top and returns structured data.

## Debugging generated code: stop at an instruction, read the registers

For somebody working on a code generator rather than a game. A wrong answer out of generated
code usually comes down to one question — what did register r4 hold at this instruction? —
and before these two, the only way to ask was to change the generator and see whether the
symptom moved. That is a rebuild and a rerun per guess.

```ruby
probe.run_until(0x080001F4)   # run until the instruction at this address is next, then stop
probe.registers               # => {r0: 0, r1: 67108864, ..., r14: 134218240, pc: 134218228, cpsr: 31}
probe.registers[:r4]          # => 21
```

`run_until` stops before the instruction at that address runs, and raises if it is not
reached within `limit:` instructions (two million by default), so a register is never read
at the wrong place by accident. `registers[:pc]` is the address of the instruction that runs
next, which is where `run_until` stopped. The picture is not refreshed by it: `pixel` still
shows the last whole frame `step` ran.

From ruby-gba, `RubyGBA::Verifier` does the same by routine name, so nobody counts bytes —
where a routine landed is in the build record, including the ones copied into the console's
quick memory at boot:

```ruby
v = RubyGBA::Verifier.new(rom, frames: 2)
v.run_until(:count_up)        # the first instruction of func(:count_up)
v.registers[:r14]             # where it will return to
```

## Using it from a game

Add it beside ruby-gba. It carries a C extension, so bundler builds it — per Ruby ABI, which
means changing Ruby version rebuilds rather than leaving a library that will not load:

```ruby
git "https://github.com/jamescook/ruby-gba.git", glob: "{,ruby-gba-emulator/}*.gemspec" do
  gem "ruby-gba"
  gem "ruby-gba-emulator"
end
```

`glob:` is how bundler finds a gemspec that is not at the root of the repository — here it has
to match two, the framework's at the root and this one a directory down.

**One block for both, not a `gem ... github:` line each.** Bundler counts `glob:` as part of a
git source's identity, so two lines with different globs are two sources; but the directory it
clones into is named from the URL alone. Two sources into one directory race on a cold cache
and the clone fails. One block is one source, one clone, and the two gems can never land on
different commits of the same repository.

## Building & testing

Needs libmgba installed (`brew install mgba`, `apt install libmgba-dev`, or a
local build pointed at with `MGBA_DIR=...`). From this directory:

```
rake compile        # build the extension into lib/ruby_gba_emulator/
rake test           # compile, then run this gem's own tests
rake clean          # throw the build away — what to run after changing Ruby version
```

Or `rake test:emulator` from the ruby-gba repo root, which delegates here. These tests are kept
out of ruby-gba's main suite; its `rake test` does not run them.

## rcheevos (RetroAchievements)

The achievement evaluator is **compiled out** by default — a plain build links nothing but
libmgba. The code is still here, guarded by `#ifdef RUBY_GBA_EMULATOR_RCHEEVOS`. To bring it
back, point at an rcheevos checkout at build time; the extconf defines the macro and adds the
sources:

```
RUBY_GBA_EMULATOR_RCHEEVOS=/path/to/rcheevos rake compile
```

No code surgery — flip the flag and the `RubyGBAEmulator::RARuntime` class reappears.
