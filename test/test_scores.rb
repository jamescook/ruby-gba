# frozen_string_literal: true

require "test_helper"

require "stringio"

# MUSIC HANDED OVER AS DATA. A game whose music already exists as numbers — decoded out of
# another cartridge, read from a file — hands the framework Scores, and picks one to play by a
# number it works out as it runs: `music = songs :music, scores` then `music.play track`.
# Nothing about the tune is written in the program.
class TestScores < Minitest::Test
  Score = RubyGBA::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = RubyGBA::Music::NOTE_FREQUENCIES
  STEP_ONE = GBA::Mixer::STEP_ONE

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame — so a note's tick is the
  # frame it sounds on, counted from the frame the song starts.
  def notes_every_ten_ticks(*keys, plays: nil, tempo: 150)
    notes = keys.each_with_index.map { |key, n| Note.new(at: n * 10, key: key) }
    Score.new(tempo: tempo, parts: [Part.new(plays: plays, notes: notes)])
  end

  # A game that hands over +scores+, names one each pass with the block, and otherwise does
  # nothing. The block is handed the song list and how many passes have run.
  def game(scores, &body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      instrument :harp, pcm: [40, -40] * 4000, rate: 8000, note: :C4
      music = songs :music, scores
      pass = var :pass, 0
      game_loop do
        pass.add 1
        instance_exec(music, pass, &body)
      end
    end
    b.emit_pending_functions
    b.program
  end

  # Which notes sounded on which frame, from the interpreter.
  def notes_by_frame(program, frames)
    i = Reference.new
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

  # --- picked by a number the game works out ---

  def test_the_song_played_is_the_one_a_number_names
    scores = [notes_every_ten_ticks(:C4), notes_every_ten_ticks(:E4), notes_every_ten_ticks(:G4)]
    program = game(scores) do |music, pass|
      track = var :track, 2
      (pass == 15).then { track.set 1 }
      music.play track
    end

    assert_equal({ 2 => [NOTES[:G4]], 16 => [NOTES[:E4]] }, notes_by_frame(program, 20),
                 "song 2 first, then song 1 from its beginning once the number changes")
  end

  def test_a_number_naming_no_song_leaves_the_music_alone
    program = game([notes_every_ten_ticks(:C4, :E4)]) do |music, pass|
      track = var :track, 0
      (pass == 5).then { track.set 7 }
      music.play track
    end

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]] }, notes_by_frame(program, 15))
  end

  def test_a_hash_of_scores_is_played_by_name
    scores = { title: notes_every_ten_ticks(:C4), file: notes_every_ten_ticks(:A4) }
    program = game(scores) { |music, _| music.play :file }

    assert_equal({ 2 => [NOTES[:A4]] }, notes_by_frame(program, 5))
  end

  # --- stop and restart ---

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

  # --- a note's length, instrument and loudness ---

  def test_a_note_with_a_length_goes_quiet_when_it_runs_out
    score = Score.new(tempo: 150, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :C4, length: 5)])],
                      length: 30)
    program = game([score]) { |music, _| music.play 0 }
    i = Reference.new
    seen = {}
    i.each_vblank { |frame| seen[frame] = i.active_samples }
    i.run(program, frames: 10)

    assert_equal [:piano], seen[4]
    assert_empty seen[8], "five ticks on, the note is over"
  end

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
    assert_in_delta (NOTES[:E4].to_f / NOTES[:C4] * STEP_ONE).round, later.first.step, 2
    assert_equal (6 * 64 / 15.0).round, later.first.volume, "...and its own loudness"
  end

  def test_the_console_plays_the_song_a_number_picks
    scores = [notes_every_ten_ticks(:C4, plays: :piano), notes_every_ten_ticks(:G4, plays: :harp)]
    rom = assemble_rom(game(scores) do |music, _|
      track = var :track, 1
      music.play track
    end, name: "SCOREPICK")
    playing = assert_emulator_loads_rom(rom, frames: 8).voices

    assert_equal [:harp], playing.map(&:sample)
    assert_in_delta (NOTES[:G4].to_f / NOTES[:C4] * STEP_ONE).round, playing.first.step, 2
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
      (pass == 10).then { track.set 9 }
      music.play track
    end, name: "SCORENONE")

    assert_equal [:harp], assert_emulator_loads_rom(rom, frames: 20).voices.map(&:sample)
  end

  # --- what cannot be had, said plainly ---

  def build_error(&program)
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

  def test_a_written_number_past_the_last_song_is_a_friendly_error
    song = notes_every_ten_ticks(:C4)
    message = build_error { songs(:music, [song, song]).play 5 }
    assert_match(/2 songs/, message)
  end

  def test_a_name_the_list_does_not_have_is_a_friendly_error
    song = notes_every_ten_ticks(:C4)
    assert_match(/:credits/, build_error { songs(:music, { title: song }).play :credits })
  end
end
