# The reference interpreter — `IR::Backends::Reference`

The headless oracle: no emulator, in-process, deterministic, the source of truth every lowering
is checked against. A test of what a GAME does makes it with `game_player` (see
`.claude/testing/lowerings.md`); `Reference.new` by name is for a test of the interpreter itself.

```ruby
i = Reference.new.run(program)               # returns self; 20 frames of a game loop by default
i = Reference.new.run(program, frames: 400)  # play this far in — every frame, however heavy
i.screen.pixel(x, y)               # colour at (x, y); nil if off-screen; 0 = unwritten (black)
i[:varname]                        # a variable's final value (0 if never written)
i.list(:trail)                     # a list's items now, oldest first, as an Array
i.pool(:guard, :x)                 # a pool field, one entry per slot: the value, or nil where the slot is free
i.game_state                       # { vars:, lists:, pools: } — all of the game's own state; compare two with ==
i.screen_mode                      # e.g. :bitmap
i.audio                            # the audio/register log
i.mixed_sound                      # every frame's slice of mixed recordings, the bytes the cartridge's mixer writes
i.stopped_at_budget?               # true if it was still looping when cut off

i.sprites(:hero)                   # the rows it drew for that named sprite
i.sprites                          # everything it drew, each saying whose it is

Reference.new.hold(:left, :a).run(prog)                   # buttons held for the whole run
Reference.new.input_each_frame { |f| [:left] }.run(prog)  # per-frame input; needed to observe `pressed` edges
Reference.new.frames_each_pass { |pass| 3 }.run(prog)     # say a pass ran late: 3 frames of catch-up
```

## `frames_each_pass` — telling it a pass was late

The interpreter has no clock and is never late, so a test says how many frames each pass
answered for, held between 1 and `IR::Frames::MOST` as the console holds it. That drives
`once_a_frame` (the body runs that many times), a beat in frames, a one-shot's counter, the song
and a playing recording (each moves on that many frames), and the buttons, read on each of those
frames — `input_each_frame` is called once per frame the screen shows, so a tap can start and end
inside one slow pass. It does not make the interpreter slow: timers still accrue a pass's worth,
and `frames:` still counts passes. Use it to pin what a program means when the console is late;
use the emulator to find out whether it really is.

## `frames:` and the step budget

`frames:` is the stop condition, and every frame asked for is played however heavy. The step
budget (`max_steps:`, a million by default) guards ONE frame; a frame that spends all of it never
reached a vblank and raises rather than handing back a part-played run. **Do not pass
`max_steps:` alongside `frames:`** — that is the old workaround for a fixed bug. Use it only for a
program with no frames (an unpaced `frame_sync: :manual` loop), where it is the whole run's budget
and `stopped_at_budget?` reports it.

## `i.sprites` — ask which sprite is which

Prefer it to hunting the fake screen or building a ROM whenever the question is where something
was drawn. It tells a sprite switched off from one drawn in the backdrop colour, one behind a
background, one a pixel off the edge. Each row is a `DrawnSprite`: `row.name`, `.x`, `.y`, and
`.picture` (the pose picked, by the name the author drew). The first three mean the same as on a
console `SpriteRow`, so a test comparing the backends reads both alike (`row[:x]` works on
neither). A sprite not drawn is absent; every live slot of a `pool` comes back under the pool's
name; a row the author named nothing for (a tiled text letter) has a nil `name`. There is no slot
number, deliberately.

## The first frame is white

A program with a game loop shows white until its first frame is set up, on both backends — the
console's forced blank. So `run(program, frames: 0)` reads white everywhere, and so does the
console for however many frames setting up takes. Read from `frames: 1`, or on the console step
until the picture stops being white. A program with no loop is shown as it is drawn.

The screen's default fill is `0` (black). For clip and overwrite tests, `clear_screen` to a
distinct colour first so "clipped" reads as that colour on both backends.
