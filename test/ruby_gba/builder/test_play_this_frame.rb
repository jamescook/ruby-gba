# frozen_string_literal: true

require "test_helper"
require "mixed_sound"

# A SONG ASKED FOR `this_frame: true` IS ON ITS FIRST FRAME THE FRAME IT IS ASKED FOR.
#
# A song the game names is taken up by the player in the screen's interrupt, which comes before
# the pass that named it, so the song starts on the next frame. A game rebuilt to match another
# cartridge, whose own sound engine runs after the game's logic in the same frame, asks for its
# songs on that cartridge's frames and was heard a frame late. Asked `this_frame: true`, the
# game takes the song up itself as it asks, and the screen's next interrupt plays its second
# frame.
class TestPlayThisFrame < Minitest::Test
  runs_on :reference, :native
  include MixedSound

  Score = RubyGBA::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = RubyGBA::Audio::Music::NOTE_FREQUENCIES

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame. Nothing sounds for the first
  # ten frames, so the first note heard says when the song started.
  SONG = Score.new(tempo: 150, parts: [Part.new(notes: [Note.new(at: 10, key: :C5), Note.new(at: 20, key: :E5)])])
  ASKED_ON = 3

  # A game that asks for SONG on pass ASKED_ON, saying +options+ as it does.
  def game(**options)
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

  # The first frame each note was read on, from the interpreter: every vblank reads what was
  # played since the one before.
  def notes_by_frame(program, frames)
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

  # The same, with a song block named by `play_song`: ten frames of rest, then a note.
  def named_game(**options)
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

  def test_a_song_named_this_frame_plays_a_frame_sooner
    assert_equal 13, notes_by_frame(named_game(this_frame: true), 30).key([NOTES[:C5]])
  end

  def test_this_frame_that_is_not_true_or_false_is_a_friendly_error
    error = assert_raises(ArgumentError) { game(this_frame: :yes) }

    assert_match(/this_frame.*must be true or false/, error.message)
  end

  # --- a sound effect ---

  # A game with the effects given, asking for effect +asks+ on pass ASKED_ON with +options+ —
  # and, given +before+, for that one on pass 1.
  def effect_game(effects, asks: 0, before: nil, **options)
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
  def later_effect(*keys, group: nil, priority: 0)
    Score.new(tempo: 150, group: group, priority: priority,
              parts: [Part.new(notes: keys.each_with_index.map { |key, n| Note.new(at: 10 * (n + 1), key: key) })])
  end

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

  # --- the console ---

  # Each frame of the cartridge, after it is played: how many passes the game had made, the
  # song its player was on, and whether anything was heard.
  def console_frames(program)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "THISFRAME")
    v = assert_emulator_loads_rom(rom, frames: 1, vars: backend.var_addresses)
    Array.new(30) do
      v.step
      { pass: v.var(:pass), song: v.var(:__music_playing), loud: v.audio_energy_by_frame.last.positive? }
    end
  end

  # The player's own record names the song on the frame of the pass that asked, and the note
  # ten frames into the song is heard ten frames after that — where asked the plain way, each is
  # a frame later.
  def test_the_console_is_on_the_song_the_frame_it_is_asked_for
    %i[game named_game].product([[{ this_frame: true }, 0], [{}, 1]]).each do |maker, (options, late)|
      frames = console_frames(send(maker, **options))
      taken_up = frames.index { |frame| frame[:song].positive? }
      heard = frames.index { |frame| frame[:loud] }

      assert_equal ASKED_ON + late, frames[taken_up][:pass], "#{maker} asked #{options}: the pass the song was taken up in"
      assert_equal 10 + late, heard - frames.index { |frame| frame[:pass] == ASKED_ON },
                   "#{maker} asked #{options}: frames from the pass that asked to the first note"
    end
  end

  # A SONG THAT PLAYS ONCE, asked for this_frame: heard from the pass that asks, and quiet from
  # the frame after its end — while the game goes on naming it every frame, which is when the
  # player has to keep it silent.
  def test_the_console_silences_a_song_that_ends_asked_for_this_frame
    # The note is held to the song's end, so only the player silencing the ended song stops it.
    once = Score.new(tempo: 150, plays_once: true, length: 12, parts: [Part.new(notes: [Note.new(at: 0, key: :C5)])])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      music = songs :music, [once]
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass >= ASKED_ON).then { music.play 0, this_frame: true }
      end
    end
    b.finalize_program
    frames = console_frames(b.program)
    asked = frames.index { |frame| frame[:pass] == ASKED_ON }

    assert frames[asked + 2][:loud], "heard as it starts"
    refute frames[(asked + 20)..].any? { |frame| frame[:loud] }, "and quiet once it has ended"
  end

  # A sound effect's note ten frames in is heard ten frames after the pass that asked for it.
  def test_the_console_hears_an_effect_asked_for_this_frame_a_frame_sooner
    [[{ this_frame: true }, 0], [{}, 1]].each do |options, late|
      frames = console_frames(effect_game([later_effect(:C5, :E5)], **options))
      heard = frames.index { |frame| frame[:loud] }

      assert_equal 10 + late, heard - frames.index { |frame| frame[:pass] == ASKED_ON },
                   "asked #{options}: frames from the pass that asked to the first note"
    end
  end

  # TWO EFFECTS OF A GROUP ON RECORDINGS: the one sounding since pass 1 is cut off where the other
  # is asked, and the other's first note starts, both in the same slice of sound on both backends.
  def test_the_console_cuts_off_and_starts_recorded_effects_of_a_group_as_the_interpreter_does
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 16_000, rate: 8000, note: :C4
      sfx = sound_effects :sfx, [
        Score.new(tempo: 150, group: :voice, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :G4)])]),
        Score.new(tempo: 150, group: :voice, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :D5), Note.new(at: 5, key: :C5)])]),
      ]
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 1).then { sfx.play 0 }
        (pass == ASKED_ON).then { sfx.play 1, this_frame: true }
      end
    end
    b.finalize_program

    assert_mixes_agree(b.program, frames: 20)
  end

  # AN EFFECT ITS GROUP DOES NOT PLAY, asked for `this_frame: true`, changes nothing where it is
  # asked: another group's effect, cut off by a plain ask earlier in the same pass, is still let go
  # of on the next frame, on both backends.
  def test_an_effect_not_played_asked_for_this_frame_cuts_nothing_off_early
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 16_000, rate: 8000, note: :C4
      held = ->(group, priority, key) { Score.new(tempo: 150, group: group, priority: priority, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: key)])]) }
      sfx = sound_effects :sfx, [held.call(:a, 5, :G4), held.call(:a, 0, :A4), held.call(:b, 0, :C5), held.call(:b, 0, :D5)]
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 1).then do
          sfx.play 0
          sfx.play 2
        end
        (pass == ASKED_ON).then do
          sfx.play 3
          sfx.play 1, this_frame: true
        end
      end
    end
    b.finalize_program

    assert_mixes_agree(b.program, frames: 20)
  end

  # --- a song on a recording ---

  # A song on a recording, asked for from a routine kept in the cartridge, and a recording of the
  # game's own, each started on pass ASKED_ON when given.
  def recorded_game(song: false, click: false)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 16_000, rate: 8000, note: :C4
      sound = sample :click, pcm: [40, 0, -40, 0] * 2000, rate: 8000
      music = songs :music, [Score.new(tempo: 150, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :E4)])])]
      func(:ask, fast: false) { music.play 0, this_frame: true }
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == ASKED_ON).then do
          sound.play if click
          call :ask if song
        end
      end
    end
    b.finalize_program
    b.program
  end

  def first_slice_heard(program)
    game_player.run(program, frames: 20).mixed_sound.index { |slice| slice.any?(&:nonzero?) }
  end

  # The song's first note is in the slice of sound a recording the game starts in the same pass
  # is first in: the next one made. Taken up a frame late, it would be a slice behind.
  def test_a_recorded_song_is_first_heard_in_the_slice_a_sound_the_game_starts_beside_it_is
    assert_equal first_slice_heard(recorded_game(click: true)), first_slice_heard(recorded_game(song: true))
  end

  # ...and the console makes the same bytes as the interpreter, slice for slice, with both in it.
  def test_the_console_mixes_a_recorded_song_asked_for_this_frame_as_the_interpreter_does
    assert_mixes_agree(recorded_game(song: true, click: true), frames: 20)
  end
end
