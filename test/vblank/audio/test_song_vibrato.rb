# frozen_string_literal: true

require "test_helper"

# A SONG'S NOTES THAT WOBBLE THEIR PITCH — vibrato — on the square voices and the wave voice.
#
# No voice does this by itself, so the music player does it a frame at a time: once a note has
# sounded for a while, it moves the voice's pitch number up and then down below where the note
# began, a few frames each way, until the part's next note, without starting the note again. The
# log says each move as [:wobble, voice, steps], steps above (or below) the note's own pitch.
class TestSongVibrato < Minitest::Test
  Vibrato = VBlank::Audio::Vibrato

  # One song, written by the block, played from the game's start.
  private def song_game(&parts)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        tempo 150 # a quarter is 24 frames
        instance_eval(&parts)
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Every [:voice] and [:wobble] entry the run logged, with the frame it was logged on.
  private def voice_moves(program, frames:)
    i = game_player
    moves = []
    logged = 0
    i.each_vblank do |frame|
      i.audio.drop(logged).each { |entry| moves << [frame, *entry] if %i[voice wobble].include?(entry.first) }
      logged = i.audio.size
    end
    i.run(program, frames: frames)
    moves
  end

  # The wobbles on +voice+, as [frames after the voice's last note began, steps].
  private def wobbles_on(moves, voice)
    started = nil
    moves.filter_map do |frame, kind, on, *rest|
      next unless on == voice

      started = frame if kind == :voice
      [frame - started, rest.first] if kind == :wobble
    end
  end

  def test_a_note_wobbles_after_its_wait_swinging_up_then_down
    moves = voice_moves(song_game do
      voice :lead do |v|
        v.vibrato depth: 3, speed: 2, after: 4
        v.note :C5, :whole
      end
    end, frames: 20)

    assert_equal [[4, 2], [6, -1], [8, 2], [10, -1]], wobbles_on(moves, 1).first(4),
                 "two steps up (half of three, rounded up), then one below where it began, two frames each"
  end

  # The [:voice] entry names the note's wobble after its fade and slide, when it says one.
  def test_the_voice_is_told_the_notes_vibrato
    moves = voice_moves(song_game { voice(:lead) { |v| v.note :C5, :whole, vibrato: { depth: 5, speed: 3 } } }, frames: 4)
    voice = moves.find { |_, kind, on| kind == :voice && on == 1 }

    assert_equal [nil, nil, Vibrato.new(depth: 5, speed: 3, after: 0)], voice.last(3)
  end

  # THE WORDS: a depth and a speed by name, and a wait as a note length at the song's tempo.
  def test_the_words_say_a_depth_a_speed_and_a_wait
    moves = voice_moves(song_game do
      voice(:lead) { |v| v.vibrato depth: :slight, speed: :medium, after: :eighth; v.note :C5, :whole }
    end, frames: 4)

    assert_equal Vibrato.new(depth: 2, speed: 4, after: 12), moves.find { |_, kind| kind == :voice }.last
  end

  # A NOTE CAN SAY ITS OWN, and :none holds one still in a part that wobbles. The part's next note
  # starts its own wobble from its own beginning, and a rest stops it.
  def test_each_note_wobbles_from_its_own_beginning_and_none_holds_still
    moves = voice_moves(song_game do
      voice :lead do |v|
        v.vibrato depth: 2, speed: 1, after: 2
        v.note :C5, :quarter, vibrato: :none
        v.note :D5, :quarter
        v.rest :quarter
      end
    end, frames: 70)
    wobbles = moves.select { |_, kind| kind == :wobble }.map(&:first)
    starts = moves.select { |_, kind, on| kind == :voice && on == 1 }.map(&:first)

    refute_empty wobbles
    assert(wobbles.all? { |frame| frame >= starts[1] + 2 && frame < starts[2] },
           "only the second note wobbles, from two frames into it, and the rest stops it")
  end

  def test_the_wave_voice_wobbles_too
    moves = voice_moves(song_game do
      voice(:pad, plays: :wave) { |v| v.vibrato depth: 4, speed: 3; v.note :C4, :whole }
    end, frames: 12)

    assert_equal [[0, 2], [3, -2], [6, 2]], wobbles_on(moves, 3).first(3)
  end

  # A SCORE SAYS IT THE SAME WAY, for a game that converts another game's music: a part's
  # `vibrato:` and a note's own, the wait in frames.
  def test_a_score_says_how_its_notes_wobble
    score = VBlank::Audio::Score
    lead = score::Part.new(vibrato: { depth: 3, speed: 4, after: 18 },
                           notes: [score::Note.new(at: 0, key: 72, length: 24),
                                   score::Note.new(at: 24, key: 74, length: 24, vibrato: :none)])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      songs(:music, [score.new(parts: [lead], tempo: 150)]).play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    voices = voice_moves(b.program, frames: 30).select { |_, kind, _, _, pitch| kind == :voice && pitch.positive? }

    assert_equal [Vibrato.new(depth: 3, speed: 4, after: 18), Vibrato::NONE], voices.map(&:last)
  end

  # THE SLOWEST SWING IS SIXTEEN FRAMES, which is what a converted engine's slowest rate holds one
  # for: it counts a swing down from fifteen to nought.
  def test_the_slowest_swing_holds_sixteen_frames
    moves = voice_moves(song_game { voice(:lead) { |v| v.vibrato depth: 2, speed: 16; v.note :C5, :whole } },
                        frames: 40)

    assert_equal [[0, 1], [16, -1], [32, 1]], wobbles_on(moves, 1).first(3)
  end

  # THE GAME'S OWN SOUND TAKES A VOICE: a `beep` on the second square voice, while the song's
  # second part wobbles a note there, is not bent by it — the voice wobbles nothing until the
  # part's next note.
  def test_a_beep_takes_the_voice_from_a_wobbling_note
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        tempo 150
        voice(:lead) { |v| v.note :C5, :whole }
        voice(:harmony) { |v| v.vibrato depth: 4, speed: 2; v.note :E4, :whole }
      end
      play_song :tune
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 10).then { beep 880 }
        wait_vblank
      end
    end
    b.finalize_program
    log = game_player.run(b.program, frames: 30).audio
    after_beep = log.drop(log.index { |entry| entry.first == :beep })

    assert(log.take(log.index { |entry| entry.first == :beep }).any? { |entry| entry.first == :wobble },
           "the harmony wobbled before the beep")
    assert_empty after_beep.select { |entry| entry.first == :wobble }, "and not after it"
  end

  # --- what a wobble cannot be said of ---

  def test_the_drums_cannot_wobble
    error = assert_raises(ArgumentError) do
      song_game { voice(:drums, plays: :noise) { |v| v.vibrato depth: 2; v.note :C2, :quarter } }
    end

    assert_match(/:drums/, error.message)
    assert_match(/only a square part or the wave part can have vibrato/i, error.message)
  end

  def test_a_note_that_slides_and_wobbles_is_refused
    error = assert_raises(ArgumentError) do
      song_game { voice(:lead) { |v| v.vibrato depth: 2; v.note :C5, :quarter, slide_up: :fast } }
    end

    assert_match(/a slide and vibrato/, error.message)
  end

  def test_a_depth_that_is_not_one_says_what_it_can_be
    error = assert_raises(ArgumentError) { song_game { voice(:lead) { |v| v.vibrato depth: 20 } } }

    assert_match(/:slight, :medium, :wide/, error.message)
    assert_match(/1 to 15/, error.message)
  end
end
