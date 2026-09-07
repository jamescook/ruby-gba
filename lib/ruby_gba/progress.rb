# frozen_string_literal: true

module RubyGBA
  # WHAT A BUILD SAYS IT IS DOING WHILE IT DOES IT.
  #
  # A big game takes a while to build, and a build that says nothing is indistinguishable from
  # one that has hung. This is what a build talks to. It is deliberately a THING rather than a
  # stream and a flag, because "how much to show" then belongs to the sink at the end rather
  # than to the forty places along the way that have something to say.
  #
  # THREE METHODS, because a build has three kinds of thing to say:
  #
  #   progress.step "the guardrails"      a named phase begins
  #   progress.of 14, 27, "DrawBudget"    ...and where it has got to, when that can be counted
  #   progress.tick                       ...or only that it is still going, when it cannot
  #
  # THIS CLASS IS THE ONE THAT SAYS NOTHING, and it is the default everywhere. Every method is
  # here and every one does nothing, so no caller ever has to ask whether anybody is listening —
  # a `&.` at forty call sites would read as uncertainty about something that is never actually
  # uncertain, and a nil check at forty call sites is forty chances to forget one.
  #
  #   RubyGBA.build(...)                                   # says nothing, costs nothing
  #   RubyGBA.build(..., progress: Progress.to($stderr))   # says what it is doing
  #
  # NO PERCENTAGE, ANYWHERE. Two of a build's phases have no bound — there is no way to know
  # how many instructions are coming — so a denominator would have to be invented, and an
  # invented one is a lie that gets believed. Elapsed time per phase instead: truthful, and it
  # is also the number that tells you when something got slower.
  class Progress
    def step(name) = nil
    def of(done, total, name = nil) = nil
    def tick = nil

    # The last phase is over. Anything holding a line open closes it here.
    def done = nil

    # The one that says nothing, shared — it has no state to keep apart.
    SILENT = new

    def self.silent = SILENT

    # ...and one that writes to a stream. See {Printed}.
    def self.to(out) = Printed.new(out)

    # A progress that writes what it is told.
    #
    # HOW MUCH IT SHOWS DEPENDS ON WHERE IT IS WRITING, which is the whole reason the sink is
    # a thing of its own. Writing to a terminal, it keeps ONE line and rewrites it in place, so
    # a phase that reports ten times a second reads as a phase getting on with it. Writing
    # anywhere else — a file, a pipe, a test's StringIO — it writes one line per phase when
    # that phase finishes, because a log wants to be read afterwards and a carriage return in a
    # log is noise.
    #
    # SO A TEST SEES ONE TIDY LINE PER PHASE, which is what makes this checkable at all.
    class Printed < Progress
      # How often a live line may be rewritten. Ten times a second looks continuous and is far
      # less work than the thing being reported on.
      EVERY = 0.1

      # Ticks are counted, and the clock is only consulted every so many of them. A phase can
      # tick a hundred thousand times, and asking the clock that often would cost more than the
      # work being reported.
      CLOCK_EVERY = 256

      def initialize(out, clock: Process)
        super()
        @out = out
        @clock = clock
        @live = out.respond_to?(:tty?) && out.tty?
        @name = nil
        @ticks = 0
      end

      # A phase begins. Whatever was running is finished and written out first, so a phase's
      # elapsed time is only ever reported once it really has elapsed.
      def step(name)
        finish
        @name = name
        @started = now
        @ticks = 0
        @where = nil
        show if @live
        nil
      end

      # Where a countable phase has got to. Cheap enough to call from a loop: it remembers the
      # numbers and only writes when a line is due.
      def of(done, total, name = nil)
        @where = name ? "#{done} of #{total}  #{name}" : "#{done} of #{total}"
        show_if_due
        nil
      end

      # ...and the same for a phase with no bound. Counting is all it can honestly say.
      def tick
        @ticks += 1
        return nil unless (@ticks % CLOCK_EVERY).zero?

        @where = "#{@ticks}"
        show_if_due
        nil
      end

      def done
        finish
        nil
      end

      private

      def now = @clock.clock_gettime(Process::CLOCK_MONOTONIC)

      # Close the phase that was running: on a terminal the live line is replaced one last
      # time and left; anywhere else this is the only line that phase ever writes.
      def finish
        return unless @name

        @out.print("\r") if @live
        @out.puts(line)
        @name = nil
      end

      def show_if_due
        return unless @live
        return if @shown && now - @shown < EVERY

        show
      end

      def show
        @shown = now
        @out.print("\r#{line}")
        @out.flush if @out.respond_to?(:flush)
      end

      # "  the guardrails  27 of 27  DrawBudget  1.4s" — the phase, where it got to, how long
      # it took. Padded so a run of phases lines up as a column rather than a ragged edge.
      def line
        parts = ["  #{@name.to_s.ljust(34)}"]
        parts << @where.to_s.ljust(24)
        parts << format("%5.1fs", now - @started)
        parts.join.rstrip
      end
    end
  end
end
