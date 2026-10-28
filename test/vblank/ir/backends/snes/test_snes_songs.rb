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
  ENVX = 0x8
  KEY_OFF = 0x5C

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

  private def played(frames:) = SNES::CheckedRun.new.run(TUNE.program(console: :snes), frames: frames).dsp_registers
end
