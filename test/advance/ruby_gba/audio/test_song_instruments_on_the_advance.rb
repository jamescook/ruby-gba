# frozen_string_literal: true

require "test_helper"

require "stringio"

# THE TESTS OF ruby_gba/audio/test_song_instruments.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# A song part can play a recorded instrument instead of the square-wave voice:
# `voice :melody, plays: :piano do ... end`. Each note plays the instrument's recording at that
# note's pitch, through the mixer, and a rest silences it. The part names the instrument, never a
# channel — which voice it uses is the framework's business.
class TestSongInstrumentsOnTheAdvance < Minitest::Test
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

  # What the interpreter has sounding after each of the first +frames+ frames.
  private def sounding_by_frame(program, frames)
    seen = {}
    i = game_player
    i.each_vblank { |f| seen[f] = i.active_samples }
    i.run(program, frames: frames)
    seen
  end

  # --- the interpreter ---

  def test_each_note_plays_the_instrument_and_a_rest_silences_it
    seen = sounding_by_frame(piano_game, 30)

    assert_equal [:piano], seen[5], "the first note is sounding"
    assert_empty seen[15], "the rest silenced it"
    assert_equal [:piano], seen[25], "the next note plays it again"
  end

  # --- the voices, which the music and the game's own sounds share ---

  VOICES = RubyGBA::Audio::Sound::MIXER_VOICES
  CLIPS = VOICES + 2 # two more of the game's own sounds than there are voices
  private def clip_names(range) = range.map { |n| :"s#{n}" }

  # A game that starts CLIPS sounds of its own at once, two seconds long each, on pass +at+ — in
  # its game loop, where the burst lands inside one frame on both backends — beside +tune+. The
  # first sound loops when +loop_first+ says so.
  private def sharing_game(at:, loop_first: false, &tune)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song(:tune) { tempo 150; voice(:melody, plays: :piano, &tune) } # a quarter is 24 frames
      clips = (0...CLIPS).map { |n| sample :"s#{n}", pcm: [25 + n, -25 - n] * 8000, rate: 8000 }
      pass = var :pass, 0
      play_song :tune
      game_loop do
        pass.add! 1
        (pass == at).then { clips.each_with_index { |clip, n| clip.play(loop: loop_first && n.zero?) } }
      end
    end
    b.finalize_program
    b.program
  end

  # What each backend has sounding, +frames+ in.
  private def sounding_on_both(program, frames:)
    [game_player.run(program, frames: frames).active_samples,
     assert_emulator_loads_rom(assemble_rom(program, name: "SONGSHARE"), frames: frames + 2).sounding]
  end

  def test_changing_tunes_silences_the_instrument
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song(:tune) { voice(:melody, plays: :piano) { note :C4, :whole } }
      song(:beeps) { note :C5, :whole }
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass < 10).then { play_song :tune }.else { play_song :beeps }
      end
    end
    b.finalize_program
    seen = sounding_by_frame(b.program, 20)

    assert_equal [:piano], seen[5]
    assert_empty seen[15], "the square-wave tune took over, and the piano stopped with its tune"
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

  # --- the surface ---

  def test_the_instrument_handle_works_as_well_as_its_name
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      piano = instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song(:tune) { voice(:melody, plays: piano) { note :C4, :whole } }
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program

    assert_equal [:piano], game_player.run(b.program, frames: 3).active_samples
  end

end
