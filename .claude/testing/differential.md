# Comparing the interpreter with the console, whole

## Every pixel — `test/differential.rb`

Compares all 38,400 pixels instead of a handful. The check is the library's
(`RubyGBA::Testing::Pictures`, `lib/ruby_gba/testing/pictures.rb`), shipped to games;
`Differential` is this suite's name for it, so a change to it is a change for every game. Use it
when a feature's whole picture should match, and keep hand-picked assertions for the values that
document intent.

```ruby
include Differential

assert_backends_agree(program, frames: 4)         # every pixel must match, or fail
assert_backends_agree(program, frames: [3, 5, 7]) # ...at each of those frames, a run each
backend_pictures(program, frames: 4)              # => [interpreter_pixels, console_pixels, interpreter_frames]
mismatched_pixels(oracle, console)                # => [[x, y, want, got], ...]
```

`frames:` is how many frames the interpreter plays. The console runs longer by
`Differential::BOOT_FRAMES` (bitmap 2, tiled 1), because it runs the ROM's setup before the loop —
measured numbers, re-measured by a test. A program that switches display mode has no single
offset and raises unless given `console_frames:`.

**The two are lined up on passes of the game loop, not frames.** `BOOT_FRAMES` was measured on a
program with almost nothing to set up; a real tiled game uploading a map spills into a second
frame and is a pass behind for the whole run, which a moving picture shows as a frame of drift
that looks like a lowering bug. So a picture that is a finished pass is compared at the passes
the console finished: tiled and rotozoom screens (no framebuffer; the sprite table and scroll
are written in one go after the vblank) and tear-free bitmap (the shown page is finished). A
single-buffered bitmap screen is compared at the console's passes when the console finished more
than the frames asked for; below that it can be caught half-drawn, so it keeps `BOOT_SLACK`'s
one-pass tolerance and the `OverBudget` refusal. The comparison is still every pixel exact; this
only picks the moment.

A failure prints the count, the first few coordinates with colour names, and a 40x20 map of
where they differ. Use `backend_pictures` directly to pin a known, filed disagreement without
failing the build.

On the native and JavaScript runs the same two calls compare the game as C (or JavaScript)
with the interpreter instead, and do not skip; see `.claude/testing/lowerings.md`.

## Every byte of recorded sound — `test/mixed_sound.rb`

The interpreter works out every byte the cartridge's mixer writes (`i.mixed_sound`, a slice a
frame), and this holds the two to each other.

```ruby
include MixedSound

assert_mixes_agree(program, frames: 24)    # every byte of every slice must match
assert_mixes_agree(program, frames: 150, presses: { 5 => [:up], 60 => [:a] }, at_least: 60)
console_mixes(program, 30)                 # the console's slices, newest after each frame
```

Each list starts at its first slice with any sound, since the console spends frames setting up.
So it cannot see the two a frame apart on everything; it does see one sound landing a frame late
against another — which is why a timing test plays two (a tune, and a sound started in the
loop). It reads recorded sound only: the square, wave and noise voices never pass through
memory.
