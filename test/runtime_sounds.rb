# frozen_string_literal: true

require VBlank.root.join("examples/pong").to_s
require VBlank.root.join("examples/jukebox").to_s

# THE SOUND A RUNTIME WRITTEN AGAIN MAKES, sample for sample: what would come out of the speaker,
# played by a lowering's runtime and by the native one's, which is already held to the cartridge in
# the emulator (test_native_tones.rb). The sound log and the mix are compared with the interpreter's
# on every frame by each checked run; what the voices make of them is held here. A lowering whose
# runtime is the native one's written again includes this and says which it is:
#
#   class TestJSSound < Minitest::Test
#     include RuntimeSounds
#     private def runtime_under_test = :js
#   end
#
# Each is recorded with Diagnostics::SoundRecording, and the two recordings say where they first
# differ.
module RuntimeSounds
  Native = VBlank::IR::Backends::Native

  # A waveform of the game's own: high for a quarter of its length, which no named shape is.
  THIN_PULSE = ([15] * 8 + [0] * 24).freeze

  def test_a_beep_sounds_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 4).then { beep 440, duty: :quarter, decay: :medium, volume: 15 }
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 70
  end

  # A song in two parts on the two square voices, coming round, with the music turned down and
  # faded out and back while a note is held, and a beep borrowing the second voice partway.
  def test_a_song_and_its_volume_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { duty :half; note :A4, :quarter; note :C5, :quarter; rest :quarter; note :E5, :quarter }
        voice(:bass) { duty :eighth; volume 8; note :A3, :half; note :E3, :half }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count.add! 1
        (count == 20).then { beep 990, duty: :eighth, decay: :slow }
        (count == 30).then { music_volume 50 }
        (count == 60).then { fade_music_out frames: 20 }
        (count == 100).then { fade_music_in frames: 20 }
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 160
  end

  # Notes that fade and swell by themselves on the square and noise voices, one note saying its
  # own, with the music turned down while they sound: they are left to fade, and only the next
  # note of each part takes the new volume.
  def test_notes_that_fade_and_swell_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { decay :slow; note :A4, :half; note :C5, :half, decay: :fast }
        voice(:pad) { volume 0; swell :medium; note :E3, :whole }
        voice(:drums, plays: :noise) { note :C3, :quarter; note :C3, :quarter, swell: 2; rest :half }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count.add! 1
        (count == 30).then { music_volume 50 }
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 130
  end

  # The wave voice told what to play at each loudness, then stopped; hits on the noise voice at
  # each of its pitches, plain and metallic. Each voice is heard on its own as well, the way a test
  # of one voice hears it.
  def test_the_wave_and_noise_voices_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 4).then { wave :triangle, :A4 }
        (count == 20).then { wave :triangle, :A4, volume: :half }
        (count == 36).then { wave THIN_PULSE, :C4, volume: :three_quarter }
        (count == 52).then { stop_wave }
        (count == 10).then { noise :explosion }
        (count == 50).then { noise pitch: :mid, decay: :medium, volume: 13, metallic: true }
        (count == 90).then { noise :zap }
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 140
    assert_sounds_like_the_native_runtime program, frames: 140, only: :wave
    assert_sounds_like_the_native_runtime program, frames: 140, only: :noise
  end

  # A pad on the wave voice and drums on the noise voice under a lead, the music volume reaching
  # both, and the pad left silent by `stop_wave` until the game's own `wave` switches the voice on.
  def test_a_songs_pad_and_drums_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:lead) { note :E5, :half; note :G5, :half }
        voice(:pad, plays: :sine) { volume 9; note :C3, :quarter; note :G3, :quarter; rest :quarter; note :C2, :quarter }
        voice(:drums, plays: :noise) { decay :slow; note :C3, :quarter; rest :quarter; note 4000, :quarter; note :C6, :quarter }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count.add! 1
        (count == 20).then { music_volume 50 }
        (count == 70).then { fade_music_out frames: 30 }
        (count == 130).then { fade_music_in frames: 30 }
        (count == 170).then { stop_wave }
        (count == 200).then { wave THIN_PULSE, :A3, volume: :half }
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 250
  end

  # A sound effect over a tune on the wave voice: each note puts its own waveform in.
  def test_a_sound_effect_over_a_tune_sounds_as_on_the_native_runtime
    score = VBlank::Audio::Score
    tune = score.new(tempo: 150, parts: [score::Part.new(plays: :triangle, notes: (0..5).map do |n|
      score::Note.new(at: n * 20, key: :C4, length: 15)
    end)])
    hit = score.new(tempo: 150, priority: 68, parts: [score::Part.new(plays: THIN_PULSE, volume: 12, notes: [
      score::Note.new(at: 0, key: :E5), score::Note.new(at: 10, key: :G5, length: 8),
    ])])
    program = sound_program do
      enable_sound
      music = songs :music, [tune]
      sfx = sound_effects :sfx, { hit: hit }
      count = var :count, 0
      game_loop do
        count.add! 1
        music.play 0
        (count == 25).then { sfx.play :hit }
        (count == 70).then { wave :sawtooth, :A3, volume: :half }
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 130
  end

  # Recordings on the mixer, two at once and one looping, under a beep: the mixer's slice is in
  # every sample the speaker plays.
  def test_mixed_recordings_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      boom = sample :boom, pcm: [0, 60, 0, -60] * 400, rate: 8000
      hum = sample :hum, pcm: ([0, 30, 50, 30, 0, -30, -50, -30] * 50), rate: 16_000
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 3).then { boom.play }
        (count == 8).then { hum.play(loop: true) }
        (count == 12).then { beep 440, duty: :half, decay: :medium, volume: 12 }
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 60
  end

  # Whole games. Pong: START, the zoom, and a rally long enough for its song to come round and the
  # ball to hit a wall and a paddle.
  def test_pongs_rally_sounds_as_on_the_native_runtime
    program = Native.new.checked_program(PongGame::GAME, err: nil)

    assert_sounds_like_the_native_runtime program, frames: 420, buttons: held(3..8 => [:a])
  end

  # The jukebox: a tune picked from its menu, played as recordings on the mixer, its two sound
  # effects over it, and its music faded out and in between two tunes.
  def test_the_jukeboxs_tunes_and_effects_sound_as_on_the_native_runtime
    program = Native.new.checked_program(Jukebox::GAME, err: nil)
    buttons = held(10..12 => [:down], 60..62 => [:a], 100..102 => [:b], 140..142 => [:down])

    assert_sounds_like_the_native_runtime program, frames: 220, buttons: buttons
  end

  private

  def sound_program(&block)
    builder = VBlank::Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # Runs of frames to the buttons held through them, as a frame number to its buttons.
  def held(runs) = runs.flat_map { |frames, buttons| frames.map { |frame| [frame, buttons] } }.to_h

  # Every sample of +frames+ frames, the same from both runtimes, and some of them not silence.
  # +only+ hears one voice (:square1, :square2, :wave, :noise).
  def assert_sounds_like_the_native_runtime(program, frames:, only: nil, buttons: {})
    native, under_test = [:native, runtime_under_test].map do |on|
      VBlank::Diagnostics::SoundRecording.of(program, on: on, frames: frames, buttons: buttons, only: only)
    end

    refute native.samples.all?(&:zero?), "the native runtime made no sound, so there is nothing to compare"
    first = native.first_difference(under_test)
    assert_nil first, "the two runtimes' sound differs first at sample #{first} " \
                      "(#{native.samples.length} samples against #{under_test.samples.length})"
  end
end
