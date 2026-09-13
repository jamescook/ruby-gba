# frozen_string_literal: true

require "test_helper"
require "stringio"

# THE SAMPLE CLOCK — how fast the mix feeds the sound hardware, and how much it writes a frame.
#
# The mixer fills a buffer once a frame and points the sound DMA at it. Handing over cleanly at
# every frame boundary puts two conditions on the clock, and missing either one puts an impulse
# in the sound at the frame rate — not a drift you notice after a minute, a rattle under the
# whole soundtrack, like a rolled tongue.
#
#   ONE  as many samples are written each frame as are read. The reads are fixed by the clock,
#        so this is only a whole number when a frame divides by the clock's period. Picking a
#        rate first and dividing it by a round 60 gives one sample a frame too few, because the
#        console runs at 59.7275 frames a second.
#   TWO  those samples are a whole number of the lots the DMA moves. It only ever moves 16 at a
#        time, so hand it a buffer that is not a whole number of lots and every frame it either
#        stops short of the end or runs past it — into whatever is allocated next, which it plays.
#
# Both are measured here on the console rather than argued about, because both were argued about
# first and only one of them was right.
class TestMixerSampleClock < Minitest::Test
  Timers = GBA::Timers

  # Rates worth asking for: two that a real cartridge records at, the framework's own default,
  # and two that are nowhere near the grid.
  ASKED = [8192, 11025, 13379, 15768, 22050, 44100, 5000].freeze

  # --- the clock itself ---

  def test_the_console_reads_exactly_as_many_samples_a_frame_as_the_mix_writes
    ASKED.each do |hz|
      clock = Timers.sample_clock(hz)
      assert_equal Timers::FRAME_CYCLES, clock.period * clock.samples_a_frame,
                   "asked #{hz}: a frame is not #{clock.samples_a_frame} lots of #{clock.period} cycles"
    end
  end

  def test_a_frame_is_a_whole_number_of_the_lots_the_dma_moves
    ASKED.each do |hz|
      clock = Timers.sample_clock(hz)
      assert_equal 0, clock.samples_a_frame % Timers::DMA_SAMPLES_A_LOT,
                   "asked #{hz}: #{clock.samples_a_frame} a frame is not whole lots of " \
                   "#{Timers::DMA_SAMPLES_A_LOT}, so the DMA is re-pointed mid-lot"
    end
  end

  def test_the_clock_is_the_rate_it_was_asked_for_or_close
    ASKED.each do |hz|
      rate = Timers.sample_clock(hz).rate
      apart = rate > hz ? rate.fdiv(hz) : hz.fdiv(rate)
      assert_operator apart, :<, 1.3, "asked #{hz} and got #{rate}, which is too far to call near"
    end
  end

  # A rate already on the grid is left alone — the snap is a repair, not a preference.
  def test_a_rate_the_hardware_can_already_sustain_is_kept
    clock = Timers.sample_clock(13_379)

    assert_equal 224, clock.samples_a_frame
    assert_equal 13_378, clock.rate # 16777216/1254, which is 13379 to the nearest whole number
  end

  # --- what came out of the speaker ---

  # A held sine, and the silence after it. Built at a rate whose naive clock would divide a
  # frame into 137.16 samples — the case that went wrong — so this fails on the old arithmetic.
  def sounded(hz, frames: 90, stop_at: 40)
    pcm = (0...hz).map { |i| (Math.sin(2 * Math::PI * 220 * i / hz) * 100).round }
    rom = RubyGBA.build("MIXCLK", code: "BMXC", maker: "01", validate: false,
                        out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      tone = sample :tone, pcm: pcm, rate: hz
      started = var :started, 0
      frame = var :frame, 0
      game_loop do
        frame.add 1
        (started == 0).then do
          started.set 1
          tone.play loop: true
        end
        (frame == stop_at).then { tone.stop }
      end
    end
    v = assert_emulator_loads_rom(rom, frames: frames)
    [v, v.audio_samples.each_slice(2).map(&:first)] # one channel is enough
  end

  # The steepest a 220Hz sine of this height can climb between two output samples. The emulator
  # holds each of the mix's samples, so a step is one of the mix's, and a break in the stream
  # measures several times this.
  def steepest(clock)
    amplitude = 100 / 128.0 * 32_767
    amplitude * 2 * Math::PI * 220 / clock.rate
  end

  def test_a_held_note_comes_out_in_one_piece
    [8192, 15_768].each do |hz|
      v, left = sounded(hz)
      note = left[(15 * left.length / 90)...(33 * left.length / 90)] # clear of the start and the stop
      biggest = note.each_cons(2).map { |a, b| (b - a).abs }.max
      bar = steepest(v.sample_clock) * 2

      assert_operator biggest, :<, bar,
                      "asked #{hz}: a step of #{biggest} between neighbouring samples, and the " \
                      "note itself cannot climb faster than #{steepest(v.sample_clock).round} — " \
                      "so the stream was broken"
    end
  end

  # Nothing sounding means nothing at all. This is the half that catches the DMA running off
  # the end of a buffer: what is allocated next is the voice slots, and it plays those.
  def test_the_silence_after_a_note_is_silent
    [8192, 15_768].each do |hz|
      _v, left = sounded(hz)
      tail = left[(55 * left.length / 90)..]

      assert_equal 0, tail.map(&:abs).max,
                   "asked #{hz}: the note was stopped, so every sample after it should be zero"
    end
  end
end
