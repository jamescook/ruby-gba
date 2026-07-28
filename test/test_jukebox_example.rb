# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../examples/jukebox"

# The Jukebox example (examples/jukebox.rb): the sound showcase. Three classical
# melodies written with the note/tempo DSL; the cursor picks one and it plays and
# loops on the music channel. This asserts what the player hears — the highlighted
# tune's notes actually fire — on the interpreter oracle AND that a real ROM drives
# the music channel on hardware.
class TestJukeboxExample < Minitest::Test
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby

  # The opening (downbeat) note of each tune, in Hz — distinct so each is a
  # diagnostic value. If the frame-0 fix regressed, these would never sound.
  ODE_FIRST    = 330 # E4
  ELISE_FIRST  = 659 # E5
  MINUET_FIRST = 587 # D5

  # A per-frame input that taps DOWN +n+ times, one edge per tap, then holds
  # nothing — leaving the cursor parked on row n. The interpreter samples the
  # script from frame 1, so the presses land on odd frames (1, 3, ...) with a
  # released frame between them, and each is a fresh rising edge the cursor moves on.
  def tap_down(times)
    down_frames = Array.new(times) { |k| 1 + k * 2 }
    ->(f) { down_frames.include?(f) ? [:down] : [] }
  end

  def notes(interpreter)
    interpreter.audio.select { |e| e[0] == :note }
  end

  def test_the_example_builds_clean
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # Row 0 is selected at the start, so the first tune plays with no input and
  # sounds its opening note.
  def test_the_first_song_plays_by_default_on_the_interpreter
    i = Ruby.new.run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :ode_to_joy, ODE_FIRST],
                    "the highlighted tune should sound its downbeat"
  end

  # Move the cursor down one row and the second tune takes over the channel.
  def test_selecting_the_second_song_plays_it_on_the_interpreter
    i = Ruby.new.input_each_frame(&tap_down(1)).run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :fur_elise, ELISE_FIRST],
                    "selecting row 1 should play Fur Elise"
  end

  # Two rows down lands on the third tune.
  def test_selecting_the_third_song_plays_it_on_the_interpreter
    i = Ruby.new.input_each_frame(&tap_down(2)).run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :minuet, MINUET_FIRST],
                    "selecting row 2 should play the Minuet"
  end

  # On real hardware: the ROM boots and the music channel is actually driven.
  def test_the_music_channel_is_driven_on_the_console
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    v = assert_gemba_loads_rom(rom, frames: 12)
    assert v.sound?, "the highlighted tune should drive the music channel"
  end
end
