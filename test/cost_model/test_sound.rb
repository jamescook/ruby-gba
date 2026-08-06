# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# Sound is per-frame work too: playing a song re-checks every note against a frame
# counter on *every* frame (the score is unrolled into one comparison per note), so
# a long tune is real recurring work, and a beep is a small burst of sound-register
# writes. The model prices both in the same scanline unit as drawing, so they weigh
# against the same budget. Built straight from the IR so the score is explicit.
class TestSoundCost < CostModelTest
  include RubyGBA::IR::Build
  include CostArith

  Cost = RubyGBA::IR::CostModel

  # A playing song costs per active VOICE, not per note (the sequencer touches only
  # the note currently due each frame). song_of makes a one-voice tune.
  def song_frame_cost(_notes = nil) = WEIGHTS[:music_voice]

  # An +n+-note song: n [frame, frequency] events, looping at frame n.
  def song_of(n)
    song(:theme, events: Array.new(n) { |i| [i, 440] }, total_frames: n)
  end

  # A game that plays an +n+-note song every frame, optionally drawing +draw+ too.
  def music_game(n, draw: nil)
    program(
      screen(:bitmap),
      song_of(n),
      loop_(wait_vblank, play_song(:theme), *[draw].compact),
    )
  end

  # Playing a song costs per active voice, not per note: the sequencer keeps a
  # cursor per voice and only touches the note currently due, so a long tune costs
  # exactly what a short one does.
  def test_playing_a_song_costs_per_voice_not_per_note
    ten = Cost.new.steady_cost(music_game(10))
    hundred = Cost.new.steady_cost(music_game(100))
    near WEIGHTS[:music_voice], ten           # one voice
    near ten, hundred                          # 10x the notes, identical cost
  end

  # A beep is a small fixed burst of writes to the sound registers.
  def test_a_beep_costs_its_sound_register_writes
    prog = program(screen(:bitmap), enable_sound, loop_(wait_vblank, beep(440)))
    near Cost::BEEP_WRITES * WEIGHTS[:sound_write], Cost.new.steady_cost(prog)
  end

  # Sound counts alongside drawing on the same frame, against the same budget.
  def test_music_counts_alongside_drawing
    prog = music_game(10, draw: clear_screen(:black)) # a whole-screen clear + the song
    near dma_blob(240 * 160) + song_frame_cost(10), Cost.new.steady_cost(prog)
  end

  # The song shows up in the drill-down tree with its cost and note count.
  def test_the_song_appears_in_the_cost_tree
    play = Cost.new.analyze(music_game(10)).find { |node| node[:op] == :play_song }
    refute_nil play, "play_song should appear as a costed leaf"
    near song_frame_cost(10), play[:cost]
    assert_match(/10 notes/, play[:label])
  end

  # rom.explain's JSON carries a per-song breakdown, judged against the music budget.
  def test_json_carries_the_song_breakdown
    song = Cost.new.as_json(music_game(10))[:songs].first
    assert_equal :theme, song[:name]
    assert_equal 10, song[:notes]
    assert_equal Cost::MUSIC_STEADY_BUDGET, song[:budget]
    refute song[:over], "a 10-note song is well under the music budget"
  end

  # A long tune is NOT heavy: the pointer-based sequencer costs the same per frame
  # as a short one (per voice, not per note), so neither trips the music budget.
  def test_a_long_song_is_not_heavier_than_a_short_one
    long = Cost.new.song_verdicts(music_game(400)).first
    short = Cost.new.song_verdicts(music_game(50)).first
    assert_equal short[:steady_cost], long[:steady_cost], "cost is per voice, so length doesn't change it"
    refute long[:over], "a long song is still well under the music budget"
  end
end
