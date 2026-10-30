# frozen_string_literal: true

require "test_helper"
require "mixed_sound"

# The game these tests play and a song for it, kept once for this file and for the test of the
# same songs on the Advance's cartridge
# (test/lowering/gba/vblank/audio/test_scores_on_the_advance_cartridge.rb).
module ScoresOnTheAdvanceGames
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  # A game that hands over +scores+, names one each pass with the block, and otherwise does
  # nothing. The block is handed the song list and how many passes have run.
  private def game(scores, &body)
    b = VBlank::Builder.new
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

  # One note held for the whole of a song twenty frames long.
  private def held_note(plays: nil, **options)
    Score.new(tempo: 150, length: 20, **options, parts: [Part.new(plays: plays, notes: [Note.new(at: 0, key: :C5)])])
  end

  # A held note in a song that plays once, with the music volume halved on pass 8 and put back
  # on pass 40, after the song has ended.
  private def volume_moved_on_a_song_played_once
    game([held_note(plays_once: true)]) do |music, pass|
      music.play 0
      (pass == 8).then { music_volume 50 }
      (pass == 40).then { music_volume 100 }
    end
  end
end

# The tests of test_scores.rb whose games bring in recorded instruments for their songs to play,
# which a Game Boy Color's hardware cannot play, so they play on the Advance's runs alone. What
# the Advance's cartridge itself sounds like is heard in
# test/lowering/gba/vblank/audio/test_scores_on_the_advance_cartridge.rb.
class TestScoresOnTheAdvance < Minitest::Test
  include MixedSound
  include ScoresOnTheAdvanceGames

  NOTES = VBlank::Audio::Music::NOTE_FREQUENCIES

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame — so a note's tick is the
  # frame it sounds on, counted from the frame the song starts.
  private def notes_every_ten_ticks(*keys, plays: nil, tempo: 150)
    notes = keys.each_with_index.map { |key, n| Note.new(at: n * 10, key: key) }
    Score.new(tempo: tempo, parts: [Part.new(plays: plays, notes: notes)])
  end

  # Which notes sounded on which frame.
  private def notes_by_frame(program, frames)
    i = game_player
    heard = {}
    logged = 0
    i.each_vblank do |frame|
      fresh = i.audio.drop(logged).select { |entry| entry[0] == :note }.map(&:last)
      logged = i.audio.size
      heard[frame] = fresh unless fresh.empty?
    end
    i.run(program, frames: frames)
    heard
  end

  # Two notes ten frames apart in a song twenty frames long, which says it plays once.
  private def two_notes_once(**options)
    Score.new(tempo: 150, length: 20, plays_once: true, **options,
              parts: [Part.new(notes: [Note.new(at: 0, key: :C4), Note.new(at: 10, key: :E4)])])
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

  # The loudest byte of each note's sound, in turn.
  private def loudest_of_each_note(score)
    i = game_player
    i.run(game([score]) { |music, _| music.play 0 }, frames: score.length + 2)
    i.mixed_sound.map(&:max).reject(&:zero?).chunk_while { |a, b| a == b }.map(&:first)
  end

  # A MIDI key reaches no further than 12,543 Hz, and the noise voice steps as fast as 524,288
  # times a second, so a drum decoded off another cartridge says its rate with `hz:` instead.
  # These are rates the voice really makes: each one is a rung of its ladder, every rung past
  # 13,107 being one no key can reach.
  RUNGS = [9_362, 10_922, 13_107, 16_384, 131_072, 524_288].freeze

  private def drums_at(*rates, plays: :noise)
    notes = rates.each_with_index.map { |rate, n| Note.new(at: n * 4, hz: rate) }
    Score.new(tempo: 150, parts: [Part.new(plays: plays, notes: notes)])
  end

  # The rate a hit was played at, as the rung of the ladder it landed on.
  private def rung_played(pitch)
    VBlank::Audio::Sound.noise_rung_hz(*VBlank::Audio::Sound.noise_rung(pitch)).round
  end

  # --- ticks into frames ---

  def test_a_scores_ticks_become_frames
    program = game([notes_every_ten_ticks(:C4, :E4, :G4)]) { |music, _| music.play 0 }

    # named on the first pass, taken up at the frame after
    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]], 22 => [NOTES[:G4]] }, notes_by_frame(program, 25))
  end

  def test_a_tempo_change_speeds_the_rest_of_the_song_up
    score = Score.new(tempo: [[0, 150], [20, 300]], parts: [Part.new(notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 30, key: :G4),
    ])])
    program = game([score]) { |music, _| music.play 0 }

    # ten ticks at twice the tempo are five frames, not ten
    assert_equal({ 2 => [NOTES[:C4]], 22 => [NOTES[:E4]], 27 => [NOTES[:G4]] }, notes_by_frame(program, 30))
  end

  def test_a_midi_note_number_is_tuned_from_a_440
    program = game([notes_every_ten_ticks(69, 81)]) { |music, _| music.play 0 }

    assert_equal({ 2 => [440.0], 12 => [880.0] }, notes_by_frame(program, 15))
  end

  def test_the_song_played_is_the_one_a_number_names
    scores = [notes_every_ten_ticks(:C4), notes_every_ten_ticks(:E4), notes_every_ten_ticks(:G4)]
    program = game(scores) do |music, pass|
      track = var :track, 2
      (pass == 15).then { track.set! 1 }
      music.play track
    end

    assert_equal({ 2 => [NOTES[:G4]], 16 => [NOTES[:E4]] }, notes_by_frame(program, 20),
                 "song 2 first, then song 1 from its beginning once the number changes")
  end

  def test_a_number_naming_no_song_leaves_the_music_alone
    program = game([notes_every_ten_ticks(:C4, :E4)]) do |music, pass|
      track = var :track, 0
      (pass == 5).then { track.set! 7 }
      music.play track
    end

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]] }, notes_by_frame(program, 15))
  end

  # A song picked from the list by a number the game holds plays its part on a recording.
  def test_the_song_a_number_picks_plays_its_recording
    scores = [notes_every_ten_ticks(:C4, plays: :piano), notes_every_ten_ticks(:G4, plays: :harp)]
    program = game(scores) do |music, _|
      track = var :track, 1
      music.play track
    end
    sounding = []
    i = game_player
    i.each_vblank { sounding << i.active_samples }
    i.run(program, frames: 6)

    assert_equal [[:harp]], sounding.drop_while(&:empty?).uniq
  end

  def test_a_hash_of_scores_is_played_by_name
    scores = { title: notes_every_ten_ticks(:C4), file: notes_every_ten_ticks(:A4) }
    program = game(scores) { |music, _| music.play :file }

    assert_equal({ 2 => [NOTES[:A4]] }, notes_by_frame(program, 5))
  end

  def test_stopping_and_playing_again_in_one_frame_starts_the_song_over
    program = game([notes_every_ten_ticks(:C4, :E4, :G4)]) do |music, pass|
      (pass == 15).then { stop_music }
      music.play 0
    end

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]], 16 => [NOTES[:C4]] }, notes_by_frame(program, 20),
                 "stopped and named again on pass 15, the song begins again on the next frame")
  end

  def test_stopping_keeps_it_stopped
    program = game([notes_every_ten_ticks(:C4, :E4, :G4)]) do |music, pass|
      (pass < 5).then { music.play 0 }.else { music.stop }
    end

    assert_equal({ 2 => [NOTES[:C4]] }, notes_by_frame(program, 25))
  end

  # It ends where its length says and is not heard again, though the game goes on naming it
  # every pass: naming the song already named changes nothing, whether or not it has ended.
  def test_a_song_that_plays_once_does_not_come_round
    program = game([two_notes_once]) { |music, _| music.play 0 }

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]] }, notes_by_frame(program, 70))
  end

  # A song that has ended is started the way any song is started over: stop the music and name
  # it, in the same pass or a later one.
  def test_a_song_that_ended_starts_over_after_a_stop
    program = game([two_notes_once]) do |music, pass|
      (pass == 40).then { stop_music }
      music.play 0
    end

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]], 41 => [NOTES[:C4]], 51 => [NOTES[:E4]] },
                 notes_by_frame(program, 70), "stopped and named on pass 40, it plays once more and ends again")
  end

  # The stop and the naming can be passes apart.
  def test_a_song_that_ended_starts_over_when_named_some_passes_after_a_stop
    program = game([two_notes_once]) do |music, pass|
      (pass < 40).then { music.play 0 }
      (pass == 40).then { stop_music }
      (pass >= 45).then { music.play 0 }
    end

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]], 46 => [NOTES[:C4]], 56 => [NOTES[:E4]] },
                 notes_by_frame(program, 70))
  end

  # ...or name another song first.
  def test_a_song_that_ended_starts_over_after_another_song
    program = game([two_notes_once, notes_every_ten_ticks(:G4)]) do |music, pass|
      track = var :track, 0
      (pass == 40).then { track.set! 1 }
      (pass == 45).then { track.set! 0 }
      music.play track
    end

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]], 41 => [NOTES[:G4]], 46 => [NOTES[:C4]], 56 => [NOTES[:E4]] },
                 notes_by_frame(program, 70))
  end

  # The fades reach it as they reach any song: faded out and back in before it ends, its note
  # steps through the same volumes as the same song left to come round, down to nothing and
  # back to the written 12.
  def test_the_music_fades_reach_a_song_that_plays_once
    volumes = lambda do |score|
      program = game([score]) do |music, pass|
        music.play 0
        (pass == 4).then { fade_music_out frames: 4 }
        (pass == 12).then { fade_music_in frames: 4 }
      end
      game_player.run(program, frames: 20).audio.select { |entry| entry[0] == :loudness }.map(&:last)
    end
    once = volumes.call(held_note(plays_once: true))

    assert_equal volumes.call(held_note), once
    assert_includes once, 0
    assert_equal [12, 12], [once.first, once.last]
  end

  # The music volume reaches it like any song while it plays: halved on pass 8, the held note
  # is set again at half. Moved after the song has ended, it sets nothing, since nothing is held.
  def test_the_music_volume_reaches_a_song_that_plays_once_until_it_ends
    set = game_player.run(volume_moved_on_a_song_played_once, frames: 60)
                     .audio.select { |entry| entry[0] == :loudness }.map { |entry| entry.drop(1) }
    assert_equal [[1, 12], [1, 6]], set, "the first square voice, at the written 12 and then at half"
  end

  def test_a_note_with_a_length_goes_quiet_when_it_runs_out
    score = Score.new(tempo: 150, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :C4, length: 5)])],
                      length: 30)
    program = game([score]) { |music, _| music.play 0 }
    i = game_player
    seen = {}
    i.each_vblank { |frame| seen[frame] = i.active_samples }
    i.run(program, frames: 10)

    assert_equal [:piano], seen[4]
    assert_empty seen[8], "five ticks on, the note is over"
  end

  def test_a_recorded_note_plays_at_the_512ths_its_volume_gives
    # The piano's recording swings to 60: 60 at its own size, then 60 x 252, x 51 and x 10 / 512.
    assert_equal [60, 29, 5, 1], loudest_of_each_note(engine_levels_score(512, 252, 51, 10)).first(4)
  end

  # A shaped note works its loudness out once a frame as a whole number of 256ths, the engine's
  # own (level x (right + left)) >> 9, so held at full a note at 51 is 25 256ths, not 26.
  def test_a_shaped_note_at_full_drops_its_half_a_step_as_the_engine_does
    held = VBlank::Audio::Envelope.new(release: 216)

    # 60 x 25 / 256 is 5; at 26 it would be 6.
    assert_equal [5], loudest_of_each_note(engine_levels_score(51, envelope: held)).uniq
  end

  def test_the_console_mixes_a_note_with_half_a_step_as_the_interpreter_does
    plain = game([engine_levels_score(51, 10)]) { |music, _| music.play 0 }
    shaped = game([engine_levels_score(51, 10, envelope: VBlank::Audio::Envelope.new(release: 216))]) { |music, _| music.play 0 }

    assert_mixes_agree(plain, frames: 24)
    assert_mixes_agree(shaped, frames: 24)
  end

  # A volume that comes to less than half a 512th is a rest: the note takes no voice.
  def test_a_recorded_note_too_quiet_for_one_step_is_a_rest
    i = game_player
    seen = {}
    i.each_vblank { |frame| seen[frame] = i.active_samples }
    i.run(game([engine_levels_score(512, 0.4)]) { |music, _| music.play 0 }, frames: 20)

    assert_equal [:piano], seen[5]
    assert_empty seen[15], "the second note is a rest"
  end

  def test_a_noise_note_steps_at_the_rate_it_names
    program = game([drums_at(*RUNGS)]) { |music, _| music.play 0 }
    hits = game_player.run(program, frames: (RUNGS.size * 4) + 2).audio
                      .select { |entry| entry.first == :noise }.map(&:last).compact

    assert_equal RUNGS, hits.map { |hit| rung_played(hit[:pitch]) }
  end
end
