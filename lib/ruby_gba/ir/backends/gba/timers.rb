# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Hardware timers. The GBA has four; each is a 16-bit counter that ticks at the
        # CPU clock divided by a prescaler (1, 64, 256, or 1024), and when it rolls past
        # 65535 it "overflows" and reloads a start value. Picking the reload value sets
        # how often it overflows — that's the rate the DSL asks for.
        #
        # A timer's raw counter races along too fast to read meaningfully, so to answer
        # "how many times has it overflowed?" we chain a second timer in CASCADE mode: a
        # cascade timer ticks once each time the timer below it overflows. So a logical
        # timer whose overflow count is read reserves a PAIR — the rate timer, plus the
        # cascade timer immediately after it that counts its overflows — and reading the
        # count is just reading the cascade timer's counter register.
        #
        # Its only state (@timers, @next_hw_timer) is its own — nothing else reaches
        # into it by name. The one hardware timer Mixer claims for its own sample clock,
        # ahead of anything the program named, goes through #reserve! (see
        # Mixer#prepare_mixer) rather than touching @next_hw_timer directly.
        class Timers
          include Constants

          # The GBA CPU clock: ~16.78 MHz (2**24 Hz). A timer at prescaler P ticks this
          # many times a second divided by P.
          CPU_CLOCK_HZ = 16_777_216

          # [control bits, clock divisor], finest resolution first — we pick the finest
          # prescaler whose overflow period still fits the 16-bit counter.
          PRESCALERS = [[0x0000, 1], [0x0001, 64], [0x0002, 256], [0x0003, 1024]].freeze

          # The prescaler bits for counting every CPU cycle — what a sample clock always uses,
          # since #frame_periods keeps only the periods the 16-bit counter reaches unaided.
          FINEST_PRESCALER = PRESCALERS.first.first

          NUM_HW_TIMERS = 4

          # THE CYCLES IN ONE DISPLAYED FRAME: 228 scanlines of 308 dots, four cycles a dot.
          #
          # The console does NOT run at 60 frames a second. It runs at CPU_CLOCK_HZ divided
          # by this, which is 59.7275, and the difference is small enough to look like a
          # rounding detail and much too big to treat as one — see #sample_clock.
          FRAME_CYCLES = 228 * 308 * 4

          # How many samples the sound DMA moves each time the sound hardware asks for more:
          # four 32-bit words, so sixteen 8-bit samples. It only ever moves a whole lot, which
          # is half of why a sample clock cannot be chosen freely — see #sample_clock.
          DMA_SAMPLES_A_LOT = 16

          # A SAMPLE CLOCK A PER-FRAME MIXER CAN ACTUALLY KEEP UP WITH.
          #
          # The mixer fills a buffer once a frame and points the sound DMA at it; the DMA then
          # feeds the hardware, which eats a sample every time this timer overflows. Handing
          # over cleanly at every frame boundary puts TWO conditions on the clock, and missing
          # either one puts an impulse in the sound at the frame rate — not a drift you notice
          # after a minute, a rattle under the whole soundtrack, like a rolled tongue. Both are
          # measured (test_mixer_sample_clock.rb), not reasoned about.
          #
          # ONE: as many samples must be written each frame as are read. The reads are fixed by
          # the clock — the timer overflows every +period+ cycles, so the hardware reads
          # FRAME_CYCLES / period samples a frame — and that is a whole number only when a
          # frame divides by +period+ exactly. Which means the RATE is a consequence of picking
          # a clock, not something to choose first and then round. Picking it first is how this
          # went wrong: a rate divided by a round 60 gave one sample a frame fewer than a
          # console running at 59.7275 frames a second actually eats.
          #
          # TWO: those samples must be a whole number of the lots the DMA moves. The DMA only
          # ever transfers DMA_SAMPLES_A_LOT at a time, so its read position lands on a lot
          # boundary and nowhere else. Hand it a buffer that is not a whole number of lots and
          # every frame it either stops short of the end or runs past it — past it into
          # whatever is allocated next, which it plays.
          #
          # Together: +period+ must divide FRAME_CYCLES / DMA_SAMPLES_A_LOT. Retail games land
          # on the same answer from the other end — the Game Boy Advance sound driver picks a
          # samples-per-frame out of a fixed table and derives its rate from that — and the
          # entries of that table which are whole lots are all in this set.
          #
          # So: take the rate the program's recordings suggest, and give back the nearest clock
          # that satisfies both. Nearest BY RATIO, because that is how a rate is heard. The
          # author never names this rate and never sees it: their recordings are resampled to
          # it as they play, at the pitch and for the duration they were recorded at, so
          # landing off it costs a little bandwidth or a little mixing and nothing else.
          # `rom.profile` says which rate a game got.
          SampleClock = Data.define(:period, :rate, :samples_a_frame)

          def self.sample_clock(hz)
            period = sample_clock_periods.min_by do |candidate|
              rate = CPU_CLOCK_HZ.fdiv(candidate)
              rate > hz ? rate / hz : hz / rate
            end
            SampleClock.new(period: period, rate: CPU_CLOCK_HZ / period,
                            samples_a_frame: FRAME_CYCLES / period)
          end

          # The periods that meet both conditions, and that the 16-bit counter can reach with
          # no prescaler (past 65536 cycles it cannot, which puts a floor of 256Hz on all this).
          def self.sample_clock_periods
            @sample_clock_periods ||= begin
              whole = FRAME_CYCLES / DMA_SAMPLES_A_LOT
              (1..Integer.sqrt(whole)).flat_map { |d| (whole % d).zero? ? [d, whole / d] : [] }
                                      .select { |d| d <= 65_536 }.sort.freeze
            end
          end

          def initialize(emitter:)
            @emitter = emitter
            @timers = {}
            @next_hw_timer = 0
          end

          # Claim the first +count+ hardware timer indices before any named timer is
          # allocated — Mixer's sample clock reserves timer 0 this way, ahead of
          # anything the program named with timer_start.
          def reserve!(count)
            @next_hw_timer = [@next_hw_timer, count].max
          end

          # Assign each named timer its hardware timer index (0-3) up front, so a
          # timer_start/timer_stop/timer_ticks anywhere in the tree already knows which
          # registers to touch. A timer whose overflow count is read also gets a cascade
          # partner in the very next slot. Runs during the definitions pass.
          def register_timers(program)
            counted = program.walk.select { |n| n.kind == :timer_ticks }.map { |n| n.name }.to_set
            handlers = {}
            program.walk.each { |n| handlers[n.timer] = n if n.kind == :on_timer } # last wins if repeated
            program.walk.select { |n| n.kind == :timer_start }.each do |node|
              register_timer(node.name, counted.include?(node.name), handlers[node.name], node.hz)
            end
          end

          # +hz+ is the rate the program ASKED for, kept because a profile holds the ticks that
          # really arrived against it. A timer restarted at a different rate keeps the first,
          # the same way the registry keeps the first of everything else about it.
          def register_timer(name, counted, handler, hz = nil)
            return if @timers.key?(name)

            rate = @next_hw_timer
            count = counted ? @next_hw_timer + 1 : nil
            @next_hw_timer += counted ? 2 : 1
            if @next_hw_timer > NUM_HW_TIMERS
              raise LoweringError,
                    "This program uses more hardware timers than the GBA has (#{NUM_HW_TIMERS}). Reading a " \
                    "timer's ticks costs two timers: one to run it, and one to count its overflows. To fix " \
                    "this, use fewer timers."
            end
            @timers[name] = { rate: rate, count: count, handler: handler, hz: hz }
          end

          # The timers with an on_tick handler, each [name, info], in hardware-timer order —
          # each one raises an interrupt the dispatcher services.
          def irq_timers
            @timers.select { |_, info| info[:handler] }.sort_by { |_, info| info[:rate] }
          end

          # Start (or restart) a timer at its requested rate. We disable it first so the
          # enable is a clean off->on transition (which reloads the counter), giving the
          # restart-from-zero the interpreter also models. If its overflow count is read,
          # its cascade partner is (re)started from zero alongside it.
          def emit_timer_start(node)
            info = timer_info(node.name)
            prescaler, reload = timer_config(node.hz)
            # A timer with an on_tick handler also raises an interrupt on each overflow,
            # which the dispatcher services.
            rate_ctrl = TIMER_ENABLE | prescaler
            rate_ctrl |= TIMER_IRQ if info[:handler]
            @emitter.write_reg16(timer_reg_h(info[:rate]), 0)             # off
            @emitter.write_reg16(timer_reg_l(info[:rate]), reload)        # reload value
            @emitter.write_reg16(timer_reg_h(info[:rate]), rate_ctrl)     # on
            return unless info[:count]

            @emitter.write_reg16(timer_reg_h(info[:count]), 0)                     # off
            @emitter.write_reg16(timer_reg_l(info[:count]), 0)                     # count up from zero
            @emitter.write_reg16(timer_reg_h(info[:count]), TIMER_ENABLE | TIMER_CASCADE)
          end

          # Stop a timer (and its cascade partner): clear the enable bit; the counter
          # freezes at its current value.
          def emit_timer_stop(node)
            info = timer_info(node.name)
            @emitter.write_reg16(timer_reg_h(info[:rate]), 0)
            @emitter.write_reg16(timer_reg_h(info[:count]), 0) if info[:count]
          end

          # Read a timer's overflow count into the accumulator — the cascade partner's
          # live counter (a 16-bit halfword load, like reading any hardware register).
          def eval_timer_ticks(node)
            info = timer_info(node.name)
            @emitter.emit(ASM.load_immediate(TMP, timer_reg_l(info[:count])))
            @emitter.emit(ASM.load_halfword(ACC, TMP))
          end

          # The reload/counter and control registers for hardware timer +index+ — each
          # timer's pair sits 4 bytes after the previous one's. Public because Mixer's
          # own clock timer (which never goes through register_timer) still needs to
          # address hardware timer 0 by hand.
          def timer_reg_l(index) = REG_TM0CNT_L + (index * 4)
          def timer_reg_h(index) = REG_TM0CNT_H + (index * 4)

          # The [prescaler bits, reload value] that make a timer overflow +hz+ times a
          # second: pick the finest prescaler whose overflow period fits 16 bits, then
          # reload = 65536 - period so it takes `period` ticks to roll over. Public for
          # the same reason timer_reg_l/timer_reg_h are — Mixer's own clock timer needs
          # it too, and never goes through register_timer.
          def timer_config(hz)
            PRESCALERS.each do |bits, divisor|
              period = CPU_CLOCK_HZ / divisor / hz
              next if period > 65_536 || period < 1

              return [bits, 65_536 - period]
            end
            raise LoweringError, "timer rate #{hz}Hz is outside the range the hardware can clock"
          end

          private

          def timer_info(name)
            @timers[name] ||
              raise(LoweringError, "timer #{name.inspect} was used before it was started with timer_start")
          end
        end
      end
    end
  end
end
