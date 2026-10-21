# frozen_string_literal: true

require "test_helper"
require "mixed_sound"

# THE TESTS OF ruby_gba/ir/backends/reference/test_mixer.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# The mixer: several samples sound at once instead of cutting each other off — background
# music plus overlapping sound effects, and (later) chords. `sample.play` adds a voice to
# the mix; `sample.stop` drops that sample's voices. This is the interpreter oracle for the
# mixer — it pins the behavior both backends must share (the GBA software-mix lowering
# matches it), down to every byte of sound it makes. The surface stays plain: play and
# stop, no voices or channels exposed.
class TestMixerOnTheAdvance < Minitest::Test
  include MixedSound

  # mem8 hands back an unsigned byte; the mix buffer holds signed 8-bit samples.
  private def signed8(byte)
    byte >= 128 ? byte - 256 : byte
  end

  # A DSL block that sets up sounds, then loops for `frames` frames — as a program, so the
  # interpreter and the console can be handed the very same one rather than two that look
  # alike.
  private def frames_program(frames, &setup)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      instance_exec(&setup)
      counter = var(:__f, 0)
      game_loop do
        wait_vblank
        counter.add! 1
        (counter >= frames).then { halt }
      end
    end
    b.program
  end

  # ...and run it on the interpreter, which is what nearly every test here wants.
  private def run_frames(frames, &setup)
    game_player.run(frames_program(frames, &setup), max_steps: 200_000)
  end

  # TWO MORE DIFFERENT SOUNDS THAN THE MIXER HAS VOICES, AND BOTH BACKENDS MUST KEEP THE SAME
  # ONES. The mixer drops a play it has no room for rather than cutting off one already
  # sounding, so the first ones played are the ones that sound and the last two are lost.
  #
  # A count alone would not show that: two backends can each hold a full mixer and disagree
  # about which. So ask each one what it is playing, by name. The console answers from its
  # own voice table — reading what the lowering really did, not what the interpreter says
  # it should have — and the two lists have to match.
  SOUNDS = (0...(RubyGBA::Audio::Sound::MIXER_VOICES + 2)).map { |i| :"s#{i}" }

  # --- the sound itself, byte for byte (see MixedSound) ---

  # A game that plays its recordings on its first pass and then does nothing.
  private def playing(&plays)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      instance_exec(&plays)
      game_loop {}
    end
    b.finalize_program
    b.program
  end

  # A recording whose every byte differs from the one beside it, so a slice that starts a
  # sample early or late, or reads one twice, is a different slice.
  SAWTOOTH = Array.new(4000) { |i| (i % 200) - 100 }.freeze

  # A recorded instrument played by a song: notes of their own pitch and loudness, rests that
  # give the voice back, and a note that takes over its part's own voice from the top.
  private def tune_on(instrument_words: {}, part_words: {}, volume_from: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :keys, pcm: SAWTOOTH.first(1200), rate: 8000, note: :C4, **instrument_words
      song :tune do
        tempo 300
        voice :melody, plays: :keys, **part_words do
          volume 13
          note :C4, :quarter
          note :E4, :quarter
          rest :quarter
          note :G4, :eighth
          note :C5, :eighth
          volume 9
          note :A4, :half
        end
        voice :under, plays: :keys do
          volume 6
          note :C3, :whole
        end
      end
      passes = var :passes, 0
      game_loop do
        passes.add! 1
        play_song :tune
        (passes == volume_from).then { music_volume 40 } if volume_from
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_songs_recorded_parts_are_the_same_bytes
    assert_mixes_agree(tune_on, frames: 60)
  end

  # A note with a shape climbs, holds and falls away, its loudness sliding across every sample
  # of a frame rather than stepping at the frame's edge.
  def test_notes_with_a_shape_are_the_same_bytes
    shaped = { envelope: { attack: 0.05, decay: 0.2, sustain: 0.5, release: 0.15 } }
    assert_mixes_agree(tune_on(instrument_words: shaped), frames: 60)
    assert_mixes_agree(tune_on(part_words: { envelope: { release: 0.3 } }), frames: 60)
  end

  # The music volume moving reaches notes already sounding — with and without a shape in the
  # game, which changes what the mix reads for a note with none.
  def test_the_music_volume_moving_is_the_same_bytes
    assert_mixes_agree(tune_on(volume_from: 8), frames: 60)
    assert_mixes_agree(tune_on(part_words: { envelope: { release: 0.2 } }, volume_from: 8), frames: 60)
  end

  # A QUIET NOTE FALLING AWAY GOES SILENT WHILE ITS LEVEL IS STILL ABOVE NOTHING. A voice's
  # loudness for a frame is a whole number of 256ths, the loudness asked for (out of 512) times
  # the level, over 512, the rest dropped — as a cartridge's own sound engine works it out from
  # its right and left volumes, (level x (right + left)) >> 9. So a note asked at 51 (25 and a
  # half 256ths) is at 1 while its level is 11 and at nothing from 10 down, and from the frame
  # it gets there it adds nothing to the mix, though its voice is still held until the level
  # runs out. Rounded to 26 256ths it would still be at 1 on level 10.
  QUIET = 51
  SILENT_FROM_LEVEL = 10

  private def quiet_note_let_go
    score = RubyGBA::Audio::Score
    shape = RubyGBA::Audio::Envelope.new(attack: 255, decay: 255, sustain: 255, release: 235)
    note = score::Note.new(at: 0, key: :C4, length: 4, volume: Rational(QUIET * 15, 512), envelope: shape)
    tune = score.new(tempo: 150, length: 400, plays_once: true, parts: [score::Part.new(plays: :tone, notes: [note])])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: [127, 127, -127, -127] * 64, rate: 8000, note: :C4, holds_from: 0
      music = songs :music, [tune]
      game_loop { music.play 0 }
    end
    b.finalize_program
    b.program
  end

  # A note at volume 0 sounds nothing, so it takes no voice: the part is silent there, and the
  # part's voice from before it is let go as a rest lets it go.
  def test_a_note_at_volume_nought_is_the_same_bytes
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :keys, pcm: SAWTOOTH.first(1200), rate: 8000, note: :C4
      song :tune do
        tempo 300
        voice :melody, plays: :keys do
          volume 12
          note :C4, :quarter
          volume 0
          note :E4, :quarter
          volume 12
          note :G4, :quarter
        end
      end
      game_loop { play_song :tune }
    end
    b.finalize_program
    assert_mixes_agree(b.program, frames: 40)
  end

  # --- level control ---

end
