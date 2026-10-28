# frozen_string_literal: true

require "test_helper"

# A SQUARE NOTE'S OWN TONE SHAPE (its duty: how much of each wave is high), and a shape that
# changes a frame at a time while the note holds — a list of two or four shapes the music player
# steps through, one a frame, from the note's first frame on, round and round.
#
# The log names the shape a note or its part said at the end of its [:voice] entry, after its
# fade, slide, wobble and speaker, and says each change of a stepping shape as [:duty, voice, shape].
class TestSongDuties < Minitest::Test
  Duty = VBlank::Audio::Duty

  # One song, written by the block, played from the game's start; +each_frame+ is what the game
  # does each frame besides, given the frame's count.
  private def song_game(tempo: 150, each_frame: nil, &parts) # at 150 a quarter is 24 frames
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        tempo tempo
        instance_eval(&parts)
      end
      play_song :tune
      count = var :count, 0
      game_loop do
        count.add! 1
        instance_exec(count, &each_frame) if each_frame
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # Every [:voice] and [:duty] entry the run logged, with the frame it was logged on.
  private def duty_moves(program, frames:)
    i = game_player
    moves = []
    logged = 0
    i.each_vblank do |frame|
      i.audio.drop(logged).each { |entry| moves << [frame, *entry] if %i[voice duty].include?(entry.first) }
      logged = i.audio.size
    end
    i.run(program, frames: frames)
    moves
  end

  def test_a_note_says_its_own_shape
    moves = duty_moves(song_game do
      voice(:lead) { |v| v.duty :half; v.note :C5, :quarter; v.note :D5, :quarter, duty: :eighth }
    end, frames: 30)
    voices = moves.select { |_, kind, on, _, pitch| kind == :voice && on == 1 && pitch.positive? }

    assert_equal [nil, Duty.said(:eighth, where: "a note")], voices.map { |entry| entry[10] }.first(2)
  end

  # A SHAPE THAT STEPS: the note's first frame its first shape, then one a frame, round again.
  def test_a_pattern_steps_a_shape_a_frame_from_the_notes_start
    moves = duty_moves(song_game do
      voice(:lead) { |v| v.duty %i[eighth quarter half quarter]; v.note :C5, :whole }
    end, frames: 8)
    started = moves.find { |_, kind, on| kind == :voice && on == 1 }.first
    steps = moves.select { |_, kind| kind == :duty }.map { |frame, _, voice, shape| [frame - started, voice, shape] }

    assert_equal [[1, 1, :quarter], [2, 1, :half], [3, 1, :quarter], [4, 1, :eighth], [5, 1, :quarter]], steps.first(5)
  end

  # Two shapes take turns, and each note starts its pattern again from the first; a rest stops it.
  # A quarter is 25 frames here, an odd number, so a pattern that carried on into the second note
  # would be the other way round from one that starts again.
  def test_each_note_starts_its_pattern_again_and_a_rest_stops_it
    moves = duty_moves(song_game(tempo: 144) do
      voice :lead do |v|
        v.note :C5, :quarter, duty: %i[eighth half]
        v.note :D5, :quarter, duty: %i[eighth half]
        v.rest :quarter
      end
    end, frames: 75)
    starts = moves.select { |_, kind, on| kind == :voice && on == 1 }.map(&:first)
    steps = moves.select { |_, kind| kind == :duty }

    assert_equal %i[half eighth], steps.first(2).map(&:last), "it takes turns"
    second = steps.select { |frame, *| frame > starts[1] }
    assert_equal :half, second.first.last, "the second note starts from the first shape, and steps to the second"
    assert(steps.none? { |frame, *| frame > starts[2] }, "the rest stops it")
  end

  # Whether +log+ has a [:duty] entry before the first entry of kind +kind+, and after it.
  private def steps_around(log, kind)
    at = log.index { |entry| entry.first == kind }
    [log.take(at), log.drop(at)].map { |entries| entries.any? { |entry| entry.first == :duty } }
  end

  # THE GAME'S BEEP takes the second voice, and no part's pattern changes the beep's shape.
  def test_a_beep_stops_a_pattern_on_its_voice
    game = song_game(each_frame: ->(count) { (count == 10).then { beep 880 } }) do
      voice(:lead) { |v| v.rest :whole }
      voice(:harmony) { |v| v.duty %i[eighth half]; v.note :E4, :whole }
    end

    assert_equal [true, false], steps_around(game_player.run(game, frames: 30).audio, :beep),
                 "the harmony stepped before the beep, and not after it"
  end

  def test_a_song_stopped_steps_no_more
    game = song_game(each_frame: ->(count) { (count == 10).then { stop_music } }) do
      voice(:lead) { |v| v.duty %i[eighth half]; v.note :C5, :whole }
    end

    assert_equal [true, false], steps_around(game_player.run(game, frames: 30).audio, :stop_music)
  end

  # A SOUND EFFECT'S NOTE steps its shapes too, and its end stops them.
  def test_a_sound_effect_steps_its_shapes_until_it_ends
    score = VBlank::Audio::Score
    zap = score.new(tempo: 150, parts: [score::Part.new(duty: %i[eighth half], notes: [score::Note.new(at: 0, key: 76, length: 12)])])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      sfx = sound_effects :sfx, { zap: zap }
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 2).then { sfx.play :zap }
        wait_vblank
      end
    end
    b.finalize_program
    log = game_player.run(b.program, frames: 40).audio
    ended = log.rindex { |entry| entry.first == :voice && entry[3].zero? }

    assert(log.take(ended).any? { |entry| entry.first == :duty }, "the effect's note stepped")
    assert(log.drop(ended).none? { |entry| entry.first == :duty }, "and not after it ended")
  end

  # A SCORE SAYS IT THE SAME WAY: a part's `duty:` and a note's own.
  def test_a_score_says_its_notes_shapes
    score = VBlank::Audio::Score
    lead = score::Part.new(duty: %i[quarter half], notes: [score::Note.new(at: 0, key: 72, length: 24),
                                                           score::Note.new(at: 24, key: 74, length: 24, duty: :eighth)])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      songs(:music, [score.new(parts: [lead], tempo: 150)]).play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    voices = duty_moves(b.program, frames: 30).select { |_, kind, _, _, pitch| kind == :voice && pitch.positive? }

    assert_equal [Duty.said(%i[quarter half], where: "a part"), Duty.said(:eighth, where: "a note")],
                 voices.map { |entry| entry[10] }
  end

  # --- what a shape cannot be said of ---

  def test_a_shape_off_the_square_voices_is_refused
    error = assert_raises(ArgumentError) do
      song_game { voice(:pad, plays: :wave) { |v| v.note :C4, :quarter, duty: :eighth } }
    end

    assert_match(/:pad/, error.message)
    assert_match(/square/, error.message)
  end

  def test_a_pattern_of_three_shapes_says_what_it_can_be
    error = assert_raises(ArgumentError) { song_game { voice(:lead) { |v| v.duty %i[eighth quarter half] } } }

    assert_match(/two or four/, error.message)
  end
end
