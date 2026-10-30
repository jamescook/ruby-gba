# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_play_this_frame"

# A SONG OR AN EFFECT ASKED FOR `this_frame: true` ON THE ADVANCE'S CARTRIDGE, heard in the
# emulator: on its first frame the frame it is asked for, where asked the plain way it is a frame
# later. The notes every run plays are in test/all/vblank/builder/test_play_this_frame.rb.
class TestPlayThisFrameCartridge < Minitest::Test
  include PlayThisFrameGames

  # Each frame of the cartridge, after it is played: how many passes the game had made, the
  # song its player was on, and whether anything was heard.
  private def console_frames(program)
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

  # A SONG WHOSE FIRST NOTE IS ON ITS FIRST FRAME, on each of the console's own voices: asked
  # this_frame, that note is heard on the frame of the pass that asks, and it goes on sounding;
  # asked the plain way, a frame later.
  def test_the_console_sounds_a_first_note_on_its_own_voices_the_frame_it_is_asked_for
    [nil, :wave, :noise].product([[{ this_frame: true }, 0], [{}, 1]]).each do |plays, (options, late)|
      at_once = Score.new(tempo: 150, parts: [Part.new(plays: plays, notes: [Note.new(at: 0, key: :C5, length: 20)])])
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        enable_sound
        music = songs :music, [at_once]
        pass = var :pass, 0
        game_loop do
          pass.add! 1
          (pass == ASKED_ON).then { music.play 0, **options }
        end
      end
      b.finalize_program
      frames = console_frames(b.program)
      asked = frames.index { |frame| frame[:pass] == ASKED_ON }

      assert_equal late, frames.index { |frame| frame[:loud] } - asked,
                   "#{plays || :square} asked #{options}: frames from the pass that asked to the first note heard"
      assert frames[(asked + late)..(asked + late + 4)].all? { |frame| frame[:loud] },
             "#{plays || :square} asked #{options}: the note goes on sounding"
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
end
