# The native run's sound against the cartridge's

What would come out of a speaker is checked against the cartridge's own, in the emulator, with
one helper for any game (`test/sound_comparison.rb`):

```ruby
include SoundComparison
assert_native_sounds_like_the_console(program, frames: 300, buttons: { 3 => [:a], 4 => [:a] })
```

It plays the game both ways one voice at a time and compares every frame: loudness, pitch, and
how thin or full the tone is. It listens to the two square voices unless told
(`voices: %i[square1 wave noise]`), and every voice named has to be heard. The noise voice has no
pitch, so it compares how bright the hiss is (how often it changes); a test of the pattern itself
reads which way the voice stands on each step of a slow one (`Heard#runs`, in
`test_native_tones.rb`). The emulator is the answer key here, not the thing under test, so the
helper asks it directly rather than through `require_emulator!`. Its tolerances and their
reasons are at the top of the file.

A small made-up program goes in `test/vblank/ir/backends/native/test_native_tones.rb`; a whole
example's sound in a file of its own under `native/examples/` (`test_pong_sounds.rb`). The
windowless program has no speaker, so it writes its sound to a temporary file (`--sound-out`)
that the helper reads; a game played in its window writes none.

## The console starts its game a frame or two after the desktop build

The helper lines the two up on when each first makes a sound (trying a frame either side and
keeping the best). It cannot line up a button that lands on a different pass in each: walk a
character for frames 3 to 30 while something chases it, and the chaser is two passes further on
in one, catches it a frame apart, and every sound after is a frame out — which reads exactly like
a fault in the sound. Hold such a button from frame 1 until what it does has stopped mattering
(the character is against a wall, the menu has moved on; `test_pacman_sounds.rb`).
