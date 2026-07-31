# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# A playable sampled instrument: `instrument :piano, from: …` turns one recording into a
# whole keyboard you play *notes* on — `piano.play(:E4)`, or `piano.play(:C4, :E4, :G4)` for
# a chord that sounds all at once. It's a thin, note-named layer over pitched mixer voices
# (no rates/voices/mixer detail exposed). Pinned on the interpreter (chords are several
# voices; notes play live from input) and on gemba (a chord is three distinct pitched voices).
class TestInstrument < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  NOTES = RubyGBA::Music::NOTE_FREQUENCIES

  # Build a piano, hand it to the block to play, then loop `frames` frames.
  def play_frames(frames, &use)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      piano = instrument :piano, pcm: [40, -40] * 2000, rate: 8000, note: :C4
      instance_exec(piano, &use)
      counter = var(:__f, 0)
      game_loop do
        wait_vblank
        counter.add 1
        (counter >= frames).then { halt }
      end
    end
    Ruby.new.run(b.program, max_steps: 200_000)
  end

  # --- the surface (interpreter) ---

  def test_a_single_note_sounds
    i = play_frames(3) { |piano| piano.play(:E4) }
    assert_includes i.active_samples, :piano, "playing a note sounds the instrument"
  end

  def test_a_chord_sounds_several_notes_at_once
    i = play_frames(3) { |piano| piano.play(:C4, :E4, :G4) }
    assert_operator i.peak_voices, :>=, 3, "a three-note chord is three voices at once (#{i.peak_voices})"
  end

  def test_playing_no_note_is_a_friendly_error
    err = assert_raises(ArgumentError) { play_frames(1) { |piano| piano.play } }
    assert_match(/note/i, err.message)
  end

  def test_an_unknown_note_is_a_friendly_error
    err = assert_raises(ArgumentError) { play_frames(1) { |piano| piano.play(:Z9) } }
    assert_match(/note/i, err.message)
  end

  def test_a_note_can_be_played_live_from_input
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      piano = instrument :piano, pcm: [40, -40] * 2000, rate: 8000, note: :C4 # ~0.5s, lasts a while
      counter = var(:__f, 0)
      game_loop do
        wait_vblank
        pressed(:a).then { piano.play(:C4) }
        counter.add 1
        (counter >= 5).then { halt }
      end
    end
    # A pressed from frame 2 -> a note is triggered on the press edge, still sounding at frame 5
    i = Ruby.new.input_each_frame { |f| f >= 2 ? [:a] : [] }.run(b.program, max_steps: 20_000)
    assert_includes i.active_samples, :piano, "pressing a button played a note"
  end

  # --- hardware: a chord is three distinct pitched voices ---

  def test_a_chord_plays_distinct_pitches_on_the_console
    gba = GBA.new
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      piano = instrument :piano, pcm: [50, -50] * 3000, rate: 8000, note: :C4 # long enough to hold the chord
      piano.play(:C4, :E4, :G4)
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    rom = ROM.assemble(gba.lower(b.program), title: "CHRD", code: "BCHR", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)

    chord = %i[C4 E4 G4]
    steps = chord.each_index.map { |i| v.mem32(gba.voice_base + (i * GBA::SLOT_BYTES) + GBA::SLOT_STEP) }
    expected = chord.map { |n| (NOTES[n].to_f / NOTES[:C4] * (1 << 16)).round }

    assert v.sound?, "the chord should be audible (energy #{v.audio_energy})"
    assert_equal 3, steps.uniq.size, "the chord is three distinct pitches, got steps #{steps.inspect}"
    steps.zip(expected).each do |got, exp|
      assert_in_delta exp, got, 2, "each voice steps at its note's ratio (#{got} ~ #{exp})"
    end
  end
end
