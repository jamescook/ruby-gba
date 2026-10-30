# frozen_string_literal: true

require "test_helper"

# The games these tests play, shared with the Advance cartridge's own tests of the same songs and
# effects (test/lowering/gba/vblank/builder/test_play_this_frame_cartridge.rb).
module PlayThisFrameGames
  include SharedConstants

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = VBlank::Audio::Music::NOTE_FREQUENCIES

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame. Nothing sounds for the first
  # ten frames, so the first note heard says when the song started. Made shareable here, since
  # only a test class's own constants are frozen for its Ractor.
  SONG = Ractor.make_shareable(Score.new(tempo: 150, parts: [Part.new(notes: [Note.new(at: 10, key: :C5),
                                                                              Note.new(at: 20, key: :E5)])]))
  ASKED_ON = 3

  # A game that asks for SONG on pass ASKED_ON, saying +options+ as it does.
  private def game(**options)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      music = songs :music, [SONG]
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == ASKED_ON).then { music.play 0, **options }
      end
    end
    b.finalize_program
    b.program
  end

  # The same, with a song block named by `play_song`: ten frames of rest, then a note.
  private def named_game(**options)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :later do
        tempo 360 # a quarter is ten frames
        rest :quarter
        note :C5, :quarter
      end
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == ASKED_ON).then { play_song :later, **options }
      end
    end
    b.finalize_program
    b.program
  end

  # A game with the effects given, asking for effect +asks+ on pass ASKED_ON with +options+ —
  # and, given +before+, for that one on pass 1.
  private def effect_game(effects, asks: 0, before: nil, **options)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      sfx = sound_effects :sfx, effects
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 1).then { sfx.play before } if before
        (pass == ASKED_ON).then { sfx.play asks, **options }
      end
    end
    b.finalize_program
    b.program
  end

  # Notes ten frames apart, from frame 10 of the effect.
  private def later_effect(*keys, group: nil, priority: 0)
    Score.new(tempo: 150, group: group, priority: priority,
              parts: [Part.new(notes: keys.each_with_index.map { |key, n| Note.new(at: 10 * (n + 1), key: key) })])
  end
end

# A SONG ASKED FOR `this_frame: true` IS ON ITS FIRST FRAME THE FRAME IT IS ASKED FOR.
#
# A song the game names is taken up by the player in the screen's interrupt, which comes before
# the pass that named it, so the song starts on the next frame. A game rebuilt to match another
# cartridge, whose own sound engine runs after the game's logic in the same frame, asks for its
# songs on that cartridge's frames and was heard a frame late. Asked `this_frame: true`, the
# game takes the song up itself as it asks, and the screen's next interrupt plays its second
# frame.
#
# What the Advance's cartridge plays, heard in the emulator, is in
# test/lowering/gba/vblank/builder/test_play_this_frame_cartridge.rb.
class TestPlayThisFrame < Minitest::Test
  include PlayThisFrameGames

  # The first frame each note was read on, from the interpreter: every vblank reads what was
  # played since the one before.
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

  # The rest before the first note is the song's first frame, read on the vblank after the pass
  # that asked: the next frame's interrupt took the song up.
  def test_a_song_asked_for_plays_from_the_frame_after
    assert_equal({ 4 => [0], 14 => [NOTES[:C5]], 24 => [NOTES[:E5]] }, notes_by_frame(game, 30))
  end

  # The rest is read on the same vblank, because the pass that asked played it, and every note
  # after it is a frame sooner.
  def test_a_song_asked_for_this_frame_plays_a_frame_sooner
    assert_equal({ 4 => [0], 13 => [NOTES[:C5]], 23 => [NOTES[:E5]] }, notes_by_frame(game(this_frame: true), 30))
  end

  def test_a_song_named_this_frame_plays_a_frame_sooner
    assert_equal 13, notes_by_frame(named_game(this_frame: true), 30).key([NOTES[:C5]])
  end

  def test_this_frame_that_is_not_true_or_false_is_a_friendly_error
    error = assert_raises(ArgumentError) { game(this_frame: :yes) }

    assert_match(/this_frame.*must be true or false/, error.message)
  end

  # --- a sound effect ---

  # Every note a frame sooner, and the voice let go a frame sooner at its end.
  def test_an_effect_asked_for_this_frame_plays_a_frame_sooner
    plain = notes_by_frame(effect_game([later_effect(:C5, :E5)]), 60)
    sooner = notes_by_frame(effect_game([later_effect(:C5, :E5)], this_frame: true), 60)

    assert_equal({ 14 => [NOTES[:C5]], 24 => [NOTES[:E5]] }, plain.reject { |_, notes| notes == [0] })
    assert_equal plain.transform_keys { |frame| frame - 1 }, sooner
  end

  # ONE OF A GROUP, cutting off the other of its group that has sounded since pass 1 — which
  # outranks it, being declared first at the same priority, so it would keep the voice while it
  # held it. It is stopped where the new one is asked, so the voice is free for the new one's
  # first frame, and what follows is a frame sooner. The stop is read on the vblank after the pass
  # either way.
  def test_an_effect_asked_for_this_frame_cuts_off_another_of_its_group_there
    effects = [Score.new(tempo: 150, group: :voice, parts: [Part.new(notes: [Note.new(at: 0, key: :G4), Note.new(at: 40, key: :A4)])]),
               Score.new(tempo: 150, group: :voice, parts: [Part.new(notes: [Note.new(at: 0, key: :D5), Note.new(at: 10, key: :C5),
                                                                                Note.new(at: 20, key: :E5)])])]
    plain = notes_by_frame(effect_game(effects, asks: 1, before: 0), 60)
    sooner = notes_by_frame(effect_game(effects, asks: 1, before: 0, this_frame: true), 60)

    assert_equal({ 2 => [NOTES[:G4]], 4 => [0, NOTES[:D5]], 14 => [NOTES[:C5]], 24 => [NOTES[:E5]] },
                 plain.reject { |frame, _| frame > 30 })
    assert_equal plain.to_h { |frame, notes| [frame > 4 ? frame - 1 : frame, notes] }, sooner
  end
end
