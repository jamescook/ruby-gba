# frozen_string_literal: true

require "test_helper"

# A SONG WITH AN INTRODUCTION. Game music plays a fanfare once and then loops a later stretch
# for as long as the scene lasts, so a song can say where its loop starts — `loop_from:` on a
# Score, `loop_from_here` in a song block. At its end it goes back there, not to its first note.
#
# What makes that more than a jump is what each part is doing at the loop point: the first time
# round a part gets there from the notes before it, every time after from the end of the song.
# A note held across the loop point is sounded again there on every pass after the first, and a
# part that is silent there is silenced there, whatever the end of the song left it doing.
class TestSongLoopPoint < Minitest::Test
  Score = RubyGBA::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = RubyGBA::Music::NOTE_FREQUENCIES
  STEP_ONE = GBA::Mixer::STEP_ONE

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame. Every song here is 72 ticks
  # long and loops from tick 24 unless it says otherwise: frames 0-23 are the introduction.
  def score(*parts, loop_from: 24, length: 72)
    Score.new(tempo: 150, length: length, loop_from: loop_from, parts: parts)
  end

  def part(*notes) = Part.new(plays: :organ, notes: notes.map { |at, key| Note.new(at: at, key: key) })

  def game(song)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      # Five seconds of a steady tone, so a note is still sounding wherever a test looks.
      instrument :organ, pcm: [60, -60] * 20_000, rate: 8000, note: :C4
      music = songs :music, [song]
      game_loop { music.play 0 }
    end
    b.emit_pending_functions
    b.program
  end

  # Every note the interpreter played, in order, over +frames+.
  def heard(song, frames: 190)
    Reference.new.run(game(song), frames: frames).audio.select { |entry| entry[0] == :note }.map(&:last)
  end

  # What the console's music voice is doing +frames+ in: [step, how far into the recording], or
  # nil when it is silent.
  def console_voice(song, frames:)
    voice = assert_emulator_loads_rom(assemble_rom(game(song), name: "LOOPPT"), frames: frames).voices.first
    voice && [voice.step, voice.position]
  end

  def step(key) = (NOTES[key].to_f / NOTES[:C4] * STEP_ONE).round

  # --- the introduction plays once ---

  INTRO_THEN_LOOP = [[0, :C4], [24, :E4], [48, :G4]].freeze

  def test_the_introduction_plays_once_and_the_rest_repeats
    notes = heard(score(part(*INTRO_THEN_LOOP)))

    assert_equal NOTES.values_at(:C4, :E4, :G4, :E4, :G4, :E4, :G4, :E4), notes
  end

  def test_without_a_loop_point_the_whole_song_repeats
    notes = heard(score(part(*INTRO_THEN_LOOP), loop_from: nil))

    assert_equal NOTES.values_at(:C4, :E4, :G4, :C4, :E4, :G4, :C4, :E4), notes
  end

  # On the console: a little way into the second time round, a song that looped from its start
  # would be back in its introduction. This one is in its loop.
  def test_the_console_goes_back_to_the_loop_point
    at_first, = console_voice(score(part(*INTRO_THEN_LOOP)), frames: 12)
    second_time, = console_voice(score(part(*INTRO_THEN_LOOP)), frames: 84)

    assert_in_delta step(:C4), at_first, 2, "the introduction, the first time"
    assert_in_delta step(:E4), second_time, 2, "the loop, not the introduction again"
  end

  # --- a note held across the loop point ---

  # C4 starts in the introduction and is still sounding when the loop point comes; the song
  # ends on G4. So every time round, C4 has to be sounded again at the loop point.
  HELD = [[0, :C4], [48, :G4]].freeze

  def test_a_note_held_across_the_loop_point_sounds_there_every_time_after_the_first
    notes = heard(score(part(*HELD)))

    assert_equal NOTES.values_at(:C4, :G4, :C4, :G4, :C4, :G4, :C4), notes,
                 "C4 again at each loop — and not twice the first time"
  end

  def test_the_console_sounds_the_held_note_at_the_loop
    second_time, = console_voice(score(part(*HELD)), frames: 84)

    assert_in_delta step(:C4), second_time, 2, "the held note, not the note the song ended on"
  end

  # The first time round the held note is not struck again at the loop point: 40 frames in it is
  # 40 frames into its recording, where striking it again at frame 24 would put it 16 in.
  def test_the_console_does_not_strike_the_held_note_again_the_first_time
    _, position = console_voice(score(part(*HELD)), frames: 44)

    assert_operator position, :>, 8000 / 2, "a sound more than half a second in (#{position} samples)"
  end

  # A song that ends on the very note held across the loop point is still sounding it when it
  # comes round — so it carries on, rather than being struck again: after the first time, C4 is
  # heard where the song plays it (frame 60), and never at the loop point.
  def test_a_song_that_ends_on_the_held_note_carries_it_on
    notes = heard(score(part([0, :C4], [48, :G4], [60, :C4])))

    assert_equal NOTES.values_at(:C4, :G4, :C4, :G4, :C4, :G4, :C4), notes
  end

  # --- a part that is silent at the loop point ---

  # This part comes in after the loop point and is still sounding at the end. Coming round, it
  # has to go quiet until its note, as it was the first time.
  def test_a_part_silent_at_the_loop_point_is_silenced_there
    assert_nil console_voice(score(part([48, :G4])), frames: 84), "silent between the loop point and its note"
  end

  # A song that loops from its start is the same rule: a part that comes in late no longer rings
  # on into the start of the song each time round.
  def test_a_part_that_comes_in_late_is_silent_each_time_the_song_starts_again
    assert_nil console_voice(score(part([36, :G4]), loop_from: nil), frames: 84)
  end

  # --- in a song block ---

  def test_a_song_block_marks_its_loop_with_loop_from_here
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :title do
        tempo 150
        note :C4, :whole # the fanfare
        loop_from_here
        note :E4, :half
        note :G4, :half
      end
      play_song :title
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    notes = Reference.new.run(b.program, frames: 400).audio.select { |entry| entry[0] == :note }.map(&:last)

    assert_equal NOTES.values_at(:C4, :E4, :G4, :E4, :G4, :E4, :G4, :E4), notes
  end

  # --- what cannot be had, said plainly ---

  def test_a_score_that_loops_from_its_end_is_a_friendly_error
    err = assert_raises(ArgumentError) { score(part(*INTRO_THEN_LOOP), loop_from: 72).to_song }

    assert_match(/before the end/, err.message)
  end

  def test_a_loop_point_that_is_not_a_tick_is_a_friendly_error
    err = assert_raises(ArgumentError) { score(part(*INTRO_THEN_LOOP), loop_from: -1).to_song }

    assert_match(/whole number/, err.message)
  end

  def test_loop_from_here_at_the_end_of_a_song_is_a_friendly_error
    ctx = RubyGBA::Music::SongContext.new
    ctx.instance_eval do
      note :C4, :quarter
      loop_from_here
    end

    assert_match(/at the end of the song/, assert_raises(ArgumentError) { ctx.loop_frame }.message)
  end

  def test_parts_that_mark_different_loop_points_are_a_friendly_error
    ctx = RubyGBA::Music::SongContext.new
    ctx.instance_eval do
      voice(:melody) { note(:C4, :quarter); loop_from_here; note(:E4, :half) }
      voice(:bass) { note(:C3, :half); loop_from_here; note(:G3, :quarter) }
    end

    assert_match(/different places to loop from/, assert_raises(ArgumentError) { ctx.loop_frame }.message)
  end
end
