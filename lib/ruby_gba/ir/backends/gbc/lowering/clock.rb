# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        class Lowering
          # THE CARTRIDGE'S CLOCK CHIP, read for the game. Mixed into Lowering.
          #
          # THE HARDWARE. The console has no clock of its own. The Color's games that kept the time
          # (Pokemon Gold, Silver and Crystal) carried a cartridge whose memory bank controller, an
          # MBC3, has a clock chip beside it with a watch battery that keeps it counting while the
          # console is off. The chip holds no date: it counts the seconds, minutes and hours of the
          # day, and the days, up to 511, then sets a carry bit (Console::GBCHardware). So a game
          # that shows the date keeps one of its own in its save, how far the time the player set
          # is from the chip's count, as Crystal does and as this framework does for every console
          # (Builder::Clocks); every reading of the time is 0 here, and so is set?, until the game
          # sets the clock. What a run reads of the chip itself is IR::Clock::COUNT: whether it is
          # there, whether it kept counting, its days and its seconds into the day.
          #
          # AT POWER-ON the chip is read, and taken to be there unless all five registers read 0xFF,
          # which is what the bus reads with nothing on it. A chip that stopped counting (its halt
          # bit), counted past what it holds (its carry bit), or holds a second, minute or hour no
          # clock can say — what a real chip can hold once its battery has run out and been put
          # back — has lost any time set from it. It is started again as Crystal starts one: all
          # five registers written, nought days, and the time of day it held where that was one.
          # THEN AFTER EACH WAIT FOR THE SCREEN it is read again, so every reading between two
          # waits is of one moment, as on every backend.
          #
          # BEFORE THE COUNT FILLS, whole days move from the chip into the time the game keeps. A
          # game that sets the clock keeps how far its time is from the chip's count in days
          # (IR::Clock::RECORD), so once the chip has counted 256 days its ninth bit is cleared —
          # 256 days fewer — and the record is 256 days more, in the save too. The time read is the
          # same, and the chip is far from its carry however long the game is played. Crystal does
          # the same at 140 days, keeping only the day of the week. It is done after a wait, never
          # at power-on, which comes before the record is read out of the save; and the save is
          # written first, so the console switched off part way loses the least it can: the chip's
          # writes come a few microseconds after the save's last.
          #
          # Each access to the chip follows the way Pan Docs says a real one wants it: the clock and
          # memory switched on, the counters latched with 0 and then 1, a register put in view and
          # then read, a pause of a call and a return (ten of the processor's steps, a little over
          # four microseconds at double speed) between any two accesses, the chip halted while its
          # counters are written, and the clock and memory switched off again after.
          module Clock
            VALUES = Ractor.make_shareable({ clock: :value_of_clock })

            # The routine that reads the chip at power-on, called before the game's first line, and
            # the one that reads it after each wait; one section holds both.
            AT_POWER_ON = "clock at power on"
            EACH_PASS = "clock each pass"

            # What a run reads of the chip, each a number kept as the game's are.
            READINGS = %i[present counting days seconds].freeze

            # The counters the latch copies, each kept in a number of its own's lowest byte: the
            # register that holds it, and the bits of it that are the counter's.
            COUNTERS = Ractor.make_shareable({
                                               seconds: [Console::GBCHardware::CLOCK_SECONDS, 0x3F],
                                               minutes: [Console::GBCHardware::CLOCK_MINUTES, 0x3F],
                                               hours: [Console::GBCHardware::CLOCK_HOURS, 0x1F],
                                               day_low: [Console::GBCHardware::CLOCK_DAY_LOW, 0xFF],
                                               day_high: [Console::GBCHardware::CLOCK_DAY_HIGH, 0xC1]
                                             })

            # The most each of the time of day's counters can say, for whether there is a chip.
            MOST = Ractor.make_shareable({ seconds: 60, minutes: 60, hours: 24 })

            # How many days one fold moves out of the chip: its ninth bit.
            FOLDED_DAYS = 256

            # Whether the program reads the clock: then the cartridge has the chip.
            def clock? = @clock_read

            private

            def prepare_clock
              @clock_read = @program.walk.any? { |node| node.kind == :clock }
              @clock_record = @program.walk.find { |node| node.kind == :save_store && node.var == IR::Clock::RECORD[:days] }
            end

            def keep_clock_readings
              return unless @clock_read

              READINGS.each { |part| @locals[clock_reading(part)] = @memory.reserve("the clock's #{part}", 4) }
              COUNTERS.each_key { |part| @locals[clock_counter(part)] = @memory.reserve("the clock's latched #{part}", 4) }
            end

            def clock_reading(part) = :"clock.#{part}"
            def clock_counter(part) = :"clock.latched #{part}"

            # The call that reads the chip before the game's first line, for the program's routine.
            def clock_at_power_on = @clock_read ? [PartCall.new(AT_POWER_ON)] : []

            # The read after each wait.
            def emit_clock_each_pass
              call_routine(EACH_PASS) if @clock_read
            end

            # The chip's count, as the run last read it; and nought for the date and the time, and
            # for set?, which a chip that keeps no date has none of to give.
            def value_of_clock(node)
              return load_variable(clock_reading(node.reading)) if READINGS.include?(node.reading)

              load_constant(0)
            end

            def clock_sections
              return [] unless @clock_read

              [routine_section(AT_POWER_ON, [], routine: "the clock") { emit_clock_routines }]
            end

            def emit_clock_routines
              h = Console::GBCHardware
              read = fresh("read")
              pause = fresh("pause")
              stopped = fresh("stopped")
              count = fresh("count")

              @asm.call(read)
              @asm.load(:a, :b) # every register read 0xFF: no chip, and every reading stays nought
              @asm.inc(:a)
              @asm.ret(:z)
              emit_clock_reading_true(:present)
              MOST.each do |part, most|
                @asm.load(:a, [place_of(clock_counter(part))])
                @asm.cp_a(most)
                @asm.jump(:nc, stopped)
              end
              @asm.load(:a, [place_of(clock_counter(:day_high))])
              @asm.and_a(h::CLOCK_HALT | h::CLOCK_CARRY)
              @asm.jump(:nz, stopped)
              emit_clock_reading_true(:counting)
              @asm.jump(count)
              @asm.label(stopped)
              emit_clock_restart(pause)
              @asm.jump(count)

              @asm.label(EACH_PASS)
              @asm.load(:a, [place_of(clock_reading(:present))])
              @asm.and_a(:a)
              @asm.ret(:z)
              @asm.call(read)
              emit_clock_fold(pause) if @clock_record
              @asm.label(count)
              emit_clock_count
              @asm.ret

              @asm.label(read)
              emit_clock_read(pause)
              @asm.ret

              @asm.label(pause) # the routine's own last return
            end

            # A reading of the chip's that is a yes, 1.
            def emit_clock_reading_true(part)
              @asm.load(:a, 1)
              @asm.load([place_of(clock_reading(part))], :a)
            end

            # The clock switched on, its counters latched, and each read through the bits that are
            # the counter's. B is left holding every register as read ANDed together, so it is 0xFF
            # only when all five read 0xFF.
            def emit_clock_read(pause)
              h = Console::GBCHardware
              emit_clock_on(pause)
              @asm.xor_a(:a)
              @asm.load([h::MBC_CLOCK_LATCH], :a)
              @asm.call(pause)
              @asm.inc(:a)
              @asm.load([h::MBC_CLOCK_LATCH], :a)
              @asm.call(pause)
              @asm.load(:b, 0xFF)
              COUNTERS.each do |part, (register, bits)|
                emit_clock_select(register, pause)
                @asm.load(:a, [h::SRAM])
                @asm.load(:c, :a)
                @asm.and_a(:b)
                @asm.load(:b, :a)
                @asm.load(:a, :c)
                @asm.and_a(bits)
                @asm.load([place_of(clock_counter(part))], :a)
                @asm.call(pause)
              end
              emit_clock_off
            end

            # A STOPPED CHIP STARTED AGAIN: halted, every register written — a second, minute or hour
            # no clock can say as nought, the others as they were, and nought days — and let go.
            def emit_clock_restart(pause)
              h = Console::GBCHardware
              MOST.each do |part, most|
                fine = fresh("fine")
                @asm.load(:a, [place_of(clock_counter(part))])
                @asm.cp_a(most)
                @asm.jump_relative(:c, fine)
                @asm.xor_a(:a)
                @asm.load([place_of(clock_counter(part))], :a)
                @asm.label(fine)
              end
              @asm.xor_a(:a)
              @asm.load([place_of(clock_counter(:day_low))], :a)
              @asm.load([place_of(clock_counter(:day_high))], :a)
              emit_clock_on(pause)
              emit_clock_write(h::CLOCK_DAY_HIGH, h::CLOCK_HALT, pause)
              MOST.each_key do |part|
                emit_clock_select(COUNTERS.fetch(part).first, pause)
                @asm.load(:a, [place_of(clock_counter(part))])
                @asm.load([h::SRAM], :a)
                @asm.call(pause)
              end
              emit_clock_write(h::CLOCK_DAY_LOW, 0, pause)
              emit_clock_write(h::CLOCK_DAY_HIGH, 0, pause)
              emit_clock_off
            end

            # 256 DAYS OUT OF THE CHIP AND INTO THE RECORD, once the chip has counted that many: the
            # record and its place in the save 256 days more, then the chip halted with its ninth
            # bit still on, the bit cleared, and the chip let go — the low eight bits stay as they
            # are.
            def emit_clock_fold(pause)
              h = Console::GBCHardware
              done = fresh("folded")
              @asm.load(:a, [place_of(clock_counter(:day_high))])
              @asm.bit(0, :a)
              @asm.jump(:z, done)
              add_in_place(place_of(IR::Clock::RECORD[:days]), FOLDED_DAYS)
              statement(@clock_record)
              emit_clock_on(pause)
              emit_clock_write(h::CLOCK_DAY_HIGH, h::CLOCK_HALT | h::CLOCK_DAY_NINTH_BIT, pause)
              emit_clock_write(h::CLOCK_DAY_HIGH, h::CLOCK_HALT, pause)
              emit_clock_write(h::CLOCK_DAY_HIGH, 0, pause)
              emit_clock_off
              @asm.xor_a(:a)
              @asm.load([place_of(clock_counter(:day_high))], :a)
              @asm.label(done)
            end

            # The days, its low eight bits and its ninth; and the seconds into the day.
            def emit_clock_count
              h = Console::GBCHardware
              days = place_of(clock_reading(:days))
              @asm.load(:a, [place_of(clock_counter(:day_low))])
              @asm.load([days], :a)
              @asm.load(:a, [place_of(clock_counter(:day_high))])
              @asm.and_a(h::CLOCK_DAY_NINTH_BIT)
              @asm.load([days + 1], :a)
              counter = ->(part) { Build.var_ref(clock_counter(part)) }
              value(Build.binop(:+, Build.binop(:+, Build.binop(:*, counter.call(:hours), Build.int(3600)),
                                                Build.binop(:*, counter.call(:minutes), Build.int(60))),
                                counter.call(:seconds)))
              store(clock_reading(:seconds))
            end

            # The clock and the cartridge's memory switched on for the processor.
            def emit_clock_on(pause)
              @asm.load(:a, Console::GBCHardware::MBC_RAM_ON)
              @asm.load([Console::GBCHardware::MBC_RAM_ENABLE], :a)
              @asm.call(pause)
            end

            # ...and off, which a console switched off with them on can write nonsense into.
            def emit_clock_off
              @asm.xor_a(:a)
              @asm.load([Console::GBCHardware::MBC_RAM_ENABLE], :a)
            end

            def emit_clock_select(register, pause)
              @asm.load(:a, register)
              @asm.load([Console::GBCHardware::MBC_RAM_BANK], :a)
              @asm.call(pause)
            end

            def emit_clock_write(register, value, pause)
              emit_clock_select(register, pause)
              @asm.load(:a, value)
              @asm.load([Console::GBCHardware::SRAM], :a)
              @asm.call(pause)
            end
          end
        end
      end
    end
  end
end
