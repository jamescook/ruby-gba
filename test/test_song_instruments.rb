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

  # --- the voices, which the music and the game's own sounds share ---

  VOICES = RubyGBA::Sound::MIXER_VOICES
  CLIPS = VOICES + 2 # two more of the game's own sounds than there are voices
  def clip_names(range) = range.map { |n| :"s#{n}" }

  # A game that starts CLIPS sounds of its own at once, two seconds long each, on pass +at+ — in
  # its game loop, where the burst lands inside one frame on both backends — beside +tune+. The
  # first sound loops when +loop_first+ says so.
  def sharing_game(at:, loop_first: false, &tune)
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
        pass.add 1
        (pass == at).then { clips.each_with_index { |clip, n| clip.play(loop: loop_first && n.zero?) } }
      end
    end
    b.emit_pending_functions
    b.program
  end

  # What each backend has sounding, +frames+ in.
  def sounding_on_both(program, frames:)
    [Reference.new.run(program, frames: frames).active_samples,
     assert_emulator_loads_rom(assemble_rom(program, name: "SONGSHARE"), frames: frames + 2).sounding]
  end

  # A note already sounding keeps its voice, and the game's burst gets every voice left.
  def test_a_sounding_note_keeps_its_voice_and_the_game_gets_the_rest
    interpreted, console = sounding_on_both(sharing_game(at: 5) { note :C4, :whole }, frames: 10)

    assert_equal [:piano] + clip_names(0...(VOICES - 1)), interpreted
    assert_equal interpreted, console
  end

  # A part's next note takes over the voice its last note is still sounding in, rather than
  # taking a second one and leaving the first to ring on underneath it.
  def test_a_parts_next_note_takes_over_its_own_voice
    interpreted, console = sounding_on_both(sharing_game(at: 999) { note :C4, :quarter; note :G4, :whole }, frames: 40)

    assert_equal [:piano], interpreted
    assert_equal interpreted, console
  end

  # A part that rests gives its voice up: while it rests, every voice is the game's.
  def test_a_resting_part_lends_its_voice_to_the_game
    interpreted, console = sounding_on_both(sharing_game(at: 40) { note :C4, :quarter; rest :whole },
                                            frames: 50)

    assert_equal clip_names(0...VOICES), interpreted, "all of them the game's, the part resting"
    assert_equal interpreted, console
  end

  # THE MOMENT THE VOICES RUN OUT: every voice is the game's when the part's note comes, so the
  # note takes the voice of the game's sound that has played longest.
  def test_a_note_with_no_voice_free_takes_the_one_the_game_started_first
    interpreted, console = sounding_on_both(sharing_game(at: 5) { rest :quarter; note :C4, :whole }, frames: 40)

    assert_equal [:piano] + clip_names(1...VOICES), interpreted, "s0, the oldest, gave way"
    assert_equal interpreted, console
  end

  # ...one that plays once before one that loops, since a loop never ends of its own accord.
  def test_a_sound_that_loops_gives_way_last
    program = sharing_game(at: 5, loop_first: true) { rest :quarter; note :C4, :whole }
    interpreted, console = sounding_on_both(program, frames: 40)

    assert_equal [:s0, :piano] + clip_names(2...VOICES), interpreted, "s0 loops, so s1 gave way"
    assert_equal interpreted, console
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
