# frozen_string_literal: true

require "test_helper"

require "stringio"

# A song part can play a recorded instrument instead of the square-wave voice:
# `voice :melody, plays: :piano do ... end`. Each note plays the instrument's recording at that
# note's pitch, through the mixer, and a rest silences it. The part names the instrument, never a
# channel — which voice it uses is the framework's business.
class TestSongInstruments < Minitest::Test
  NOTES = RubyGBA::Music::NOTE_FREQUENCIES
  STEP_ONE = GBA::Mixer::STEP_ONE

  # A piano recorded at C4, a second long — longer than any note here, so it is the next event
  # that ends a note rather than the recording running out.
  def piano_game(&extra)
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
    b.emit_pending_functions
    b.program
  end

  # What the interpreter has sounding after each of the first +frames+ frames.
  def sounding_by_frame(program, frames)
    seen = {}
    i = Reference.new
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

  def test_a_song_with_an_instrument_keeps_a_voice_for_it
    sfx = Builder.new
    sfx.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song(:tune) { voice(:melody, plays: :piano) { note :C4, :whole } }
      clips = (0...10).map { |n| sample :"s#{n}", pcm: [25 + n, -25 - n] * 2000, rate: 8000 }
      play_song :tune
      clips.each(&:play)
      game_loop { wait_vblank }
    end
    sfx.emit_pending_functions
    i = Reference.new.run(sfx.program, frames: 3)

    assert_equal %i[s0 s1 s2 s3 s4 s5 s6 piano], i.active_samples,
                 "the song's part keeps its own voice, so the game's own sounds get the other seven"
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
        pass.add 1
        (pass < 10).then { play_song :tune }.else { play_song :beeps }
      end
    end
    b.emit_pending_functions
    seen = sounding_by_frame(b.program, 20)

    assert_equal [:piano], seen[5]
    assert_empty seen[15], "the square-wave tune took over, and the piano stopped with its tune"
  end

  # --- the console ---

  def console_steps_at(frames)
    rom = assemble_rom(piano_game, name: "SONGINST")
    assert_emulator_loads_rom(rom, frames: frames).voices.map { |v| [v.sample, v.step] }
  end

  def step_for(note) = (NOTES[note].to_f / NOTES[:C4] * STEP_ONE).round

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

  def test_both_backends_keep_the_same_sounds_beside_a_song
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song(:tune) { voice(:melody, plays: :piano) { note :C4, :whole } }
      clips = (0...10).map { |n| sample :"s#{n}", pcm: [25 + n, -25 - n] * 2000, rate: 8000 }
      play_song :tune
      clips.each(&:play)
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    program = b.program

    interpreted = Reference.new.run(program, frames: 4).active_samples
    console = assert_emulator_loads_rom(assemble_rom(program, name: "SONGMIX"), frames: 8).sounding

    assert_equal interpreted, console
  end

  # While a recorded part rests, its voice sits idle — and it is still the music's. A burst of
  # the game's own sounds in the rest gets seven voices, not eight, on both backends; a sound
  # that took the music's voice would be cut off by the part's next note.
  def test_a_resting_part_keeps_its_voice_from_the_game
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song(:tune) { voice(:melody, plays: :piano) { note :C4, :quarter; rest :whole } }
      clips = (0...10).map { |n| sample :"s#{n}", pcm: [25 + n, -25 - n] * 8000, rate: 8000 }
      pass = var :pass, 0
      play_song :tune
      game_loop do
        pass.add 1
        (pass == 40).then { clips.each(&:play) } # thirty frames into the rest
      end
    end
    b.emit_pending_functions
    program = b.program

    interpreted = Reference.new.run(program, frames: 50).active_samples
    console = assert_emulator_loads_rom(assemble_rom(program, name: "SONGREST"), frames: 52).sounding

    assert_equal %i[s0 s1 s2 s3 s4 s5 s6], interpreted
    assert_equal interpreted, console
  end

  # --- the surface ---

  def test_an_instrument_nobody_declared_is_a_friendly_error
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("NOPIANO", code: "ZNOP", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        enable_sound
        song(:tune) { voice(:melody, plays: :piano) { note :C4, :quarter } }
        play_song :tune
        game_loop { wait_vblank }
      end
    end
    assert_match(/instrument :piano/, err.string)
  end

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
    b.emit_pending_functions

    assert_equal [:piano], Reference.new.run(b.program, frames: 3).active_samples
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
    b.emit_pending_functions
    report = RubyGBA::IR::Guardrails::Validator.new.run(b.program, autofix: false)

    refute(report.warnings.any? { |w| w.check == :channel_conflict })
  end
end
