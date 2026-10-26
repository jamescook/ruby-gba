# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # THE CARTRIDGE'S CLOCK CHIP, read and set for the game. Mixed into Lowering.
          #
          # THE HARDWARE. The console has no clock of its own. The Color's games that kept the time
          # (Pokemon Gold, Silver and Crystal) carried a cartridge whose memory bank controller, an
          # MBC3, has a clock chip beside it with a watch battery that keeps it counting while the
          # console is off. The chip holds no date: it counts the seconds, minutes and hours of the
          # day, and the days, up to 511, then sets a carry bit; and it has a halt bit that stops it
          # counting (Console::GBCHardware). So a game that shows the date keeps one of its own in
          # its save, how far the time the player set is from the chip's count, as Crystal does and
          # as `clock.set_to` does on every console (IR::Clock::OFFSET_DAYS). The chip's own time is
          # taken as its days on from 1 January 2000 (IR::Clock.undated), and nothing reads as set,
          # and every reading is 0, until the game has set a time on a chip that is counting.
          #
          # AT POWER-ON the chip is read, and taken to be there unless all five registers read 0xFF,
          # which is what the bus reads with nothing on it. A chip that is halted has not been set.
          # One that counted past what it holds (its carry bit), or holds a second, minute or hour
          # no clock can say — what a real chip can hold once its battery has run out and been put
          # back — has lost any time set from it: it is started again as Crystal starts one, all
          # five registers written, nought days and the time of day it held where that was one,
          # and left halted, so it too reads as not set until the game sets it. THEN AFTER EACH WAIT
          # FOR THE SCREEN it is read again, so every reading between two waits is of one moment.
          #
          # SETTING IT keeps how far the time set is from the chip's own, and lets a halted chip go,
          # which is what it says it was set by. The readings are worked out from the chip's count
          # and that offset after each wait, after the saved offset is read back at power-on, and
          # after the game sets a new one — never while a number is being worked out.
          #
          # BEFORE THE COUNT FILLS, whole days move from the chip into the offset. Once the chip has
          # counted 256 days its ninth bit is cleared — 256 days fewer — and the offset is 256 days
          # more, in the save too. The time read is the same, and the chip is far from its carry
          # however long the game is played. Crystal does the same at 140 days, keeping only the day
          # of the week. It is done after a wait, never at power-on, which comes before the offset
          # is read out of the save; and the save is written first, so the console switched off part
          # way loses the least it can: the chip's writes come a few microseconds after the save's.
          #
          # Each access to the chip follows the way Pan Docs says a real one wants it: the clock and
          # memory switched on, the counters latched with 0 and then 1, a register put in view and
          # then read, a pause of a call and a return (ten of the processor's steps, a little over
          # four microseconds at double speed) between any two accesses, the chip halted while its
          # counters are written, and the clock and memory switched off again after.
          module Clock
            STATEMENTS = Ractor.make_shareable({ set_clock: :emit_set_clock })
            VALUES = Ractor.make_shareable({ clock: :value_of_clock })

            # The routines, all in one section: the read at power-on, called before the game's first
            # line, the read after each wait, the working-out of the readings, and the start of a
            # halted chip.
            AT_POWER_ON = "clock at power on"
            EACH_PASS = "clock each pass"
            WORK_OUT = "clock readings"
            START = "clock start"

            # What a run keeps of the chip, each a number kept as the game's are: whether it is
            # there, whether it is counting, its own days and seconds into the day, and what the
            # game reads — whether it was set, and the time.
            KEPT = %i[present running own_days own_seconds set].freeze

            # ...and what working the readings out and setting the clock work in, with the chip's own
            # second the readings were last worked out at.
            WORK = %i[days into_day year month day hour minute second worked_at].freeze
            CALENDAR = %i[cycles of_cycle years into months].freeze

            # The counters the latch copies, each kept in a number of its own's lowest byte: the
            # register that holds it, and the bits of it that are the counter's.
            COUNTERS = Ractor.make_shareable({
                                               seconds: [Console::GBCHardware::CLOCK_SECONDS, 0x3F],
                                               minutes: [Console::GBCHardware::CLOCK_MINUTES, 0x3F],
                                               hours: [Console::GBCHardware::CLOCK_HOURS, 0x1F],
                                               day_low: [Console::GBCHardware::CLOCK_DAY_LOW, 0xFF],
                                               day_high: [Console::GBCHardware::CLOCK_DAY_HIGH, 0xC1]
                                             })

            # The most each of the time of day's counters can say.
            MOST = Ractor.make_shareable({ seconds: 60, minutes: 60, hours: 24 })

            # How many days one fold moves out of the chip: its ninth bit.
            FOLDED_DAYS = 256

            # Whether the program reads or sets the clock: then the cartridge has the chip.
            def clock? = @clock_used

            private

            def prepare_clock
              @clock_sets = IR::Clock.sets_clock?(@program)
              @clock_used = @clock_sets || @program.walk.any? { |node| node.kind == :clock }
              @clock_saves_offset = @program.walk.find { |node| node.kind == :save_store && node.var == IR::Clock::OFFSET_DAYS }
            end

            def keep_clock_readings
              return unless @clock_used

              (KEPT + IR::Clock::TIME).each { |part| @locals[clock_kept(part)] = @memory.reserve("the clock's #{part}", 4) }
              COUNTERS.each_key { |part| @locals[clock_counter(part)] = @memory.reserve("the clock's latched #{part}", 4) }
              (WORK + CALENDAR).each { |part| @locals[clock_work(part)] = @memory.reserve("the clock's working #{part}", 4) }
              @starts << [@locals[clock_work(:worked_at)], -1] # no second of the chip's, so the first pass works them out
            end

            def clock_kept(part) = :"clock.#{part}"
            def clock_counter(part) = :"clock.latched #{part}"
            def clock_work(part) = :"clock.working #{part}"

            # The call that reads the chip before the game's first line, for the program's routine.
            def clock_at_power_on = @clock_used ? [PartCall.new(AT_POWER_ON)] : []

            # The read after each wait.
            def emit_clock_each_pass
              call_routine(EACH_PASS) if @clock_used
            end

            # The readings worked out again once the saved offset is read back.
            def emit_clock_readings_from_save
              call_routine(WORK_OUT) if @clock_sets
            end

            # What the run last worked out: whether there is a chip, whether the game set a time on
            # it, and the time. A game that never sets the clock reads nought for both of the last.
            def value_of_clock(node) = load_variable(clock_kept(node.reading))

            # SETTING THE CLOCK, as Reference#exec_set_clock does: nothing at all with no chip; each
            # part worked out once, in order; how far the time set is from the chip's own, in days
            # and the seconds left over; a halted chip let go; and the readings worked out from it.
            def emit_set_clock(node)
              no_chip = fresh("no_clock")
              jump_unless(Build.var_ref(clock_kept(:present)), no_chip)
              IR::Clock::SET_PARTS.each { |part| statement(Build.set(clock_work(part), node.public_send(part))) }
              offset_statements.each { |statement| statement(statement) }
              call_routine(START)
              call_routine(WORK_OUT)
              @asm.label(no_chip)
            end

            def offset_statements
              days = IR::Clock::OFFSET_DAYS
              seconds = IR::Clock::OFFSET_SECONDS
              work = ->(part) { Build.var_ref(clock_work(part)) }
              kept = ->(part) { Build.var_ref(clock_kept(part)) }
              borrow = Build.binop(:<, Build.var_ref(seconds), Build.int(0))
              [
                Build.set(days, Build.binop(:-, ClockCalendar.day_number(work[:year], work[:month], work[:day]),
                                            Build.binop(:+, kept[:own_days], Build.int(ClockCalendar::DAY_NUMBER_OF_2000)))),
                Build.set(seconds, Build.binop(:-, ClockCalendar.seconds_into_day(work[:hour], work[:minute], work[:second]),
                                               kept[:own_seconds])),
                Build.set(days, Build.binop(:-, Build.var_ref(days), borrow)),
                Build.set(seconds, Build.binop(:+, Build.var_ref(seconds),
                                               Build.binop(:*, borrow, Build.int(IR::Clock::SECONDS_A_DAY))))
              ]
            end

            def clock_sections
              return [] unless @clock_used

              [routine_section(AT_POWER_ON, [], routine: "the clock") { emit_clock_routines }]
            end

            def emit_clock_routines
              read = fresh("read")
              pause = fresh("pause")
              emit_clock_power_on_body(read, pause)
              @asm.label(EACH_PASS)
              @asm.load(:a, [place_of(clock_kept(:present))])
              @asm.and_a(:a)
              @asm.ret(:z)
              @asm.call(read)
              emit_clock_fold(pause) if @clock_saves_offset
              emit_clock_own_time
              emit_clock_work_out_when_moved if @clock_sets
              @asm.ret
              emit_clock_work_out
              emit_clock_start(pause)
              @asm.label(read)
              emit_clock_read(pause)
              @asm.ret
              @asm.label(pause) # the section's own last return
            end

            # Is there a chip, and is it counting: started again halted if it lost its time.
            def emit_clock_power_on_body(read, pause)
              lost = fresh("lost")
              counted = fresh("counted")
              @asm.call(read)
              @asm.load(:a, :b) # every register read 0xFF: no chip, and every reading stays nought
              @asm.inc(:a)
              @asm.ret(:z)
              emit_clock_kept_true(:present)
              MOST.each do |part, most|
                @asm.load(:a, [place_of(clock_counter(part))])
                @asm.cp_a(most)
                @asm.jump(:nc, lost)
              end
              @asm.load(:a, [place_of(clock_counter(:day_high))])
              @asm.bit(7, :a) # the carry
              @asm.jump(:nz, lost)
              @asm.bit(6, :a) # the halt
              @asm.jump(:nz, counted)
              emit_clock_kept_true(:running)
              @asm.jump(counted)
              @asm.label(lost)
              emit_clock_restart(pause)
              @asm.label(counted)
              emit_clock_own_time
              @asm.ret
            end

            # A yes, 1, in what the run keeps.
            def emit_clock_kept_true(part)
              @asm.load(:a, 1)
              @asm.load([place_of(clock_kept(part))], :a)
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

            # A CHIP THAT LOST ITS TIME STARTED AGAIN: halted first, which clears its carry and its
            # ninth bit, then every register written — a second, minute or hour no clock can say as
            # nought, the others as they were, and nought days — and left halted.
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
              @asm.load(:a, h::CLOCK_HALT)
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
              emit_clock_off
            end

            # A HALTED CHIP LET GO, once the game sets it: its day count's ninth bit written back
            # with the halt bit clear, and the chip counting from then on.
            def emit_clock_start(pause)
              h = Console::GBCHardware
              @asm.label(START)
              @asm.load(:a, [place_of(clock_kept(:running))])
              @asm.and_a(:a)
              @asm.ret(:nz)
              emit_clock_on(pause)
              emit_clock_select(h::CLOCK_DAY_HIGH, pause)
              @asm.load(:a, [place_of(clock_counter(:day_high))])
              @asm.and_a(h::CLOCK_DAY_NINTH_BIT)
              @asm.load([place_of(clock_counter(:day_high))], :a)
              @asm.load([h::SRAM], :a)
              @asm.call(pause)
              emit_clock_off
              emit_clock_kept_true(:running)
              @asm.ret
            end

            # 256 DAYS OUT OF THE CHIP AND INTO THE OFFSET, once the chip has counted that many: the
            # offset and its place in the save 256 days more, then the chip halted with its ninth
            # bit still on, the bit cleared, and the chip let go — the low eight bits stay as they
            # are. A halted chip is left as it is.
            def emit_clock_fold(pause)
              h = Console::GBCHardware
              done = fresh("folded")
              @asm.load(:a, [place_of(clock_counter(:day_high))])
              @asm.cp_a(h::CLOCK_DAY_NINTH_BIT)
              @asm.jump(:nz, done)
              add_in_place(place_of(IR::Clock::OFFSET_DAYS), FOLDED_DAYS)
              statement(@clock_saves_offset)
              emit_clock_on(pause)
              emit_clock_write(h::CLOCK_DAY_HIGH, h::CLOCK_HALT | h::CLOCK_DAY_NINTH_BIT, pause)
              emit_clock_write(h::CLOCK_DAY_HIGH, h::CLOCK_HALT, pause)
              emit_clock_write(h::CLOCK_DAY_HIGH, 0, pause)
              emit_clock_off
              @asm.xor_a(:a)
              @asm.load([place_of(clock_counter(:day_high))], :a)
              @asm.label(done)
            end

            # The chip's own days, its low eight bits and its ninth, and its seconds into the day.
            def emit_clock_own_time
              h = Console::GBCHardware
              days = place_of(clock_kept(:own_days))
              @asm.load(:a, [place_of(clock_counter(:day_low))])
              @asm.load([days], :a)
              @asm.load(:a, [place_of(clock_counter(:day_high))])
              @asm.and_a(h::CLOCK_DAY_NINTH_BIT)
              @asm.load([days + 1], :a)
              counter = ->(part) { Build.var_ref(clock_counter(part)) }
              value(ClockCalendar.seconds_into_day(counter[:hours], counter[:minutes], counter[:seconds]))
              store(clock_kept(:own_seconds))
            end

            # The readings move on only when the chip's second does, so after a wait they are worked
            # out again only then: ten divisions of 32-bit numbers, which the Color makes a step at a
            # time, are not spent on the fifty-nine passes a second that would come to the same.
            def emit_clock_work_out_when_moved
              same = fresh("same_second")
              jump_unless(Build.binop(:!=, Build.var_ref(clock_kept(:own_seconds)), Build.var_ref(clock_work(:worked_at))), same)
              @asm.call(WORK_OUT)
              @asm.label(same)
            end

            # THE READINGS WORKED OUT: set when the chip is counting and the game set a time on it
            # (IR::Clock.undated_set?), and then the chip's own day and time with the offset added,
            # a day carried when the seconds pass midnight, back to a date and a time.
            def emit_clock_work_out
              return unless @clock_sets

              @asm.label(WORK_OUT)
              statement(Build.set(clock_work(:worked_at), Build.var_ref(clock_kept(:own_seconds))))
              kept = ->(part) { Build.var_ref(clock_kept(part)) }
              offset = ->(name) { Build.binop(:!=, Build.var_ref(name), Build.int(0)) }
              statement(Build.set(clock_kept(:set),
                                  Build.binop(:and, kept[:running],
                                              Build.binop(:or, offset[IR::Clock::OFFSET_DAYS], offset[IR::Clock::OFFSET_SECONDS]))))
              done = fresh("not_set")
              jump_unless(kept[:set], done)
              work_out_statements.each { |statement| statement(statement) }
              @asm.label(done)
              @asm.ret
            end

            def work_out_statements
              days = clock_work(:days)
              into_day = clock_work(:into_day)
              copy = IR::Clock::TIME.to_h { |reading| [reading, clock_kept(reading)] }
              into = Build.var_ref(into_day)
              [
                Build.set(days, Build.binop(:+, Build.binop(:+, Build.var_ref(clock_kept(:own_days)),
                                                            Build.int(ClockCalendar::DAY_NUMBER_OF_2000)),
                                            Build.var_ref(IR::Clock::OFFSET_DAYS))),
                Build.set(into_day, Build.binop(:+, Build.var_ref(clock_kept(:own_seconds)), Build.var_ref(IR::Clock::OFFSET_SECONDS))),
                Build.set(days, Build.binop(:+, Build.var_ref(days), Build.binop(:/, into, Build.int(IR::Clock::SECONDS_A_DAY)))),
                Build.set(into_day, Build.binop(:%, Build.var_ref(into_day), Build.int(IR::Clock::SECONDS_A_DAY))),
                *ClockCalendar.date_of_day_number(days, into: copy, scratch: CALENDAR.to_h { |part| [part, clock_work(part)] }),
                Build.set(copy[:hour], Build.binop(:/, Build.var_ref(into_day), Build.int(3600))),
                Build.set(copy[:minute], Build.binop(:%, Build.binop(:/, Build.var_ref(into_day), Build.int(60)), Build.int(60))),
                Build.set(copy[:second], Build.binop(:%, Build.var_ref(into_day), Build.int(60)))
              ]
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
