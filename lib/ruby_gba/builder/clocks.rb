# frozen_string_literal: true

module RubyGBA
  class Builder
    # The clock verb: `clock` — the date and time, as the clock a cartridge carries keeps them.
    # A concern of {Builder}, mixed in so `clock` stays a flat DSL verb.
    #
    # A GAME THAT SETS THE CLOCK (DSL::Clock#set!) keeps the time it set as the console's own games
    # kept it: its save holds how far that time is from the chip's count, in days and in seconds,
    # and whether it set one (RECORD); every reading is the chip's count moved on by that much. So
    # such a game's readings are not the chip's: once the whole game is declared, each one it
    # wrote reads a number of its own (SHOWN), which a routine of the framework's works out once a
    # pass — at power-on and after every wait for the screen, where the chip's own readings move
    # on — so every reading in one pass is still of one moment. Until the game sets it, the chip's
    # own readings are what it reads, as in a game that never does.
    module Clocks
      RECORD = IR::Clock::RECORD
      SHOWN = IR::Clock::SHOWN
      WORK = %i[days seconds year month era doe yoe doy mp].to_h { |part| [part, :"__clock_work_#{part}"] }.freeze

      # The routine that works out SHOWN each pass, and the one that, at power-on, forgets a time
      # set when the chip stopped counting since — its battery ran out — before working it out.
      READINGS, AT_POWER_ON = IR::Clock::ROUTINES

      DAY = IR::Clock::DAY

      # The cartridge's clock, as a {DSL::Clock} whose readings are numbers like any variable's:
      # `clock.hour`, `.minute`, `.second`, `.year`, `.month`, `.day` and `.weekday`, and the
      # tests `clock.present?` and `clock.set?`; `clock.set!` sets it.
      #
      #   now = clock
      #   draw_number now.minute, 60, 60, :white, digits: 2
      #
      # @return [DSL::Clock]
      def clock = DSL::Clock.new(self)

      # DSL::Clock#set!: the record made from +parts+ (value nodes by name): the days and seconds
      # of the time set, less the chip's count now. The month is counted from 0 into whole years
      # first, so a month past 12 is one of the next year, and the seconds into whole days.
      def set_clock(parts)
        keep_clock_record
        b = Build
        work = ->(part) { b.var_ref(WORK.fetch(part)) }
        record(b.set(WORK[:month], b.binop(:-, parts.fetch(:month), b.int(1))))
        record(b.set(WORK[:year], b.binop(:+, parts.fetch(:year), floor_div(work.call(:month), 12))))
        record(b.set(WORK[:month], b.binop(:+, b.binop(:%, work.call(:month), b.int(12)), b.int(1))))
        record(b.set(WORK[:seconds], b.binop(:+, b.binop(:+, b.binop(:*, parts.fetch(:hour), b.int(3600)),
                                                         b.binop(:*, parts.fetch(:minute), b.int(60))), parts.fetch(:second))))
        days = IR::Clock.days_from_civil(-> { work.call(:year) }, -> { work.call(:month) }, -> { b.int(1) })
        record(b.set(WORK[:days], b.binop(:+, b.binop(:+, days, b.binop(:-, parts.fetch(:day), b.int(1))),
                                          floor_div(work.call(:seconds), DAY))))
        record(b.set(RECORD[:days], b.binop(:-, work.call(:days), b.clock(:days))))
        record(b.set(RECORD[:seconds], b.binop(:-, b.binop(:%, work.call(:seconds), b.int(DAY)), b.clock(:seconds))))
        record_conditional(b.binop(:<, b.var_ref(RECORD[:seconds]), b.int(0))) do
          record(b.set(RECORD[:seconds], b.binop(:+, b.var_ref(RECORD[:seconds]), b.int(DAY))))
          record(b.set(RECORD[:days], b.binop(:-, b.var_ref(RECORD[:days]), b.int(1))))
        end
        record(b.set(RECORD[:set], b.int(1)))
        RECORD.each_value { |name| mirror_save(name) } # the record into save memory, as a save_var's verbs do
      end

      private

      # +value+ divided by +by+, rounded down rather than towards nought: the % the IR keeps has
      # the sign of the divisor, so taking it off first leaves a whole multiple.
      def floor_div(value, by)
        Build.binop(:/, Build.binop(:-, value, Build.binop(:%, value.copy, Build.int(by))), Build.int(by))
      end

      # The record in the save, the numbers the readings read, and the two routines, the first time
      # the game sets the clock.
      def keep_clock_record
        return if @clock_record

        @clock_record = true
        @clock_own_readings = {}.compare_by_identity # the chip's readings the routines read, left as they are
        RECORD.each_value { |name| save_var name, 0 }
        (SHOWN.values + WORK.values).each { |name| var name, 0 }
        func(AT_POWER_ON) { emit_clock_at_power_on }
        func(READINGS) { emit_clock_readings }
        @per_pass_routines << READINGS
      end

      def emit_clock_at_power_on
        record_conditional(Build.binop(:==, chip_reading(:counting), Build.int(0))) do
          record(Build.set(RECORD[:set], Build.int(0)))
          mirror_save(RECORD[:set])
        end
        record(Build.call(READINGS))
      end

      # The chip's own readings; then, with a time set and a chip to count from, the time set.
      def emit_clock_readings
        b = Build
        work = ->(part) { b.var_ref(WORK.fetch(part)) }
        SHOWN.each { |reading, name| record(b.set(name, chip_reading(reading))) }
        set = b.binop(:and, b.binop(:!=, b.var_ref(RECORD[:set]), b.int(0)), chip_reading(:present))
        record_conditional(set) do
          record(b.set(WORK[:seconds], b.binop(:+, chip_reading(:seconds), b.var_ref(RECORD[:seconds]))))
          record(b.set(WORK[:days], b.binop(:+, chip_reading(:days), b.var_ref(RECORD[:days]))))
          record_conditional(b.binop(:>=, work.call(:seconds), b.int(DAY))) do
            record(b.set(WORK[:seconds], b.binop(:-, work.call(:seconds), b.int(DAY))))
            record(b.set(WORK[:days], b.binop(:+, work.call(:days), b.int(1))))
          end
          record(b.set(SHOWN[:hour], b.binop(:/, work.call(:seconds), b.int(3600))))
          record(b.set(SHOWN[:minute], b.binop(:%, b.binop(:/, work.call(:seconds), b.int(60)), b.int(60))))
          record(b.set(SHOWN[:second], b.binop(:%, work.call(:seconds), b.int(60))))
          IR::Clock.civil_from_days(-> { work.call(:days) }, into: SHOWN, work: WORK).each { |statement| record(statement) }
          record(b.set(SHOWN[:set], b.int(1)))
        end
      end

      # A reading of the chip that the routines make, which reads the chip whatever the game sets.
      def chip_reading(reading) = Build.clock(reading).tap { |node| @clock_own_readings[node] = true }

      # EVERY READING THE GAME WROTE reads its number of SHOWN, and the routine at power-on runs
      # first, once every routine is built. A game that never sets the clock is left as it is.
      def finalize_clock_readings
        return unless @clock_record

        @program.walk.select { |node| node.kind == :clock && SHOWN.key?(node.reading) }.each do |node|
          next if @clock_own_readings.key?(node)
          next if node.parent.replace_operand(node, Build.var_ref(SHOWN.fetch(node.reading)))

          raise IR::InvariantError, "a clock reading at #{node.source || 'an unknown line'} is not held where it can be replaced"
        end
        start = Build.call(AT_POWER_ON)
        @program.children.insert(0, start)
        start.parent = @program
      end
    end
  end
end
