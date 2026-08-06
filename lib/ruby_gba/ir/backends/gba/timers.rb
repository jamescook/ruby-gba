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
        module Timers
          include Constants

          # The GBA CPU clock: ~16.78 MHz (2**24 Hz). A timer at prescaler P ticks this
          # many times a second divided by P.
          CPU_CLOCK_HZ = 16_777_216

          # [control bits, clock divisor], finest resolution first — we pick the finest
          # prescaler whose overflow period still fits the 16-bit counter.
          PRESCALERS = [[0x0000, 1], [0x0001, 64], [0x0002, 256], [0x0003, 1024]].freeze

          NUM_HW_TIMERS = 4

          # Assign each named timer its hardware timer index (0-3) up front, so a
          # timer_start/timer_stop/timer_ticks anywhere in the tree already knows which
          # registers to touch. A timer whose overflow count is read also gets a cascade
          # partner in the very next slot. Runs during the definitions pass.
          def register_timers(program)
            counted = program.walk.select { |n| n.kind == :timer_ticks }.map { |n| n[:name] }.to_set
            handlers = {}
            program.walk.each { |n| handlers[n[:timer]] = n if n.kind == :on_timer } # last wins if repeated
            program.walk.select { |n| n.kind == :timer_start }.each do |node|
              register_timer(node[:name], counted.include?(node[:name]), handlers[node[:name]])
            end
          end

          def register_timer(name, counted, handler)
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
            @timers[name] = { rate: rate, count: count, handler: handler }
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
            info = timer_info(node[:name])
            prescaler, reload = timer_config(node[:hz])
            # A timer with an on_tick handler also raises an interrupt on each overflow,
            # which the dispatcher services.
            rate_ctrl = TIMER_ENABLE | prescaler
            rate_ctrl |= TIMER_IRQ if info[:handler]
            write_reg16(timer_reg_h(info[:rate]), 0)             # off
            write_reg16(timer_reg_l(info[:rate]), reload)        # reload value
            write_reg16(timer_reg_h(info[:rate]), rate_ctrl)     # on
            return unless info[:count]

            write_reg16(timer_reg_h(info[:count]), 0)                     # off
            write_reg16(timer_reg_l(info[:count]), 0)                     # count up from zero
            write_reg16(timer_reg_h(info[:count]), TIMER_ENABLE | TIMER_CASCADE)
          end

          # Stop a timer (and its cascade partner): clear the enable bit; the counter
          # freezes at its current value.
          def emit_timer_stop(node)
            info = timer_info(node[:name])
            write_reg16(timer_reg_h(info[:rate]), 0)
            write_reg16(timer_reg_h(info[:count]), 0) if info[:count]
          end

          # Read a timer's overflow count into the accumulator — the cascade partner's
          # live counter (a 16-bit halfword load, like reading any hardware register).
          def eval_timer_ticks(node)
            info = timer_info(node[:name])
            emit(ASM.load_immediate(TMP, timer_reg_l(info[:count])))
            emit(ASM.load_halfword(ACC, TMP))
          end

          private

          def timer_info(name)
            @timers[name] ||
              raise(LoweringError, "timer #{name.inspect} was used before it was started with timer_start")
          end

          # The reload/counter and control registers for hardware timer +index+ — each
          # timer's pair sits 4 bytes after the previous one's.
          def timer_reg_l(index) = REG_TM0CNT_L + (index * 4)
          def timer_reg_h(index) = REG_TM0CNT_H + (index * 4)

          # The [prescaler bits, reload value] that make a timer overflow +hz+ times a
          # second: pick the finest prescaler whose overflow period fits 16 bits, then
          # reload = 65536 - period so it takes `period` ticks to roll over.
          def timer_config(hz)
            PRESCALERS.each do |bits, divisor|
              period = CPU_CLOCK_HZ / divisor / hz
              next if period > 65_536 || period < 1

              return [bits, 65_536 - period]
            end
            raise LoweringError, "timer rate #{hz}Hz is outside the range the hardware can clock"
          end
        end
      end
    end
  end
end
