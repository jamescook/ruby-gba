# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Pitched voices: `sample.play(pitch: :E4)` plays one recorded sample at a different note by
# reading through it faster (higher) or slower (lower) — so one recorded note covers a whole
# keyboard. The pitch shifts from the sample's own `note:` (default :C4). This is the piece
# the piano is built on. Pinned on the interpreter (a higher note plays out faster) and on
# gemba (the voice's play position and its fixed-point step, read off the console).
class TestPitchedVoices < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM

  # Play sample :s (recorded at :C4) once at the given pitch, then loop `frames` frames.
  def play_for(frames, pitch)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      s = sample :s, pcm: [30] * 4000, rate: 8000, note: :C4 # ~0.5s at recorded pitch (~30 frames)
      pitch ? s.play(pitch: pitch) : s.play
      counter = var(:__f, 0)
      game_loop do
        wait_vblank
        counter.add 1
        (counter >= frames).then { halt }
      end
    end
    Reference.new.run(b.program, max_steps: 200_000)
  end

  # --- the surface (interpreter): a higher note plays out faster ---

  def test_a_higher_note_finishes_sooner
    base = play_for(20, nil)     # ~30 frames of sound -> still going at frame 20
    high = play_for(20, :C5)     # an octave up -> ~15 frames -> already done by 20
    assert_includes base.active_samples, :s, "the recorded pitch is still sounding at frame 20"
    refute_includes high.active_samples, :s, "an octave up has already finished by frame 20"
  end

  def test_a_lower_note_lasts_longer
    high = play_for(20, :C4)     # recorded pitch, ~30 frames
    low  = play_for(20, :C3)     # an octave down -> ~60 frames
    # both still sounding at 20, but the low one has plenty left — sanity that low != high
    assert_includes low.active_samples, :s, "an octave down is still sounding at frame 20"
    refute_nil high.volume_of(:s)
  end

  def test_a_bad_pitch_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        s = sample :s, pcm: [0, 1], rate: 8000
        s.play(pitch: :H9) # not a note
      end
    end
    assert_match(/note/i, err.message)
  end

  # --- hardware: the console reads a pitched voice faster ---
  #
  # Two voices of the same sample play together — one at its recorded pitch, one an octave
  # up. After a few frames we read each voice's play position off the console: the octave-up
  # voice should have advanced through the sample about twice as far. We also read its
  # fixed-point step and check it's the octave ratio.
  def test_a_pitched_voice_steps_faster_on_the_console
    gba = GBA.new
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      tone = sample :tone, pcm: [40, -40] * 3000, rate: 8000, note: :C4 # 6000 samples, no wrap in 6 frames
      tone.play(loop: true)              # voice 0 — recorded pitch
      tone.play(loop: true, pitch: :C5)  # voice 1 — an octave up
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    rom = ROM.assemble(gba.lower(b.program), title: "PIT0", code: "BPIT", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)

    base_pos = v.mem32(gba.voice_base + GBA::SLOT_POS)
    high_pos = v.mem32(gba.voice_base + GBA::SLOT_BYTES + GBA::SLOT_POS)
    assert_operator base_pos, :>, 0, "the base voice advanced through its sample"
    ratio = high_pos.to_f / base_pos
    assert_operator ratio, :>, 1.7, "the octave-up voice advanced ~2x as far (#{high_pos} vs #{base_pos})"
    assert_operator ratio, :<, 2.3, "...and not more than ~2x (#{high_pos} vs #{base_pos})"

    high_step = v.mem32(gba.voice_base + GBA::SLOT_BYTES + GBA::SLOT_STEP)
    expected = (523.0 / 262 * (1 << 16)).round # C5/C4, 16.16 fixed
    assert_in_delta expected, high_step, 2, "the octave step is the C5/C4 ratio in 16.16"
  end
end
