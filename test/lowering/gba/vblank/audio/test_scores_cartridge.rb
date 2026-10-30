# frozen_string_literal: true

require "test_helper"
require "all/vblank/audio/test_scores"

# Music handed over as data, on the Advance's cartridge: the bytes it is built to, and its
# voices, speaker and noise register read back in the emulator. What the songs do on every run,
# and the friendly errors, are in test/all/vblank/audio/test_scores.rb.
class TestScoresCartridge < Minitest::Test
  include ScoresGames

  STEP_ONE = GBA::Mixer::STEP_ONE

  # A step carries the note's pitch against the recorded one AND the resampling: the mix runs
  # at a rate the sound hardware can sustain (Console::SampleClock) rather than at the rate
  # these instruments were recorded at, so a note at the recorded pitch is not a step of 1.0.
  RECORDED_AT = 8000
  private def step_for(note)
    resample = RECORDED_AT.to_f / VBlank::Console::ADVANCE.sample_clock(RECORDED_AT).rate
    (NOTES[note].to_f / NOTES[:C4] * resample * STEP_ONE).round
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

  # --- a song that plays once ---

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

  # --- a noise note that names how fast its hiss steps ---

  # The console is told the rung in the noise voice's register, and those bits read back: the
  # low three are the divider and the four above the metallic bit are the halvings.
  def test_the_console_steps_a_noise_note_at_the_rate_it_names
    rom = assemble_rom(game([drums_at(131_072)]) { |music, _| music.play 0 }, name: "DRUMS")
    register = assert_emulator_loads_rom(rom, frames: 8).mem16(VBlank::Console::Hardware::REG_SOUND4CNT_H)

    assert_equal 131_072, VBlank::Audio::Sound.noise_rung_hz(register & 0x7, (register >> 4) & 0xF).round
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
end
