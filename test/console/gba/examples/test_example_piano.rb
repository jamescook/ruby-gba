# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/piano").to_s

# examples/piano.rb — two hands playing "Mary Had a Little Lamb", animated: the
# right hand plays the melody (a finger per note, the key lights) while the left
# hand vamps a two-note block chord on each downbeat, so a downbeat sounds three
# notes at once — a real two-hand chord with no voice cutting out. One recorded
# sample, re-pitched across the keys and summed by the software mixer. This pins
# that behavior on the run's own player.
class TestExamplePiano < Minitest::Test
  YELLOW = Color.resolve(:yellow)

  # Run the example on the interpreter for +frames+ frames, calling the block at
  # each vblank with the interpreter (its #screen has the settled previous frame).
  private def play(frames)
    i = game_player
    i.each_vblank { |f| yield(i, f) if block_given? && f <= frames }
    i.run(Piano.program, frames: frames)
    i
  end

  # The x-center of the MELODY key-light. Scanned on the right of the keyboard so
  # the fixed chord lights on the left can't be mistaken for it. nil if hidden.
  private def melody_light_center(i, row: 141)
    xs = (120...220).select { |x| i.screen.pixel(x, row) == YELLOW }
    xs.empty? ? nil : (xs.min + xs.max) / 2
  end

  private def face_vars(i)
    i.vars.select { |k, _| k.to_s.end_with?("_face") }
  end

  # --- the two-hand chord: several notes at once, no cutout ---

  def test_two_hands_sound_a_chord
    i = play(12)
    assert_operator i.peak_voices, :>=, 3,
                    "a downbeat should sound the melody note plus the left hand's two-note " \
                    "chord at once, but peak voices was only #{i.peak_voices}"
  end

  # --- the melody hand lights the correct keys ---

  def test_the_melody_light_tracks_the_right_keys
    keys = []
    play(120) do |i, _f|
      c = melody_light_center(i)
      keys << (c / Piano::KEY_W) if c
    end
    %i[E D C].each do |note|
      assert_includes keys, Piano::MEL_KEY[note],
                      "the melody light should light key #{Piano::MEL_KEY[note]} for #{note}; saw #{keys.uniq.sort.inspect}"
    end
  end

  # --- both hands animate: the melody hand cycles fingers, the chord hand toggles ---

  def test_both_hands_animate
    seen = Hash.new { |h, k| h[k] = [] }
    play(120) { |i, _f| face_vars(i).each { |k, v| seen[k] << v } }
    counts = seen.values.map { |vs| vs.uniq.size }
    assert_equal 2, seen.size, "there should be two posed hands"
    assert_operator counts.min, :>=, 2, "both hands should change pose at least once"
    assert_operator counts.max, :>=, 3, "the melody hand should cycle through several fingers"
  end

  def test_the_notes_actually_sound
    sounded = false
    play(30) { |i, _f| sounded ||= i.active_samples.include?(:piano) }
    assert sounded, "playing the tune should sound the piano instrument"
  end

  # Both hands rendering and the piano sounding on the Advance's cartridge, in the emulator, are
  # in test/lowering/gba/examples/test_example_piano_cartridge.rb.
end
