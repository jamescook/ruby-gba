# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../examples/piano"

# examples/piano.rb — one left hand autoplaying "Mary Had a Little Lamb", animated:
# on each note the right finger presses the right key, the key lights, and the note
# sounds (one recorded sample, re-pitched across the keys). This pins that behavior
# the way a player sees it — the light lands on the correct keys, the hand changes
# finger poses, the notes sound — on the interpreter, and that it renders with the
# right colors and audible sound on gemba.
class TestExamplePiano < Minitest::Test
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color
  YELLOW = Color.resolve(:yellow)
  WHITE  = Color.resolve(:white)
  SKIN   = Color.rgb(31, 23, 17)

  # Run the example on the interpreter for +frames+ frames, calling +probe+ at each
  # vblank with the interpreter (its #screen has the settled previous frame).
  def play(frames)
    i = Ruby.new
    i.each_vblank { |f| yield(i, f) if block_given? && f <= frames }
    i.run(Piano.program, max_steps: frames * 3_000)
    i
  end

  # The x-center of the yellow key-light on a scan row through it, or nil if hidden.
  def light_center(i, row: 141)
    xs = (0...240).select { |x| i.screen.pixel(x, row) == YELLOW }
    xs.empty? ? nil : (xs.min + xs.max) / 2
  end

  # --- interpreter: the melody drives the animation to the right keys ---

  def test_the_key_light_tracks_the_notes_correct_keys
    keys = []
    play(120) do |i, _f|
      c = light_center(i)
      keys << (c / Piano::KEY_W) if c # which key index the light sits on
    end
    # The opening E, D, C land on keys 8, 7, 6 — the light should visit each.
    %i[E D C].each do |note|
      assert_includes keys, Piano::KEY_INDEX[note],
                      "the light should light key #{Piano::KEY_INDEX[note]} for #{note}; saw keys #{keys.uniq.sort.inspect}"
    end
  end

  def test_the_hand_changes_finger_poses
    poses = []
    play(120) do |i, _f|
      face = i.instance_variable_get(:@vars).find { |k, _| k.to_s.end_with?("_face") }
      poses << face.last if face
    end
    assert_operator poses.uniq.size, :>=, 3,
                    "the hand should press several different fingers over the tune, saw #{poses.uniq.sort.inspect}"
  end

  def test_the_notes_actually_sound
    sounded = false
    play(30) { |i, _f| sounded ||= i.active_samples.include?(:piano) }
    assert sounded, "playing the tune should sound the piano instrument"
  end

  # --- hardware: it renders with the right colors and is audible on gemba ---

  def test_it_renders_and_sounds_on_gemba
    rom = Piano.build_rom(out: StringIO.new, err: StringIO.new)
    v = assert_gemba_loads_rom(rom, frames: 8)

    # The see-through slot of the sprite palette must be exactly 0 — a byte-shifted
    # palette (the odd-length-sample DMA bug) would make this non-zero and tint
    # every sprite. This is the regression guard for that fix, read off hardware.
    assert_equal 0x0000, v.mem16(0x0500_0200), "sprite palette slot 0 must be see-through (palette not byte-shifted)"

    assert v.pixel_is?(100, 150, WHITE), "the keyboard's white keys should be white"
    assert v.pixel_is?(120, 100, SKIN),  "the hand should be skin-colored, not a scrambled palette"
    assert v.sound?, "the piano should be audible (energy #{v.audio_energy})"
  end
end
