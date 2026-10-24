# Asserting what something costs

There is no cost estimator (the old scanline estimator, its weights and `rake cost:check` are
deleted). A test that says "this is more work than that" has two honest instruments.

**What the build emitted**, for code that is a straight run of instructions:

```ruby
RubyGBA::IR::Backends::GBA.new.lower(program).bytesize
```

Right for "a tiny font emits less than the default one". Wrong wherever machinery is shared — a
palette, a glyph routine — because it lands wherever it is first needed, so the same `tint`
reads very differently in two programs.

**What the console really did**, for anything about time:

```ruby
result = RubyGBA::Diagnostics::Profiler.run(rom, frames: 30, picture: false)
result.idle_share        # how much of each frame was left over — the usual one
result.fps               # 60.0, or less when a pass does not fit in a frame
result.samples_per_frame # instructions a frame
```

It needs a ROM built through the DSL (or `rom_of`), since a profile has to know where each
routine ended up. `picture: false` skips the screen readings (tearing, and `Flicker`, losing half
the drawing), which cost a bus read per pixel.

Prefer `idle_share` to `samples_per_frame` for "is this faster": a pass too slow for one frame
spills into the next, so a slower build runs fewer instructions per frame. A program that never
sleeps idles at 0.0 either way; compare `fps` for those.

**Tearing.** Whether a game can tear is a fact of its screen, and `BuildReport` says it. Whether
it does is a race a profile reads (`RubyGBA::Diagnostics::Tearing`), except on a screen with no
framebuffer, where it says nothing rather than "no tear".
