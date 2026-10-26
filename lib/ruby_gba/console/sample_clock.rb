# frozen_string_literal: true

module RubyGBA
  module Console
    # A SAMPLE CLOCK A PER-FRAME MIXER CAN ACTUALLY KEEP UP WITH.
    #
    # The mixer fills a buffer once a frame and points the sound copy at it; the copy then feeds
    # the hardware, which eats a sample every time a timer overflows. Handing over cleanly at every
    # frame boundary puts TWO conditions on the clock, and missing either one puts an impulse in
    # the sound at the frame rate — not a drift you notice after a minute, a rattle under the whole
    # soundtrack, like a rolled tongue. Both are measured (test_mixer_sample_clock.rb), not
    # reasoned about.
    #
    # ONE: as many samples must be written each frame as are read. The reads are fixed by the
    # clock — the timer overflows every +period+ cycles, so the hardware reads cycles_a_frame /
    # period samples a frame — and that is a whole number only when a frame divides by +period+
    # exactly. Which means the RATE is a consequence of picking a clock, not something to choose
    # first and then round. Picking it first is how this went wrong: a rate divided by a round 60
    # gave one sample a frame fewer than a console running at 59.7275 frames a second actually
    # eats.
    #
    # TWO: those samples must be a whole number of the lots the copy moves. It only ever moves
    # samples_a_copy at a time, so its read position lands on a lot boundary and nowhere else. Hand
    # it a buffer that is not a whole number of lots and every frame it either stops short of the
    # end or runs past it — past it into whatever is allocated next, which it plays.
    #
    # Together: +period+ must divide cycles_a_frame / samples_a_copy. Retail games land on the same
    # answer from the other end — the Game Boy Advance sound driver picks a samples-per-frame out of
    # a fixed table and derives its rate from that — and the entries of that table which are whole
    # lots are all in this set.
    #
    # So: take the rate the program's recordings suggest, and give back the nearest clock that
    # satisfies both. Nearest BY RATIO, because that is how a rate is heard. The author never names
    # this rate and never sees it: their recordings are resampled to it as they play, at the pitch
    # and for the duration they were recorded at, so landing off it costs a little bandwidth or a
    # little mixing and nothing else. `rom.profile` says which rate a game got.
    #
    # It is the console's, not a lowering's, because the interpreter mixes the very samples the
    # cartridge hands its hardware, and so has to mix them at the same rate.
    SampleClock = Data.define(:period, :rate, :samples_a_frame) do
      # The clock nearest +hz+ that +console+ (a Console::Description) can keep.
      def self.nearest(hz, console)
        cycles = console.cycles_a_second
        period = periods(console).min_by do |candidate|
          rate = cycles.fdiv(candidate)
          rate > hz ? rate / hz : hz / rate
        end
        new(period: period, rate: cycles / period, samples_a_frame: console.cycles_a_frame / period)
      end

      # The periods that meet both conditions, and that a 16-bit counter can reach with no
      # prescaler (past 65536 cycles it cannot, which puts a floor of 256Hz on all this).
      def self.periods(console)
        unless console.samples_a_copy
          raise ArgumentError, "A #{console.title} mixes no recordings. It has no sample clock."
        end

        whole = console.cycles_a_frame / console.samples_a_copy
        (1..Integer.sqrt(whole)).flat_map { |d| (whole % d).zero? ? [d, whole / d] : [] }
                                .select { |d| d <= 65_536 }.sort
      end
    end
  end
end
