# frozen_string_literal: true

require "test_helper"
require "mixed_sound"

# THE TESTS OF vblank/ir/backends/reference/test_mixer.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
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
  SOUNDS = (0...(VBlank::Audio::Sound::MIXER_VOICES + 2)).map { |i| :"s#{i}" }

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
    score = VBlank::Audio::Score
    shape = VBlank::Audio::Envelope.new(attack: 255, decay: 255, sustain: 255, release: 235)
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

  def test_one_recording_is_mixed_into_the_same_bytes
    assert_mixes_agree(playing { sample(:saw, pcm: SAWTOOTH, rate: 8000).play })
  end

  def test_a_quieter_play_is_the_same_bytes
    %i[three_quarter half quarter].each do |level|
      assert_mixes_agree(playing { sample(:saw, pcm: SAWTOOTH, rate: 8000).play(volume: level) })
    end
  end

  # A note other than the one it was recorded at reads the recording faster or slower, by a
  # step that is not a whole number of samples, and the part left over is carried frame to
  # frame. So is a recording made at another rate than the mix runs at.
  def test_a_recording_read_at_another_pitch_or_rate_is_the_same_bytes
    assert_mixes_agree(playing { sample(:saw, pcm: SAWTOOTH, rate: 8000, note: :C4).play(pitch: :E4) })
    assert_mixes_agree(playing { sample(:saw, pcm: SAWTOOTH, rate: 8000, note: :C4).play(pitch: :A3) })
    assert_mixes_agree(playing do
      sample(:other, pcm: SAWTOOTH, rate: 11_025).play
      sample(:common, pcm: [3] * 10, rate: 8000)
      sample(:common_too, pcm: [4] * 10, rate: 8000)
    end)
  end

  # A recording shorter than a frame's worth ends partway through a slice, and the rest of
  # that slice is silent; the frame after is silence through and through.
  def test_a_recording_that_ends_partway_through_a_frame_is_the_same_bytes
    short = Array.new(300) { |i| (i % 50) - 25 }
    assert_mixes_agree(playing { sample(:blip, pcm: short, rate: 8000).play }, frames: 6)
  end

  def test_a_recording_that_loops_or_holds_is_the_same_bytes
    loop_me = Array.new(150) { |i| (i % 30) - 15 }
    assert_mixes_agree(playing { sample(:round, pcm: loop_me, rate: 8000).play(loop: true) })
    assert_mixes_agree(playing { sample(:held, pcm: SAWTOOTH.first(500), rate: 8000, holds_from: 320).play(loop: true) })
  end

  # A hold of two samples read two octaves up steps about four at a time, so one read back is not
  # enough to be inside the recording again: it reads back as many times as it takes, and
  # never reads what is stored after the recording.
  def test_a_hold_shorter_than_a_step_is_the_same_bytes
    assert_mixes_agree(playing do
      sample(:held, pcm: SAWTOOTH.first(100), rate: 8000, note: :C4, holds_from: 98).play(pitch: :C6, loop: true)
    end)
  end

  # The same for a recording that loops whole and is shorter than one step.
  def test_a_loop_shorter_than_a_step_is_the_same_bytes
    assert_mixes_agree(playing do
      sample(:tiny, pcm: SAWTOOTH.first(3), rate: 8000, note: :C4).play(pitch: :C6, loop: true)
    end)
  end

  # A recording declared with a shape climbs and settles when the game plays it, its loudness
  # sliding across every sample of a frame.
  def test_a_recording_with_a_shape_is_the_same_bytes
    shape = { attack: 0.1, decay: 0.2, sustain: 0.4 }
    assert_mixes_agree(playing { sample(:swell, pcm: SAWTOOTH, rate: 8000, envelope: shape).play(loop: true) })
  end

  # ...and one the game starts and stops in its loop lands on the same frames, a frame's slice
  # made after the pass that said it — mixed once at nothing before its shape first moves it.
  def test_a_shaped_recording_started_and_stopped_in_the_loop_is_the_same_bytes
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clip = sample :clip, pcm: SAWTOOTH.reverse, rate: 8000, envelope: { attack: 0.1 }
      passes = var :passes, 0
      game_loop do
        passes.add! 1
        (passes == 3).then { clip.play }
        (passes == 12).then { clip.stop }
      end
    end
    b.finalize_program
    assert_mixes_agree(b.program, frames: 20, at_least: 6)
  end

  # A recording declared twice under one name plays the second declaration's samples.
  def test_a_name_declared_twice_plays_the_last_recording
    assert_mixes_agree(playing do
      sample(:saw, pcm: SAWTOOTH, rate: 8000)
      sample(:saw, pcm: SAWTOOTH.reverse, rate: 8000).play
    end)
  end

  # Several voices summed, each total held to a byte only once every voice is in.
  def test_several_recordings_summed_and_clamped_are_the_same_bytes
    loud = Array.new(3000) { |i| ((i * 7) % 256) - 128 }
    assert_mixes_agree(playing do
      sample(:saw, pcm: SAWTOOTH, rate: 8000).play
      sample(:loud, pcm: loud, rate: 8000).play(pitch: :D4)
      sample(:also, pcm: loud.reverse, rate: 8000).play(volume: :half, loop: true)
    end)
  end

  # A Score's note can name its own recording and its own shape, over its part's: here the second
  # note is another recording, and the third the part's own recording with a shape of its own.
  def test_a_notes_own_recording_and_shape_are_the_same_bytes
    score = VBlank::Audio::Score
    notes = [score::Note.new(at: 0, key: :C4, length: 8),
             score::Note.new(at: 10, key: :E4, instrument: :reed, length: 8),
             score::Note.new(at: 20, key: :G4, envelope: { attack: 0.1, release: 0.1 }, length: 10)]
    tune = score.new(tempo: 150, length: 40, parts: [score::Part.new(plays: :keys, notes: notes)])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :keys, pcm: SAWTOOTH.first(2400), rate: 8000, note: :C4
      instrument :reed, pcm: SAWTOOTH.reverse.first(2400), rate: 8000, note: :C4
      music = songs :music, [tune]
      game_loop { music.play 0 }
    end
    b.finalize_program
    assert_mixes_agree(b.program, frames: 40)
  end

  def test_a_quiet_note_is_silent_once_its_whole_loudness_is_nothing
    levels = []
    i = game_player
    i.each_vblank { levels << i.level_of(:tone) }
    i.run(quiet_note_let_go, frames: 120)
    slices = i.mixed_sound

    # A frame's slice slides from the loudness one level reading back to the one the reading
    # before that, so it is wholly at nothing two readings after the level reaches 10.
    silent_from = levels.each_index.find { |f| f > 1 && levels[f - 2] && levels[f - 2] <= SILENT_FROM_LEVEL }
    refute_nil silent_from, "the note never fell to level #{SILENT_FROM_LEVEL} in the run: #{levels.compact.last(5)}"
    sounding = (silent_from...levels.size).select { |f| levels[f] }
    refute_empty sounding, "the voice was let go as its loudness reached nothing, so there is no frame to check"
    sounding.each do |f|
      assert(slices[f].all?(&:zero?), "frame #{f}, level #{levels[f]}: #{slices[f].uniq.first(4)}")
    end
  end

  # ...and the console makes the same bytes.
  def test_a_quiet_note_fading_is_the_same_bytes
    assert_mixes_agree(quiet_note_let_go, frames: 100)
  end

  # WHAT A GAME DOES INSIDE ITS LOOP is mixed in the slice made just after its pass, so against a
  # tune that is already sounding, a sound the game starts or stops lands on the cartridge's
  # frame — and a sound with a shape is mixed once at nothing before its shape first moves it.
  def test_a_sound_the_game_starts_and_stops_in_its_loop_lands_on_the_same_frame
    [{}, { envelope: { attack: 0.1, release: 0.2 } }].each do |shape|
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        enable_sound
        instrument :keys, pcm: SAWTOOTH.first(1200), rate: 8000, note: :C4
        clip = sample :clip, pcm: SAWTOOTH.reverse, rate: 8000, **shape
        song :tune do
          tempo 300
          voice(:melody, plays: :keys) { note :C4, :whole }
        end
        passes = var :passes, 0
        game_loop do
          passes.add! 1
          play_song :tune
          (passes == 6).then { clip.play }
          (passes == 14).then { clip.stop }
        end
      end
      b.finalize_program
      assert_mixes_agree(b.program, frames: 30)
    end
  end

  # --- level control ---


  # A recording declared and never played is nothing to mix, so there is no mix at all, as on
  # the cartridge, which brings its mixer up only for a game that plays one.
  def test_a_game_that_only_declares_a_recording_mixes_nothing
    declared = playing { sample(:saw, pcm: SAWTOOTH, rate: 8000) }

    assert_empty game_player.run(declared, frames: 5).mixed_sound
  end
end
