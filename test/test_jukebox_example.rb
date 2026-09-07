# frozen_string_literal: true

require "test_helper"

require "stringio"
require_relative "../examples/jukebox"

# The Jukebox example (examples/jukebox.rb): the sound showcase. Three classical
# melodies written with the note/tempo DSL; the cursor picks one and it plays and
# loops on the music channel. This asserts what the player hears — the highlighted
# tune's notes actually fire — on the interpreter oracle AND that a real ROM drives
# the music channel on hardware.
class TestJukeboxExample < Minitest::Test

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
  # sounds its opening note. Ode to Joy is a two-part arrangement, so both the
  # melody's downbeat and the bass note under it sound together on frame 0.
  ODE_BASS_FIRST = 131 # C3, the bass note under the opening measure

  def test_the_first_song_plays_by_default_on_the_interpreter
    i = Reference.new.run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :ode_to_joy, ODE_FIRST],
                    "the highlighted tune should sound its melody downbeat"
    assert_includes notes(i), [:note, :ode_to_joy, ODE_BASS_FIRST],
                    "the two-part arrangement should sound its bass under the melody"
  end

  # Move the cursor down one row and the second tune takes over the channel.
  def test_selecting_the_second_song_plays_it_on_the_interpreter
    i = Reference.new.input_each_frame(&tap_down(1)).run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :fur_elise, ELISE_FIRST],
                    "selecting row 1 should play Fur Elise"
  end

  # Two rows down lands on the third tune.
  def test_selecting_the_third_song_plays_it_on_the_interpreter
    i = Reference.new.input_each_frame(&tap_down(2)).run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :minuet, MINUET_FIRST],
                    "selecting row 2 should play the Minuet"
  end

  # The three headings say they are centred, so the proof is that they LOOK centred:
  # the gap to the left of the lit pixels matches the gap to the right. Read off the
  # picture rather than recomputed from the font, so it would still catch a font that
  # measured itself wrong. The example used to multiply the character count by four
  # and every one of these lines sat left of centre — each by a different amount.
  HEADING_ROWS = { 14 => "JUKEBOX", 34 => "PRESS UP OR DOWN", 108 => "NOW PLAYING" }.freeze

  # The leftmost and rightmost columns anything is drawn in, over the rows one line of
  # text occupies.
  def lit_span(screen, y, height: 7)
    xs = (0...240).select { |x| (0...height).any? { |dy| screen.pixel(x, y + dy) != 0 } }
    refute_empty xs, "nothing is drawn at y=#{y}"
    [xs.first, xs.last]
  end

  def test_the_headings_are_genuinely_centred
    screen = Reference.new.run(Jukebox.program, max_steps: 4000).screen

    HEADING_ROWS.each do |y, text|
      left, right = lit_span(screen, y)
      assert_in_delta left, 239 - right, 1,
                      "#{text.inspect} sits #{left} from the left and #{239 - right} from the right"
    end
  end

  # The cursor is drawn beside the picked row, and moves with it. Worth pinning here
  # because the example drew ">" for a long time and nothing appeared: the built-in
  # font had no such glyph, so every frame drew an invisible cursor and the only thing
  # marking the picked row was its colour.
  ROW_TOPS = [58, 78, 98].freeze

  def test_the_cursor_hangs_off_the_left_of_the_picked_row
    at_rest = Reference.new.run(Jukebox.program, max_steps: 4000).screen
    left_edges = ROW_TOPS.map { |y| lit_span(at_rest, y).first }

    assert_operator left_edges[0], :<, left_edges[1],
                    "the picked row starts further left, because the cursor is beside it"
    assert_equal left_edges[1], left_edges[2], "the other two rows line up with each other"

    moved = Reference.new.input_each_frame(&tap_down(1)).run(Jukebox.program, max_steps: 4000)
    after = ROW_TOPS.map { |y| lit_span(moved.screen, y).first }

    assert_operator after[1], :<, after[0], "the cursor followed the pick down a row"
  end

  # On real hardware: the ROM boots and the music channel is actually driven.
  def test_the_music_channel_is_driven_on_the_console
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    v = assert_gemba_loads_rom(rom, frames: 12)
    assert v.sound?, "the highlighted tune should drive the music channel"
  end
end
