# frozen_string_literal: true

require "test_helper"

# A SONG ON A SUPER NINTENDO. The Advance plays a song's square parts on its two square voices, a
# note at a time from the screen's interrupt; here each part's notes are DSP writes on the voice the
# Advance's square voice is (voice 0 for the first, voice 1 for the second, which beeps share), sent
# as each note's frame comes. A note holds at a fixed level, as the Advance's song notes do, and a
# rest or stop_music lets the voice go. The checked run holds the sound log and the DSP's registers
# to the interpreter's, as for a beep (test_snes_beep.rb); what each write should be is held by the
# tests below, to fullsnes's numbers worked by hand or to the DSP's own envelope.
class TestSNESSongs < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  FIRST = 0 << 4 # the first register of voice 0, the Advance's first square voice
  SECOND = 1 << 4
  WAVE = 2 << 4 # the Advance's third voice
  NOISE = 3 << 4 # ...and its fourth
  ENVX = 0x8
  KEY_OFF = 0x5C
  NOISE_ON = 0x3D
  FLAGS = 0x6C

  # Two parts, a quarter of eight frames each: A4 over A3, then a rest on the first part.
  TUNE = VBlank.game("TUNE", consoles: %i[gba snes]) do
    enable_sound
    song :tune do
      tempo 450
      voice(:lead) do
        note :A4, :quarter
        rest :quarter
      end
      voice(:bass) do
        duty :quarter
        volume 8
        note :A3, :half
      end
    end
    n = var :n, 0
    game_loop do
      n.add! 1
      (n < 20).then { play_song :tune }
      (n == 20).then { stop_music }
      (n == 24).then { play_song :tune }
    end
  end

  # The log agreeing, and every DSP write it means arriving, through the song, a stop and the song
  # started again.
  def test_the_sound_log_agrees_and_every_dsp_write_arrives
    run = SNES::CheckedRun.new.run(TUNE.program(console: :snes), frames: 30)

    assert_includes run.audio, [:stop_music]
    assert_operator run.audio.count { |entry| entry.first == :note }, :>=, 5
  end

  # A4 on the first part, each register from fullsnes: 440 waves a second of 32 samples is 14080
  # samples a second, pitch 14080 * $1000 / 32000 = $070A; a volume of 12 is 96 ($60), as a beep at
  # 12; a fixed gain at the top, so the envelope (ENVX) holds at $7F.
  def test_a_square_note_holds_its_voice_at_a_fixed_level
    dsp = played(frames: 3)

    assert_equal [0x0A, 0x07], [dsp.getbyte(FIRST + 2), dsp.getbyte(FIRST + 3)], "the pitch"
    assert_equal [0x60, 0x60], [dsp.getbyte(FIRST), dsp.getbyte(FIRST + 1)], "the volume"
    assert_equal 0x7F, dsp.getbyte(FIRST + 7), "a fixed gain"
    assert_equal 0x7F, dsp.getbyte(FIRST + ENVX), "the envelope held at the gain"
  end

  # Both parts sound at once, each on its own voice: A3 is $0385, at volume 8 ($40).
  def test_two_parts_sound_at_once
    dsp = played(frames: 3)

    assert_equal [0x85, 0x03], [dsp.getbyte(SECOND + 2), dsp.getbyte(SECOND + 3)], "the second part's pitch"
    assert_equal 0x40, dsp.getbyte(SECOND), "the second part's volume"
    assert_equal [0x7F, 0x7F], [dsp.getbyte(FIRST + ENVX), dsp.getbyte(SECOND + ENVX)], "both sounding"
  end

  # The first part's rest lets its voice go, and the envelope falls to nought; the second part's
  # half note sounds on.
  def test_a_rest_lets_the_voice_go
    dsp = played(frames: 12)

    assert_equal 0, dsp.getbyte(FIRST + ENVX), "the first part silent"
    assert_equal 0x7F, dsp.getbyte(SECOND + ENVX), "the second sounding"
  end

  # stop_music lets every voice go.
  def test_stop_music_silences_the_song
    dsp = played(frames: 22)

    assert_equal [0, 0], [dsp.getbyte(FIRST + ENVX), dsp.getbyte(SECOND + ENVX)]
  end

  # A beep after stop_music sounds: the key-off that stopped the voice it shares with the song holds
  # until something clears it, and a key-on under it plays nothing (fullsnes, "KON/KOFF Notes").
  def test_a_beep_after_stop_music_sounds
    game = VBlank.game("BEEPAFTER", consoles: %i[gba snes]) do
      enable_sound
      song(:tune) { voice(:lead) { note :A4, :whole } }
      define_sound :ping, frequency: 880, decay: :none
      n = var :n, 0
      game_loop do
        n.add! 1
        (n == 1).then { play_song :tune }
        (n == 3).then { stop_music }
        (n == 5).then { beep :ping }
      end
    end
    dsp = SNES::CheckedRun.new.run(game.program(console: :snes), frames: 7).dsp_registers

    assert_operator dsp.getbyte(SECOND + ENVX), :>, 0, "the beep sounding"
    assert_equal 0, dsp.getbyte(KEY_OFF) & (1 << 1), "its key-off cleared"
  end

  # A tune stopping lets go of its own parts' voices and no other: a beep beside a one-part tune
  # sounds on through stop_music, as on the Advance.
  def test_stop_music_leaves_a_beep_beside_the_tune_sounding
    game = VBlank.game("BEEPBESIDE", consoles: %i[gba snes]) do
      enable_sound
      song(:tune) { voice(:lead) { note :A4, :whole } }
      define_sound :ping, frequency: 880, decay: :none
      n = var :n, 0
      game_loop do
        n.add! 1
        (n == 1).then { play_song :tune }
        (n == 3).then { beep :ping }
        (n == 4).then { stop_music }
      end
    end
    dsp = SNES::CheckedRun.new.run(game.program(console: :snes), frames: 7).dsp_registers

    assert_equal 0, dsp.getbyte(FIRST + ENVX), "the tune let go"
    assert_operator dsp.getbyte(SECOND + ENVX), :>, 0, "the beep sounding on"
  end

  # The player's awkward moments, each held to the interpreter's log and DSP writes by the checked
  # run: a stop and a play in one pass start the tune over, a tune named `this_frame:` plays its
  # first frame where it is named, and a tune that plays once ends and stays quiet while named.
  def test_a_restart_a_tune_started_this_frame_and_a_tune_that_ends
    build = VBlank::IR::Build
    n = build.var_ref(:n)
    program = build.program(
      build.enable_sound,
      build.song(:tune, events: [[0, 440], [3, 494]], total_frames: 6),
      build.song(:finale, events: [[0, 294]], total_frames: 2, plays_once: true),
      build.loop_(
        build.add(:n, 1),
        build.if_(build.binop(:==, n, build.int(1)), build.play_song(:tune)),
        build.if_(build.binop(:==, n, build.int(4)), build.stop_music, build.play_song(:tune)),
        build.if_(build.binop(:==, n, build.int(8)), build.play_song(:finale, this_frame: true)),
        build.wait_vblank
      )
    )
    run = SNES::CheckedRun.new.run(program, frames: 14)

    assert_equal 3, run.audio.count([:stop_music]), "stopped for the restart, for the finale, and at its end"
    assert_equal 0, run.dsp_registers.getbyte(FIRST + ENVX), "quiet after the finale"
  end

  # A wave part and a noise part, each on the voice the Advance's is: A4 on the wave voice (voice 2)
  # as `wave` plays it — pitch $070A on 32 samples, the first waveform recorded (source 9), volume
  # 120 ($78), held at the gain ($7F); and a hiss at 4096 Hz on the noise voice (voice 3). 4096 Hz is
  # the Advance's rung 524288 / 1 / 2^7, and the DSP's nearest noise rate is 25 (32000 / 8 = 4000 a
  # second, against 5333 for 26), so FLG reads $20 | $19; its volume 12 is 96, cut to the noise
  # generator's swing (7/16) as a `noise` hit's is, 42 ($2A). A rest on each lets its voice go.
  def test_wave_and_noise_parts_play_on_their_own_voices
    dsp = parts_played(frames: 3)

    assert_equal [0x0A, 0x07, 9], [dsp.getbyte(WAVE + 2), dsp.getbyte(WAVE + 3), dsp.getbyte(WAVE + 4)],
                 "the wave part's pitch and recording"
    assert_equal 0x78, dsp.getbyte(WAVE), "the wave part's volume"
    assert_equal 0x7F, dsp.getbyte(WAVE + ENVX), "the wave part held at the gain"
    assert_equal 1 << 3, dsp.getbyte(NOISE_ON), "the noise voice on the generator"
    assert_equal 0x39, dsp.getbyte(FLAGS), "the generator's rate"
    assert_equal 0x2A, dsp.getbyte(NOISE), "the hiss's volume"
    assert_operator dsp.getbyte(NOISE + ENVX), :>, 0, "the hiss sounding"
  end

  def test_a_rest_on_a_wave_or_noise_part_lets_its_voice_go
    dsp = parts_played(frames: 8)

    assert_equal [0, 0], [dsp.getbyte(WAVE + ENVX), dsp.getbyte(NOISE + ENVX)]
  end

  # A note's own volume, not its part's, on the wave and noise voices too, as the Color's player
  # plays it: a hiss note at 5 of a part at 12 is 5 * 8 * 7/16 = 17.5, 18 ($12).
  def test_a_noise_note_plays_at_its_own_volume
    build = VBlank::IR::Build
    part = VBlank::Audio::Music::Part
    program = build.program(
      build.enable_sound,
      build.song(:drum, total_frames: 8, voices: [part.new(events: [[0, 4096, nil, 5]], noise: true, decay: :none)]),
      build.play_song(:drum),
      build.loop_(build.wait_vblank)
    )
    dsp = SNES::CheckedRun.new.run(program, frames: 3).dsp_registers

    assert_equal 0x12, dsp.getbyte(NOISE)
  end

  # The wave part, after its rest, sounds again as the tune comes round (frame 12): its key-off
  # cleared before its key-on.
  def test_a_wave_part_sounds_again_after_its_rest
    assert_equal 0x7F, parts_played(frames: 15).getbyte(WAVE + ENVX)
  end

  # A square part written after a wave part still plays on the first square voice, and stop_music
  # lets go of the wave voice the song plays on.
  def test_mixed_parts_and_stop_music
    build = VBlank::IR::Build
    part = VBlank::Audio::Music::Part
    n = build.var_ref(:n)
    program = build.program(
      build.enable_sound,
      build.song(:mix, total_frames: 16, voices: [part.new(events: [[0, 220]], wave: :sine), part.new(events: [[0, 440]])]),
      build.play_song(:mix),
      build.loop_(build.add(:n, 1), build.if_(build.binop(:==, n, build.int(4)), build.stop_music), build.wait_vblank)
    )
    sounding = SNES::CheckedRun.new.run(program, frames: 3).dsp_registers
    stopped = SNES::CheckedRun.new.run(program, frames: 7).dsp_registers

    assert_equal [0x0A, 0x07], [sounding.getbyte(FIRST + 2), sounding.getbyte(FIRST + 3)], "the square on voice 0"
    assert_equal 0x7F, sounding.getbyte(WAVE + ENVX), "the wave part sounding"
    assert_equal [0, 0], [stopped.getbyte(FIRST + ENVX), stopped.getbyte(WAVE + ENVX)], "both let go"
  end

  # THE MUSIC VOLUME. At music_volume 50 the level is 8 of 16, so a square note at 12 sounds at
  # 12 * 8 / 16 = 6, volume 48 ($30); and a wave part at 15 at 7, which the Advance plays at the
  # nearest of its wave voice's five loudnesses, :half (7 * 4 / 15 rounds to 2), so the voice
  # changes to its recording at :half, a quarter of the way down the ladder from the note's own.
  def test_music_volume_reaches_the_notes_sounding
    full = volume_played(frames: 3)
    half = volume_played(frames: 8)

    assert_equal [0x60, 0x30], [full.getbyte(FIRST), half.getbyte(FIRST)], "the square part, then at half"
    refute_equal full.getbyte(WAVE + 4), half.getbyte(WAVE + 4), "the wave part's recording at :half"
    assert_equal 0x7F, half.getbyte(WAVE + ENVX), "still sounding"
  end

  # A fade out takes the level to nought over its frames, and every part with it.
  def test_fade_music_out_quiets_the_song
    dsp = volume_played(frames: 24)

    assert_equal [0, 0], [dsp.getbyte(FIRST), dsp.getbyte(FIRST + 1)]
  end

  private def volume_played(frames:)
    game = VBlank.game("VOLUME", consoles: %i[gba snes]) do
      enable_sound
      song :tune do
        voice(:lead) { note :A4, :whole }
        voice(:hum, plays: :wave) do
          volume 15
          note :A3, :whole
        end
      end
      n = var :n, 0
      game_loop do
        n.add! 1
        (n == 1).then { play_song :tune }
        (n == 5).then { music_volume 50 }
        (n == 10).then { fade_music_out frames: 6 }
      end
    end
    SNES::CheckedRun.new.run(game.program(console: :snes), frames: frames).dsp_registers
  end

  private def parts_played(frames:)
    build = VBlank::IR::Build
    part = VBlank::Audio::Music::Part
    program = build.program(
      build.enable_sound,
      build.song(:drums, total_frames: 12, voices: [part.new(events: [[0, 440], [4, 0]], wave: :triangle),
                                                     part.new(events: [[0, 4096], [4, 0]], noise: true, decay: :none)]),
      build.play_song(:drums),
      build.loop_(build.wait_vblank)
    )
    SNES::CheckedRun.new.run(program, frames: frames).dsp_registers
  end

  private def played(frames:) = SNES::CheckedRun.new.run(TUNE.program(console: :snes), frames: frames).dsp_registers
end
