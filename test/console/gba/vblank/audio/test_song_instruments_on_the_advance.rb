# frozen_string_literal: true

require "test_helper"

require "stringio"

# The games these tests share the mixer's voices in, kept once for the Advance's cartridge too
# (test/lowering/gba/vblank/audio/test_song_instruments_cartridge.rb).
module SongInstrumentsSharing
  include SharedConstants

  VOICES = VBlank::Audio::Sound::MIXER_VOICES
  CLIPS = VOICES + 2 # two more of the game's own sounds than there are voices
  private def clip_names(range) = range.map { |n| :"s#{n}" }

  # A game that starts CLIPS sounds of its own at once, two seconds long each, on pass +at+ — in
  # its game loop, where the burst lands inside one frame on both backends — beside +tune+. The
  # first sound loops when +loop_first+ says so.
  private def sharing_game(at:, loop_first: false, &tune)
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
        pass.add! 1
        (pass == at).then { clips.each_with_index { |clip, n| clip.play(loop: loop_first && n.zero?) } }
      end
    end
    b.finalize_program
    b.program
  end

  # The part's one long note already sounding when the game's burst comes on pass 5.
  private def note_held_through_the_burst = sharing_game(at: 5) { note :C4, :whole }

  # A part's two notes, and no burst at all.
  private def next_note_on_its_own_voice = sharing_game(at: 999) { note :C4, :quarter; note :G4, :whole }

  # A part resting when the burst comes on pass 40.
  private def resting_part = sharing_game(at: 40) { note :C4, :quarter; rest :whole }

  # The part's note coming after the burst on pass 5 has taken every voice.
  private def note_after_the_burst(loop_first: false)
    sharing_game(at: 5, loop_first: loop_first) { rest :quarter; note :C4, :whole }
  end
end

# THE TESTS OF vblank/audio/test_song_instruments.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# A song part can play a recorded instrument instead of the square-wave voice:
# `voice :melody, plays: :piano do ... end`. Each note plays the instrument's recording at that
# note's pitch, through the mixer, and a rest silences it. The part names the instrument, never a
# channel — which voice it uses is the framework's business.
class TestSongInstrumentsOnTheAdvance < Minitest::Test
  include SongInstrumentsSharing

  # A piano recorded at C4, a second long — longer than any note here, so it is the next event
  # that ends a note rather than the recording running out.
  private def piano_game(&extra)
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
    b.finalize_program
    b.program
  end

  # What the interpreter has sounding after each of the first +frames+ frames.
  private def sounding_by_frame(program, frames)
    seen = {}
    i = game_player
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
  #
  # Each of these is asked of the run's own player; the Advance's cartridge is held to the same
  # answers in test/lowering/gba/vblank/audio/test_song_instruments_cartridge.rb.

  # A note already sounding keeps its voice, and the game's burst gets every voice left.
  def test_a_sounding_note_keeps_its_voice_and_the_game_gets_the_rest
    assert_equal [:piano] + clip_names(0...(VOICES - 1)),
                 game_player.run(note_held_through_the_burst, frames: 10).active_samples
  end

  # A part's next note takes over the voice its last note is still sounding in, rather than
  # taking a second one and leaving the first to ring on underneath it.
  def test_a_parts_next_note_takes_over_its_own_voice
    assert_equal [:piano], game_player.run(next_note_on_its_own_voice, frames: 40).active_samples
  end

  # A part that rests gives its voice up: while it rests, every voice is the game's.
  def test_a_resting_part_lends_its_voice_to_the_game
    assert_equal clip_names(0...VOICES), game_player.run(resting_part, frames: 50).active_samples,
                 "all of them the game's, the part resting"
  end

  # THE MOMENT THE VOICES RUN OUT: every voice is the game's when the part's note comes, so the
  # note takes the voice of the game's sound that has played longest.
  def test_a_note_with_no_voice_free_takes_the_one_the_game_started_first
    assert_equal [:piano] + clip_names(1...VOICES), game_player.run(note_after_the_burst, frames: 40).active_samples,
                 "s0, the oldest, gave way"
  end

  # ...one that plays once before one that loops, since a loop never ends of its own accord.
  def test_a_sound_that_loops_gives_way_last
    assert_equal [:s0, :piano] + clip_names(2...VOICES),
                 game_player.run(note_after_the_burst(loop_first: true), frames: 40).active_samples,
                 "s0 loops, so s1 gave way"
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
        pass.add! 1
        (pass < 10).then { play_song :tune }.else { play_song :beeps }
      end
    end
    b.finalize_program
    seen = sounding_by_frame(b.program, 20)

    assert_equal [:piano], seen[5]
    assert_empty seen[15], "the square-wave tune took over, and the piano stopped with its tune"
  end

  # --- the surface ---

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
    b.finalize_program

    assert_equal [:piano], game_player.run(b.program, frames: 3).active_samples
  end
end
