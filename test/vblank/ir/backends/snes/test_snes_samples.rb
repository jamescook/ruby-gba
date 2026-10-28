# frozen_string_literal: true

require "test_helper"

# RECORDINGS ON A SUPER NINTENDO. The Advance's processor mixes every recording a game plays into
# one stream; the S-DSP plays each on a voice of its own, reading it from the sound unit's memory
# in BRR, its own packing of four bits a sample (fullsnes, "SNES APU DSP BRR Samples"). The
# cartridge keeps the interpreter's count of where each recording has got to, so it logs a loop
# coming round, and a recording ending, on the same frame; the voices sound the first four.
class TestSNESSamples < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Build = VBlank::IR::Build
  VOICE = 4 << 4 # the first voice recordings play on, past the four the Advance's voices take
  ENVX = 0x8
  TABLE = SNES::Runtime::Sound::TABLE_AT

  # 64 samples recorded at 32000 a second: a ramp of steps of sixteen, -112 up to 112 and back,
  # which BRR keeps exactly (each a whole number of its four-bit steps at the largest shift).
  RAMP = ((-7..7).to_a + (-7..7).to_a.reverse + (-7..7).to_a + (-7..7).to_a.reverse + [0, 0, 0, 0]).map { |n| n * 16 }
  CLIP = RAMP.pack("c*")

  private def game(*body, frames:)
    program = Build.program(Build.enable_sound, Build.sample(:clip, CLIP, 32_000), *body, Build.loop_(Build.wait_vblank))
    program.console = :snes # the interpreter mixes at the Super Nintendo's rate
    SNES::CheckedRun.new.run(program, frames: frames)
  end

  # Played at the note it was recorded at, a recording made at 32000 a second reads one sample of
  # itself for each of the DSP's: pitch $1000. At :full it is 127 on both sides, held at a fixed gain.
  def test_a_recording_plays_on_a_voice_of_its_own
    run = game(Build.play_sample(:clip, loop: true), frames: 2)
    dsp = run.dsp_registers

    assert_equal [0x00, 0x10], [dsp.getbyte(VOICE + 2), dsp.getbyte(VOICE + 3)], "the pitch"
    assert_equal [0x7F, 0x7F], [dsp.getbyte(VOICE), dsp.getbyte(VOICE + 1)], "the volume"
    assert_equal 0x7F, dsp.getbyte(VOICE + ENVX), "sounding"
    assert_equal [:clip], run.active_samples
  end

  # The recording in the sound unit's memory, decoded as fullsnes decodes BRR with filter nought:
  # each four-bit sample shifted left by the block's range and right by one. Every step of sixteen
  # comes back as that step times 128, the sixteen bits a sample the DSP mixes in.
  def test_the_recording_is_kept_in_brr
    run = game(Build.play_sample(:clip, loop: true), frames: 2)
    ram = run.apu_ram
    source = run.dsp_registers.getbyte(VOICE + 4)
    start = ram.getbyte(TABLE + (source * 4)) | (ram.getbyte(TABLE + (source * 4) + 1) << 8)
    decoded = ram.byteslice(start, 9 * 4).bytes.each_slice(9).flat_map do |header, *bytes|
      range = header >> 4
      bytes.flat_map { |byte| [byte >> 4, byte & 0xF] }.map { |n| ((n >= 8 ? n - 16 : n) << range) >> 1 }
    end

    assert_equal RAMP.map { |sample| sample * 128 }, decoded
  end

  # A recording played once ends: 64 samples at 32000 a second last two milliseconds, gone by the next
  # frame; its voice falls silent (ENVX nought), and nothing sounds.
  def test_a_recording_played_once_ends
    run = game(Build.play_sample(:clip), frames: 4)

    assert_equal 0, run.dsp_registers.getbyte(VOICE + ENVX)
    assert_empty run.active_samples
  end

  # A recording asked to loop comes round from its start, 532 samples of the DSP's a frame against
  # 64 of it, and the log says so each time round, as the interpreter's does.
  def test_a_looping_recording_logs_each_time_round
    run = game(Build.play_sample(:clip, loop: true), frames: 3)

    assert_operator run.audio.count([:sample, :clip]), :>, 10
  end

  # A recording that holds from a point not on a block, round a held part of 37 samples, a length no
  # block divides: the cartridge's count logs it coming round as the interpreter's mix does, frame by
  # frame (the checked run holds both), and the voice sounds on, the held part laid out on whole
  # blocks (Samples.recording).
  def test_a_recording_held_from_a_point_off_a_block_comes_round_with_the_interpreter
    program = Build.program(Build.enable_sound, Build.sample(:held, CLIP.byteslice(0, 40), 32_000, holds_from: 3),
                            Build.play_sample(:held, loop: true), Build.loop_(Build.wait_vblank))
    program.console = :snes
    run = SNES::CheckedRun.new.run(program, frames: 6)

    assert_equal 0x7F, run.dsp_registers.getbyte(VOICE + ENVX)
    assert_equal [:held], run.active_samples
  end

  # At :half the mix takes 256 of 512, which is 127 * 256 / 512 = 63.5 of the DSP's volume, 64 ($40);
  # an octave up, C5 against the C4 it was recorded at, reads 523 / 262 of a sample each of the
  # DSP's: 65536 * 523 / 262 = 130824 (IR::Mixing.step, rounded), over 16, $1FF0.
  def test_volume_and_pitch_reach_the_voice
    dsp = game(Build.play_sample(:clip, loop: true, volume: :half, pitch: :C5), frames: 2).dsp_registers

    assert_equal 0x40, dsp.getbyte(VOICE), "the volume"
    assert_equal [0xF0, 0x1F], [dsp.getbyte(VOICE + 2), dsp.getbyte(VOICE + 3)], "the pitch"
  end

  # Five recordings at once: the first four on voices 4 to 7, the fifth counted and not heard.
  def test_a_fifth_recording_is_counted_and_not_heard
    run = game(*Array.new(5) { Build.play_sample(:clip, loop: true) }, frames: 2)
    sounding = (4..7).map { |voice| run.dsp_registers.getbyte((voice << 4) + ENVX) }

    assert_equal [:clip] * 5, run.active_samples
    assert_equal [0x7F] * 4, sounding
  end

  # stop_sample with no name stops every recording.
  def test_stop_sample_with_no_name_stops_them_all
    n = Build.var_ref(:n)
    program = Build.program(Build.enable_sound, Build.sample(:clip, CLIP, 32_000), Build.play_sample(:clip, loop: true),
                            Build.play_sample(:clip, loop: true),
                            Build.loop_(Build.add(:n, 1), Build.if_(Build.binop(:==, n, Build.int(2)), Build.stop_sample),
                                        Build.wait_vblank))
    program.console = :snes
    run = SNES::CheckedRun.new.run(program, frames: 5)

    assert_equal [0, 0], [run.dsp_registers.getbyte(VOICE + ENVX), run.dsp_registers.getbyte((5 << 4) + ENVX)]
    assert_empty run.active_samples
  end

  # A recording beside a song: each frame moves the recordings on before the music plays, as the
  # interpreter's does, and the checked run holds the log's order to it.
  def test_a_recording_beside_a_song_logs_in_the_interpreters_order
    program = Build.program(Build.enable_sound, Build.sample(:clip, CLIP, 32_000),
                            Build.song(:tune, events: [[0, 440], [2, 494]], total_frames: 4),
                            Build.play_sample(:clip, loop: true), Build.play_song(:tune), Build.loop_(Build.wait_vblank))
    program.console = :snes
    run = SNES::CheckedRun.new.run(program, frames: 5)

    assert_includes run.audio, [:note, :tune, 494]
  end

  # stop_sample lets its voice go.
  def test_stop_sample_silences_it
    n = Build.var_ref(:n)
    program = Build.program(Build.enable_sound, Build.sample(:clip, CLIP, 32_000), Build.play_sample(:clip, loop: true),
                            Build.loop_(Build.add(:n, 1), Build.if_(Build.binop(:==, n, Build.int(2)), Build.stop_sample(:clip)),
                                        Build.wait_vblank))
    program.console = :snes
    run = SNES::CheckedRun.new.run(program, frames: 5)

    assert_equal 0, run.dsp_registers.getbyte(VOICE + ENVX)
    assert_empty run.active_samples
  end
end
