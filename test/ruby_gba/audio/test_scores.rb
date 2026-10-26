# frozen_string_literal: true

require "test_helper"

require "stringio"

# MUSIC HANDED OVER AS DATA. A game whose music already exists as numbers — decoded out of
# another cartridge, read from a file — hands the framework Scores, and picks one to play by a
# number it works out as it runs: `music = songs :music, scores` then `music.play track`.
# Nothing about the tune is written in the program.
class TestScores < Minitest::Test
  Score = RubyGBA::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = RubyGBA::Audio::Music::NOTE_FREQUENCIES
  STEP_ONE = GBA::Mixer::STEP_ONE

  # A step carries the note's pitch against the recorded one AND the resampling: the mix runs
  # at a rate the sound hardware can sustain (Console::SampleClock) rather than at the rate
  # these instruments were recorded at, so a note at the recorded pitch is not a step of 1.0.
  RECORDED_AT = 8000
  private def step_for(note)
    resample = RECORDED_AT.to_f / RubyGBA::Console::ADVANCE.sample_clock(RECORDED_AT).rate
    (NOTES[note].to_f / NOTES[:C4] * resample * STEP_ONE).round
  end

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame — so a note's tick is the
  # frame it sounds on, counted from the frame the song starts.
  private def notes_every_ten_ticks(*keys, plays: nil, tempo: 150)
    notes = keys.each_with_index.map { |key, n| Note.new(at: n * 10, key: key) }
    Score.new(tempo: tempo, parts: [Part.new(plays: plays, notes: notes)])
  end

  # A game that hands over +scores+, names one each pass with the block, and otherwise does
  # nothing. The block is handed the song list and how many passes have run.
  private def game(scores, &body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      instrument :harp, pcm: [40, -40] * 4000, rate: 8000, note: :C4
      music = songs :music, scores
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        instance_exec(music, pass, &body)
      end
    end
    b.finalize_program
    b.program
  end

  # --- low notes ---

  # SAYING A SCORE'S LOW NOTES ARE INTENDED CHANGES WHAT THE BUILD SAYS, NOT WHAT IT BUILDS. A
  # note below the square-wave voice's 64 Hz is played at 64 Hz either way, because that is all
  # the voice can do: the cartridge is the same to the byte.
  def test_saying_the_low_notes_are_intended_builds_the_same_cartridge
    low = Part.new(notes: [Note.new(at: 0, key: 27), Note.new(at: 24, key: 60)])
    built = [false, true].map do |intended|
      program = game([Score.new(parts: [low], low_notes_intended: intended)]) { |music, _| music.play 0 }
      GBA.new.lower(program)
    end

    assert_equal built.first, built.last
  end

  def test_saying_it_with_anything_but_true_or_false_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: 60)])], low_notes_intended: :yes).to_song
    end
    assert_match(/must be true or false/, error.message)
  end

  # --- a song that plays once ---

  # Two notes ten frames apart in a song twenty frames long, which says it plays once.
  private def two_notes_once(**options)
    Score.new(tempo: 150, length: 20, plays_once: true, **options,
              parts: [Part.new(notes: [Note.new(at: 0, key: :C4), Note.new(at: 10, key: :E4)])])
  end

  # One note held for the whole of a song twenty frames long.
  private def held_note(plays: nil, **options)
    Score.new(tempo: 150, length: 20, **options, parts: [Part.new(plays: plays, notes: [Note.new(at: 0, key: :C5)])])
  end

  # The console's speaker says the same: the held note sounds, then nothing does for the rest
  # of the run — where the same song left to come round is still sounding at the end of it.
  def test_the_console_goes_quiet_when_a_song_that_plays_once_ends
    energy = lambda do |score|
      rom = assemble_rom(game([score]) { |music, _| music.play 0 }, name: "SCOREONCE")
      assert_emulator_loads_rom(rom, frames: 70).audio_energy_by_frame
    end
    once = energy.call(held_note(plays_once: true))
    round = energy.call(held_note)
    loud = round.max / 4

    assert_operator once[8..18].min, :>, loud, "the note sounds while the song plays (#{once.inspect})"
    assert_operator once[30..].max, :<, loud, "and nothing sounds once it has ended (#{once.inspect})"
    assert_operator round[30..].min, :>, loud, "a song that comes round is still sounding (#{round.inspect})"
  end

  # A part that plays a recording gives its mixer voice back at the end, and takes none again.
  def test_the_console_frees_the_voices_of_a_song_that_plays_once
    rom = assemble_rom(game([held_note(plays: :piano, plays_once: true)]) { |music, _| music.play 0 }, name: "SCOREFREE")
    console = assert_emulator_loads_rom(rom, frames: 12)

    assert_equal [:piano], console.voices.map(&:sample)
    console.step(20)
    assert_empty console.voices, "the song has ended"
    console.step(30)
    assert_empty console.voices, "and has not started again"
  end

  # Which recordings are sounding on each of sixty frames, on the interpreter and then on the
  # console, each counted from the first frame any is — so the two are laid side by side
  # whatever frame each one started on.
  private def recordings_by_frame(program)
    require_emulator!
    i = Reference.new
    interpreted = []
    i.each_vblank { interpreted << i.active_samples.sort }
    i.run(program, frames: 70)
    console = assert_emulator_loads_rom(assemble_rom(program, name: "SCOREEDGE"), frames: 1)
    on_console = Array.new(70) do
      console.step
      console.voices.map(&:sample).sort
    end
    [interpreted, on_console].map { |seen| seen.drop_while(&:empty?).first(60) }
  end

  # It lasts exactly its length on both: the voice holding the note sounds for twenty frames.
  def test_a_song_that_plays_once_lasts_its_length_on_both_backends
    program = game([held_note(plays: :piano, plays_once: true)]) { |music, _| music.play 0 }
    heard = ([[:piano]] * 20) + ([[]] * 40)

    assert_equal [heard, heard], recordings_by_frame(program)
  end

  # THE FRAME IT ENDS ON is where the two backends could part. Another song named on the pass
  # the player takes up on that very frame follows it with no gap and no overlap; named a pass
  # sooner, it cuts the last frame off.
  def test_another_song_named_as_it_ends_follows_it_on_both_backends
    scores = [held_note(plays: :piano, plays_once: true), notes_every_ten_ticks(:G4, plays: :harp)]
    named_on = lambda do |on|
      game(scores) do |music, pass|
        track = var :track, 0
        (pass == on).then { track.set! 1 }
        music.play track
      end
    end
    as_it_ends = ([[:piano]] * 20) + ([[:harp]] * 40)
    a_pass_sooner = ([[:piano]] * 19) + ([[:harp]] * 41)

    assert_equal [as_it_ends, as_it_ends], recordings_by_frame(named_on.call(21))
    assert_equal [a_pass_sooner, a_pass_sooner], recordings_by_frame(named_on.call(20))
  end

  # ...and stopped and named again on that pass, it plays straight through a second time.
  def test_a_stop_and_a_play_as_it_ends_plays_it_again_on_both_backends
    program = game([held_note(plays: :piano, plays_once: true)]) do |music, pass|
      (pass == 21).then { stop_music }
      music.play 0
    end
    twice = ([[:piano]] * 40) + ([[]] * 20)

    assert_equal [twice, twice], recordings_by_frame(program)
  end

  # A sound effect goes on being played after the song has ended, and while it plays: with no
  # tune playing, every effect is the player's to play.
  def test_sound_effects_play_during_and_after_a_song_that_plays_once
    song = held_note(plays: :piano, plays_once: true)
    ping = Score.new(tempo: 150, length: 6, parts: [Part.new(plays: :harp, notes: [Note.new(at: 0, key: :G4)])])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      instrument :harp, pcm: [40, -40] * 4000, rate: 8000, note: :C4
      music = songs :music, [song]
      sfx = sound_effects :sfx, { ping: ping }
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        music.play 0
        ((pass == 10) | (pass == 30)).then { sfx.play :ping }
      end
    end
    b.finalize_program
    heard = ([[:piano]] * 9) + ([%i[harp piano]] * 6) + ([[:piano]] * 5) + ([[]] * 9) + ([[:harp]] * 6) + ([[]] * 25)

    assert_equal [heard, heard], recordings_by_frame(b.program)
  end

  # Stopped and named again long after it ended, the console plays it from its first note: the
  # voice is back, and near the start of the recording.
  def test_the_console_starts_a_song_that_ended_over_on_a_stop_and_a_play
    program = game([held_note(plays: :piano, plays_once: true)]) do |music, pass|
      (pass == 40).then { stop_music }
      music.play 0
    end
    console = assert_emulator_loads_rom(assemble_rom(program, name: "SCOREBACK"), frames: 36)

    assert_empty console.voices, "ended, and still named every pass"
    console.step(12)
    assert_equal [:piano], console.voices.map(&:sample)
    assert_operator console.voices.first.position, :<, RECORDED_AT / 4, "from its first note"
  end

  # ...and the same after another song has been named: that one plays, and then the song that
  # ended plays from its first note.
  def test_the_console_starts_a_song_that_ended_over_after_another_song
    scores = [held_note(plays: :piano, plays_once: true), notes_every_ten_ticks(:G4, plays: :harp)]
    program = game(scores) do |music, pass|
      track = var :track, 0
      (pass == 40).then { track.set! 1 }
      (pass == 50).then { track.set! 0 }
      music.play track
    end
    console = assert_emulator_loads_rom(assemble_rom(program, name: "SCORENEXT"), frames: 36)

    assert_empty console.voices, "ended"
    console.step(10)
    assert_equal [:harp], console.voices.map(&:sample), "the other song"
    console.step(12)
    assert_equal [:piano], console.voices.map(&:sample)
    assert_operator console.voices.first.position, :<, RECORDED_AT / 4, "from its first note"
  end

  # --- a note's length, instrument and loudness ---

  def test_a_note_can_change_instrument_and_loudness_on_the_console
    score = Score.new(tempo: 150, length: 60, parts: [Part.new(plays: :piano, notes: [
      Note.new(at: 0, key: :C4),
      Note.new(at: 20, key: :E4, instrument: :harp, volume: 6),
    ])])
    rom = assemble_rom(game([score]) { |music, _| music.play 0 }, name: "SCORENOTE")

    early = assert_emulator_loads_rom(rom, frames: 10).voices
    later = assert_emulator_loads_rom(rom, frames: 30).voices

    assert_equal [:piano], early.map(&:sample)
    assert_equal [:harp], later.map(&:sample), "the second note names its own instrument"
    assert_in_delta step_for(:E4), later.first.step, 2
    assert_equal (6 * 512 / 15.0).round, later.first.volume, "...and its own loudness"
  end

  # A RECORDED NOTE CAN BE GIVEN A VOLUME WITH A FRACTION, for music whose engine works its
  # loudness out finer than sixteen steps. A volume of 15 x L / 512 plays the recording at L
  # 512ths of its size. A cartridge's own engine keeps a voice's right and left volumes and
  # mixes by their sum, out of 512, so a note keeps the odd half a sum can have: 51 is 25 and a
  # half 256ths, where rounded to 256ths it would be 26.
  private def engine_levels_score(*levels, envelope: nil)
    notes = levels.each_with_index.map { |level, n| Note.new(at: n * 10, key: :C4, volume: Rational(15 * level, 512)) }
    Score.new(tempo: 150, length: levels.size * 10, parts: [Part.new(plays: :piano, envelope: envelope, notes: notes)])
  end

  def test_the_console_gives_a_recorded_note_the_loudness_its_volume_gives
    rom = assemble_rom(game([engine_levels_score(512, 51)]) { |music, _| music.play 0 }, name: "SCORE512")

    assert_equal [51], assert_emulator_loads_rom(rom, frames: 20).voices.map(&:volume)
  end

  def test_a_volume_with_a_fraction_on_a_console_voice_is_a_friendly_error
    square = Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: :C4, volume: 7.5)])])
    assert_match(/whole number/, build_error { songs :music, [square] })
  end

  # --- a noise note that names how fast its hiss steps ---

  # A MIDI key reaches no further than 12,543 Hz, and the noise voice steps as fast as 524,288
  # times a second, so a drum decoded off another cartridge says its rate with `hz:` instead.
  private def drums_at(*rates, plays: :noise)
    notes = rates.each_with_index.map { |rate, n| Note.new(at: n * 4, hz: rate) }
    Score.new(tempo: 150, parts: [Part.new(plays: plays, notes: notes)])
  end

  # The console is told the rung in the noise voice's register, and those bits read back: the
  # low three are the divider and the four above the metallic bit are the halvings.
  def test_the_console_steps_a_noise_note_at_the_rate_it_names
    rom = assemble_rom(game([drums_at(131_072)]) { |music, _| music.play 0 }, name: "DRUMS")
    register = assert_emulator_loads_rom(rom, frames: 8).mem16(RubyGBA::Console::Hardware::REG_SOUND4CNT_H)

    assert_equal 131_072, RubyGBA::Audio::Sound.noise_rung_hz(register & 0x7, (register >> 4) & 0xF).round
  end

  def test_the_console_plays_the_song_a_number_picks
    scores = [notes_every_ten_ticks(:C4, plays: :piano), notes_every_ten_ticks(:G4, plays: :harp)]
    rom = assemble_rom(game(scores) do |music, _|
      track = var :track, 1
      music.play track
    end, name: "SCOREPICK")
    playing = assert_emulator_loads_rom(rom, frames: 8).voices

    assert_equal [:harp], playing.map(&:sample)
    assert_in_delta step_for(:G4), playing.first.step, 2
  end

  # Stopped and named again in one frame, the console starts the song over: the voice playing
  # its one long note is back near the start of the recording, where a song left alone is well
  # into it.
  def test_the_console_starts_a_song_over_on_a_stop_and_a_play
    held = Score.new(tempo: 150, length: 600, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :C4)])])
    restarted = game([held]) do |music, pass|
      (pass == 20).then { stop_music }
      music.play 0
    end
    left_alone = game([held]) { |music, _| music.play 0 }
    how_far = lambda do |program|
      assert_emulator_loads_rom(assemble_rom(program, name: "SCOREAGAIN"), frames: 26).voices.first.position
    end

    assert_operator how_far.call(restarted), :<, how_far.call(left_alone) / 2
  end

  def test_the_console_leaves_the_music_alone_for_a_number_naming_no_song
    scores = [notes_every_ten_ticks(:C4, plays: :piano), notes_every_ten_ticks(:G4, plays: :harp)]
    rom = assemble_rom(game(scores) do |music, pass|
      track = var :track, 1
      (pass == 10).then { track.set! 9 }
      music.play track
    end, name: "SCORENONE")

    assert_equal [:harp], assert_emulator_loads_rom(rom, frames: 20).voices.map(&:sample)
  end

  # --- what cannot be had, said plainly ---

  private def build_error(&program)
    err = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        enable_sound
        instance_exec(&program)
      end
    end
    err.message
  end

  def test_something_that_is_not_a_score_is_a_friendly_error
    assert_match(/Score/, build_error { songs :music, [:title_theme] })
  end

  def test_a_note_before_the_start_is_a_friendly_error
    bad = Score.new(parts: [Part.new(notes: [Note.new(at: -4, key: :C4)])])
    assert_match(/tick/, build_error { songs :music, [bad] })
  end

  def test_a_rate_on_a_part_that_is_not_the_noise_voice_is_a_friendly_error
    pad = drums_at(440, plays: :wave)
    message = build_error { songs :music, [pad] }

    assert_match(/only a part on the noise voice/i, message)
    assert_match(/key:/, message, "says what the part gives instead")
  end

  def test_a_note_with_both_a_key_and_a_rate_is_a_friendly_error
    both = Score.new(parts: [Part.new(plays: :noise, notes: [Note.new(at: 0, key: 60, hz: 131_072)])])

    assert_match(/both/, build_error { songs :music, [both] })
  end

  def test_a_rate_the_noise_voice_cannot_make_is_a_friendly_error
    [0, -5, 600_000, "fast"].each do |rate|
      drums = drums_at(rate)
      assert_match(/524,288/, build_error { songs :music, [drums] }, "hz: #{rate.inspect}")
    end
  end

  def test_a_written_number_past_the_last_song_is_a_friendly_error
    song = notes_every_ten_ticks(:C4)
    message = build_error { songs(:music, [song, song]).play 5 }
    assert_match(/2 songs/, message)
  end

  def test_a_song_that_plays_once_and_loops_is_a_friendly_error
    both = Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: :C4), Note.new(at: 48, key: :E4)])],
                     plays_once: true, loop_from: 24)

    assert_match(/plays once.*does not loop/m, build_error { songs :music, [both] })
  end

  def test_saying_plays_once_with_anything_but_true_or_false_is_a_friendly_error
    odd = Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: :C4)])], plays_once: 1)

    assert_match(/plays_once.*must be true or false/m, build_error { songs :music, [odd] })
  end

  # A sound effect plays once whatever its Score says, so one that says so is taken as it is:
  # a decoder hands over the same Score whether the game plays it as a song or as an effect.
  def test_a_sound_effect_may_say_it_plays_once
    b = Builder.new
    effect = two_notes_once
    b.instance_eval do
      screen :bitmap
      enable_sound
      sfx = sound_effects :sfx, { ping: effect }
      game_loop { pressed(:a).then { sfx.play :ping } }
    end
    b.finalize_program
    i = game_player.input_each_frame { |frame| frame == 3 ? [:a] : [] }.run(b.program, frames: 40)

    assert_equal [NOTES[:C4], NOTES[:E4]], i.audio.select { |entry| entry[0] == :note }.map(&:last).reject(&:zero?)
  end

  def test_a_name_the_list_does_not_have_is_a_friendly_error
    song = notes_every_ten_ticks(:C4)
    assert_match(/:credits/, build_error { songs(:music, { title: song }).play :credits })
  end
end
