# frozen_string_literal: true

require "test_helper"

require "stringio"

# A song part can play a recorded instrument instead of the square-wave voice:
# `voice :melody, plays: :piano do ... end`. Each note plays the instrument's recording at that
# note's pitch, through the mixer, and a rest silences it. The part names the instrument, never a
# channel — which voice it uses is the framework's business.
class TestSongInstruments < Minitest::Test
  NOTES = RubyGBA::Audio::Music::NOTE_FREQUENCIES
  STEP_ONE = GBA::Mixer::STEP_ONE

  # A piano recorded at C4, a second long — longer than any note here, so it is the next event
  # that ends a note rather than the recording running out.
  private def piano_game(&extra)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :tune do
        tempo 360 # a quarter is ten frames
        voice :melody, plays: :piano do
          note :C4, :quarter
          rest :quarter
          note :G4, :quarter
        end
      end
      play_song :tune
      instance_exec(&extra) if extra
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # --- the console ---

  private def console_steps_at(frames)
    rom = assemble_rom(piano_game, name: "SONGINST")
    assert_emulator_loads_rom(rom, frames: frames).voices.map { |v| [v.sample, v.step] }
  end

  # A step carries the note's pitch against the recorded one AND the resampling: the mix runs
  # at a rate the sound hardware can sustain (GBA::Timers.sample_clock) rather than at the rate
  # the piano was recorded at, so a note at the recorded pitch is not a step of 1.0.
  RECORDED_AT = 8000
  private def step_for(note)
    resample = RECORDED_AT.to_f / GBA::Timers.sample_clock(RECORDED_AT).rate
    (NOTES[note].to_f / NOTES[:C4] * resample * STEP_ONE).round
  end

  def test_the_console_plays_each_note_at_its_pitch
    first = console_steps_at(6)
    assert_equal 1, first.size, "one voice: the melody's C4 (#{first.inspect})"
    assert_equal :piano, first[0][0]
    assert_in_delta step_for(:C4), first[0][1], 2

    assert_empty console_steps_at(16), "the rest silenced it"

    third = console_steps_at(26)
    assert_equal :piano, third[0][0]
    assert_in_delta step_for(:G4), third[0][1], 2, "the G4 reads the recording faster"
  end

  # --- the surface ---

  def test_an_instrument_nobody_declared_is_a_friendly_error
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("NOPIANO", console: :gba, code: "ZNOP", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        enable_sound
        song(:tune) { voice(:melody, plays: :piano) { note :C4, :quarter } }
        play_song :tune
        game_loop { wait_vblank }
      end
    end
    assert_match(/instrument :piano/, err.string)
  end

  # `plays: :sine` is the console's wave voice, so a recording called :sine could never be played
  # by a part — it would sit in the cartridge, envelope and all, and nothing would say so.
  def test_a_recording_named_like_one_of_the_consoles_own_voices_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval { instrument :sine, pcm: [60, -60] * 400, rate: 8000 }
    end

    assert_match(/:sine/, error.message)
    assert_match(/different name/, error.message)
  end

  # A song whose second part is an instrument leaves the square voice beeps use alone, so a
  # beep beside it is nothing to warn about.
  def test_an_instrument_part_does_not_share_the_voice_beeps_use
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :bass, pcm: [60, -60] * 4000, rate: 8000, note: :C3
      song :duet do
        voice(:melody) { note :C5, :whole }
        voice(:bass, plays: :bass) { note :C3, :whole }
      end
      play_song :duet
      game_loop do
        wait_vblank
        beep :high
      end
    end
    b.finalize_program
    report = RubyGBA::IR::Guardrails::Validator.new.run(b.program, autofix: false)

    refute(report.warnings.any? { |w| w.check == :channel_conflict })
  end
end
