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

  # A FRAME THAT MIXES FAR MORE THAN THE ONE BEFORE IT still hands over in one piece.
  #
  # The DMA takes a lot whenever the sound hardware asks, on a grid the clock fixes, and between
  # two hand-overs it takes as many lots as grid points fell between them. So a hand-over made
  # later than the last one takes a lot from past the end of the buffer. Made after the mix, a
  # hand-over was as late as that frame's mix was long — and here every voice but one joins on
  # the same frame, which makes that frame's mix many lots longer than the one before it.
  #
  # One voice is loud and already sounding, so a lot taken from the wrong place is a jump in a
  # wave that is there to hear. The voices that join are nearly silent: they are only there to
  # make the mix long.
  def test_voices_joining_a_sounding_one_do_not_break_it
    hz = 15_768
    wave = ->(height) { (0...hz).map { |i| (Math.sin(2 * Math::PI * 220 * i / hz) * height).round } }
    loud = wave.call(100)
    quiet = wave.call(1)
    joining = RubyGBA::Sound::MIXER_VOICES - 1
    rom = RubyGBA.build("MIXCLK", code: "BMXC", maker: "01", validate: false,
                        out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      lead = sample :lead, pcm: loud, rate: hz
      crowd = (1..joining).map { |n| sample :"quiet#{n}", pcm: quiet, rate: hz }
      frame = var :frame, 0
      game_loop do
        frame.add 1
        (frame == 5).then { lead.play loop: true }
        (frame == 20).then { crowd.each { |tone| tone.play loop: true } }
      end
    end
    v = assert_emulator_loads_rom(rom, frames: 40)
    left = v.audio_samples.each_slice(2).map(&:first)
    around = left[(12 * left.length / 40)...(30 * left.length / 40)] # the lead sounding, and the crowd joining it
    biggest = around.each_cons(2).map { |a, b| (b - a).abs }.max
    bar = steepest(v.sample_clock) * 2 * (100 + (quiet.max * joining)) / 100.0

    assert_operator biggest, :<, bar,
                    "a step of #{biggest} between neighbouring samples, and the voices together cannot " \
                    "climb faster than #{(bar / 2).round} — so the stream was broken where they joined"
  end

  # A GAME WHOSE PASS RUNS PAST THE END OF THE FRAME still hands over in one piece.
  #
  # The hand-over is the first thing the screen's interrupt does, but the interrupt itself can
  # be held off: a whole-screen clear is one long DMA, and nothing interrupts the console while
  # one runs. A game clearing the screen several times a pass is inside one of them when the
  # frame ends, a different distance through it every frame, so the hand-over lands a different
  # number of the DMA's lots late every frame.
  def test_a_game_busy_past_the_end_of_the_frame_does_not_break_the_sound
    [8192, 15_768, 22_050].each do |hz|
      pcm = (0...hz).map { |i| (Math.sin(2 * Math::PI * 220 * i / hz) * 100).round }
      rom = RubyGBA.build("MIXCLK", code: "BMXC", maker: "01", validate: false,
                          out: StringIO.new, err: StringIO.new) do
        screen :bitmap
        tone = sample :tone, pcm: pcm, rate: hz
        started = var :started, 0
        game_loop do
          (started == 0).then do
            started.set 1
            tone.play loop: true
          end
          8.times { clear_screen :black }
        end
      end
      v = assert_emulator_loads_rom(rom, frames: 60)
      left = v.audio_samples.each_slice(2).map(&:first)
      note = left[(15 * left.length / 60)..]
      biggest = note.each_cons(2).map { |a, b| (b - a).abs }.max
      bar = steepest(v.sample_clock) * 2

      assert_operator biggest, :<, bar,
                      "asked #{hz}: a step of #{biggest} between neighbouring samples, and the note " \
                      "cannot climb faster than #{steepest(v.sample_clock).round} — so the stream broke " \
                      "where the frame ended inside the game's own work"
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
