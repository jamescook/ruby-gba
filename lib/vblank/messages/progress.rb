# frozen_string_literal: true

module VBlank
  module Messages
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
    #   progress.report_count 14, 27, "draw budget"   ...and where it has got to, when that can be counted
    #   progress.tick                       ...or only that it is still going, when it cannot
    #
    # A tick may carry a label — `tick { "#{bytes} bytes" }` — and it is a BLOCK because a tick
    # happens tens of thousands of times and a line is drawn a few times a second. The block runs
    # only when a line is actually due, so building the label costs nothing the rest of the time.
    #
    # THIS CLASS IS THE ONE THAT SAYS NOTHING, and it is the default everywhere. Every method is
    # here and every one does nothing, so no caller ever has to ask whether anybody is listening —
    # a `&.` at forty call sites would read as uncertainty about something that is never actually
    # uncertain, and a nil check at forty call sites is forty chances to forget one.
    #
    #   VBlank.build(...)                                   # says nothing, costs nothing
    #   VBlank.build(..., progress: Progress.to($stderr))   # says what it is doing
    #
    # NO PERCENTAGE, ANYWHERE. Two of a build's phases have no bound — there is no way to know
    # how many instructions are coming — so a denominator would have to be invented, and an
    # invented one is a lie that gets believed. Elapsed time per phase instead: truthful, and it
    # is also the number that tells you when something got slower.
    class Progress
      def step(name) = nil
      def report_count(done, total, name = nil) = nil
      def tick = nil

      # The last phase is over. Anything holding a line open closes it here.
      def done = nil

      # A PHASE MADE OF PHASES: begin the phase +name+, and hand back a progress for the work
      # inside it, whose own phases are only ever this one's detail — what it is doing now —
      # rather than lines of their own. A build that builds the game once to measure it is one
      # step of the real build, not a second list of everything. The one that says nothing has
      # nothing to fold, so it hands itself back.
      def as_one_line(name)
        step(name)
        self
      end

      # What the phase that is open is doing now, said in place of a count.
      def show_detail(_text) = nil

      # The one that says nothing, shared — it has no state to keep apart. Frozen because a
      # game may build from a Ractor, and a Ractor may only reach a frozen object; this one
      # holds nothing at all, so freezing it costs nothing.
      SILENT = new.freeze

      def self.silent = SILENT

      # ...and one that writes to a stream. See {Printed}. +refresh+ is how often, in seconds,
      # its line is redrawn.
      def self.to(out, refresh: Printed::REFRESH) = Printed.new(out, refresh: refresh)

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
        # HOW OFTEN THE LINE IS REDRAWN, in seconds — one rate for both of the reasons a line is
        # redrawn, because from the reader's side they are the same thing. The build had
        # something to say, or the build has said nothing for a while and the elapsed time needs
        # to move: either way what the reader sees is a line that is alive. A tenth of a second
        # matches the tenths the time is shown in, so the number climbs smoothly, and it is far
        # less work than the thing being reported on.
        REFRESH = 0.1

        # Ticks are counted, and the clock is only consulted every so many of them. A phase can
        # tick a hundred thousand times, and asking the clock that often would cost more than the
        # work being reported.
        CLOCK_EVERY = 256

        def initialize(out, clock: Process, refresh: REFRESH)
          super()
          @out = out
          @clock = clock
          @refresh = refresh
          @live = out.respond_to?(:tty?) && out.tty?
          @name = nil
          @ticks = 0
          @lock = Mutex.new  # the line is drawn by two threads; see #start_refresher
          @idle = ConditionVariable.new
        end

        # A phase begins. Whatever was running is finished and written out first, so a phase's
        # elapsed time is only ever reported once it really has elapsed.
        def step(name)
          @lock.synchronize do
            finish
            @name = name
            @started = now
            @ticks = 0
            @where = nil
            @over = false
            next unless @live

            show
            start_refresher
          end
          nil
        end

        # Where a countable phase has got to. Cheap enough to call from a loop: it remembers the
        # numbers and only writes when a line is due.
        def report_count(done, total, name = nil)
          @lock.synchronize do
            @where = name ? "#{done} of #{total}  #{name}" : "#{done} of #{total}"
            show_if_due
          end
          nil
        end

        # ...and the same for a phase with no bound. Counting is all it can honestly say, unless
        # the caller hands it something better to say in a block.
        def tick
          @ticks += 1
          return nil unless (@ticks % CLOCK_EVERY).zero?

          @lock.synchronize do
            @where = block_given? ? yield.to_s : @ticks.to_s
            show_if_due
          end
          nil
        end

        def done
          @lock.synchronize do
            finish
            @over = true
            @idle.signal
          end
          @refresher&.join # outside the lock: it is the lock the thread is waiting on
          @refresher = nil
          nil
        end

        def as_one_line(name)
          step(name)
          Folded.new(self)
        end

        def show_detail(text)
          @lock.synchronize do
            @where = text
            show_if_due if @name # with no phase open there is no line to say it on
          end
          nil
        end

        private

        def now = @clock.clock_gettime(Process::CLOCK_MONOTONIC)

        # THE LINE REDRAWS ITSELF WHILE A PHASE IS OPEN, and this is the half that cannot be done
        # by the build talking. A phase can spend fifteen seconds inside ONE call — one cost
        # estimate for one routine, one guardrail walking a big tree — and a line that is only
        # redrawn when it is told sits at 0.0s for all fifteen and reads as a hang. Nothing the
        # build says can fix that, because the build is not saying anything: it is inside the
        # call. So a small thread keeps the elapsed time climbing.
        #
        # It exists only for a terminal — a log has one line per phase and nothing to animate —
        # and it draws through the same "is a line due?" test everything else does, so a phase
        # that IS talking never draws twice for one moment. It waits on a condition variable
        # rather than sleeping, so closing a phase ends it at once instead of up to a refresh
        # later.
        def start_refresher
          @refresher ||= Thread.new do
            @lock.synchronize do
              until @over
                @idle.wait(@lock, @refresh)
                show_if_due if @name && !@over
              end
            end
          end
        end

        # Close the phase that was running: on a terminal the live line is replaced one last
        # time and left; anywhere else this is the only line that phase ever writes.
        def finish
          return unless @name

          @out.print("\r") if @live
          @out.puts(@live ? pad_over_last_line(line) : line)
          @name = nil
          @drawn = 0 # a new line starts at the left, with nothing of the old one to cover
        end

        def show_if_due
          return unless @live
          return if @shown && now - @shown < @refresh

          show
        end

        def show
          @shown = now
          @out.print("\r#{pad_over_last_line(line)}")
          @out.flush if @out.respond_to?(:flush)
        end

        # A line drawn over a longer one leaves the tail of the old one behind, and the tail reads
        # as part of the new line: a phase that took 4.5s came out as "4.5s3s", wearing the end of
        # the 4.53s that had been there. So a rewrite is padded out to cover whatever it is
        # replacing. Spaces rather than the escape code for "clear to the end of the line",
        # because this has to be right on whatever the person is running.
        def pad_over_last_line(text)
          was = @drawn.to_i
          @drawn = text.length
          text.ljust(was)
        end

        # "  the guardrails      4.5s   27 of 27  draw budget" — the phase, how long it took, and
        # where it has got to.
        #
        # THE TIME SITS NEXT TO THE NAME, in a column of its own, because the question a run of
        # these answers is "which phase is the slow one" and the two halves of that answer should
        # be side by side. Where it got to trails LAST, where it can be as long or short as it
        # likes without pushing anything else about — which it otherwise does, since it is the
        # one part whose length nobody controls.
        def line
          "  #{column(@name, NAME_WIDTH)}#{format('%5.1fs', now - @started)}   #{@where}".rstrip
        end

        # How wide the phase name's column is, gutter included. The longest name the framework
        # itself uses fits with room to spare; a longer one keeps the two spaces after it and
        # pushes the line out, which is much the lesser fault next to running into the time.
        NAME_WIDTH = 40

        def column(text, width) = text.to_s.ljust(width - 2) + "  "
      end

      # THE WORK INSIDE A PHASE MADE OF PHASES (see #as_one_line). Each of its phases, and where
      # each has got to, becomes the open phase's detail; its `done` leaves that phase open, since
      # it is the phase around it that decides when it is over.
      class Folded < Progress
        def initialize(around)
          super()
          @around = around
          @phase = nil
        end

        def step(name)
          @phase = name
          @around.show_detail(name)
        end

        def report_count(done, total, name = nil)
          @around.show_detail([@phase, "#{done} of #{total}", name].compact.join("  "))
        end

        # Ticks are counted by the line around, which only asks for the label when it draws.
        def tick(&label)
          @around.tick { [@phase, label&.call].compact.join("  ") }
        end
      end
    end
  end
end
