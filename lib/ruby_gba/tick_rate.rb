# frozen_string_literal: true

module RubyGBA
  # WHAT RATE IS THIS TIMER REALLY DELIVERING? Counted, on a real run.
  #
  # THE FOOTGUN THIS IS ABOUT. `timer :beat, per_second: N` raises an interrupt N times a
  # second and `on_tick` is what it runs. There is NO QUEUE: a tick that arrives while the
  # last one is still being answered is dropped. So a game can quietly run at a fraction of
  # the rate it asked for, and nothing on screen says so — the sound is just slower, or the
  # reading just coarser, than it should be. This puts the number in front of somebody.
  #
  # HOW IT IS COUNTED, and it is a count rather than an estimate. The profiling loop steps
  # one instruction at a time and records the program counter each time, so the histogram is
  # exact. A handler's first instruction runs exactly once per tick ANSWERED — the dispatcher
  # has already branched past it when that timer did not fire — so the hits on that one
  # address are the ticks that arrived.
  #
  # WHAT IT IS HELD AGAINST is real time, and this is the part that has to be right: elapsed
  # time is HARDWARE frames over sixty, never passes of the game loop. A timer ticks in real
  # time whatever the game does, and interrupts preempt the main loop — so a game running at
  # thirty frames a second with a handler that keeps up delivers its full rate. Measuring
  # against passes would make every frame-dropping game look broken.
  #
  # == WHY THIS REPORTS A NUMBER AND DOES NOT WARN ==
  #
  # The obvious next step is to warn when the rate delivered falls short of the rate asked
  # for, and to blame the handler. Measured, that does not work, because a handler is not the
  # main thing that costs ticks. DRAWING IS. A transfer stalls the console and holds
  # interrupts off while it runs, so a full-screen clear — the most ordinary thing a game
  # does — swallows ticks all on its own. With a handler that does one addition:
  #
  #   clears a frame:      1        2        4
  #   share of 4096 Hz:    0.81     0.62     0.24
  #
  # A handler too slow to keep up answers every second tick, which is 0.5. Ordinary drawing
  # reaches 0.24. The two ranges overlap completely, so no threshold can tell them apart, and
  # a warning built on one would fire on games that are perfectly fine and stay quiet for
  # some that are not.
  #
  # So the rate is reported and the cause is left open. Telling somebody their handler is too
  # slow when their `clear_screen` did it would send them to rewrite the wrong code — worse
  # than saying nothing, because it looks like an answer.
  module TickRate
    # WHAT A RUN SAW, for one timer. +asked+ is the rate the program wanted and +got+ the
    # rate that arrived. A reading that could not be taken says so with #measured? false, so
    # "we could not tell" never reads as "nothing was wrong".
    Reading = Data.define(:name, :asked, :got) do
      def self.unmeasured(name, asked) = new(name: name, asked: asked, got: nil)

      def measured? = !got.nil?

      # How much of the asked-for rate arrived, 0.0 to 1.0.
      def share = measured? && asked.positive? ? got.to_f / asked : 0.0

      # Worth putting in front of somebody: enough of the rate is missing that it would
      # change what the game does. Not a fault and not a cause — see the note above on why
      # this reports rather than warns.
      def short? = measured? && share < NOTEWORTHY
    end

    # How much of the rate has to be missing before the line is worth printing. A tick either
    # way at any rate worth using is far inside this, and a fifth of the rate gone is a
    # difference somebody can hear.
    NOTEWORTHY = 0.9

    # How many ticks a run has to expect before the count means anything. At four ticks a
    # second over a one-second window there are four to count, and one either way is a
    # quarter of the answer — a ratio like that is noise rather than a reading. The fast
    # timers, which are the ones that lose ticks at all, are far above this.
    ENOUGH_TICKS = 40

    module_function

    # Read one timer: +ticks+ is how many times its handler ran, +seconds+ how long the run
    # really was. A rate too slow to judge over that window comes back unmeasured rather than
    # guessed at.
    def read(name:, asked:, ticks:, seconds:)
      return Reading.unmeasured(name, asked) if seconds <= 0 || (asked * seconds) < ENOUGH_TICKS

      Reading.new(name: name, asked: asked, got: (ticks / seconds).round)
    end
  end
end
