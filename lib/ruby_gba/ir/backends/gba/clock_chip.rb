# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # THE CARTRIDGE'S CLOCK CHIP, read for the game.
        #
        # THE HARDWARE. The console has no clock of its own. A cartridge that keeps the date and
        # time carries a small chip for it (the Seiko S-3511A the console's own games used), with
        # a watch battery that keeps it counting while the console is off. The chip is not in the
        # console's memory at all: the cartridge brings four pins out at the bottom of its own
        # address space, and the chip hangs off three of them — one the console ticks as a clock
        # (SCK), one that carries a bit either way (SIO), and one that says a conversation is going
        # on (CS). So the console talks to it a bit at a time: it raises CS, ticks a command byte
        # in on SIO, and then either ticks in the bytes that go with it or ticks the chip's answer
        # back out the same way, lowest bit first. The answer is the year, month, day, day of the
        # week, hour, minute and second, each a byte holding two decimal digits.
        #
        # AT POWER-ON the chip is asked whether it is there at all and whether its time was ever
        # set; a cartridge with no chip, or one whose battery ran out, is never asked again, and
        # every reading stays 0, which is IR::Clock's promise. THEN AFTER EACH WAIT FOR THE SCREEN
        # the date and time are read into a copy the game reads, so every reading between two waits
        # is of one moment, as on every backend, and a game reading the time twenty times a pass
        # talks to the chip once.
        #
        # IS THERE A CHIP? With none, the pins are not pins: reading them reads two bytes of the
        # cartridge's own code, which never change, so every bit the console ticks back is the same
        # and the chip's settings read as all noughts or all ones. The chip, told to count in 24
        # hours, reads that setting back with that one bit on, which neither of those is.
        class ClockChip
          # The pins' registers: what is on each pin, which way each one points (a 1 is the
          # console driving it), and whether the console can read them back at all.
          PINS = 0x080000C4
          DIRECTION = 2 # ...after PINS
          READABLE = 4  # ...after PINS

          SCK = 1
          SIO = 2
          CS = 4

          # The commands as the chip's own documentation writes them, highest bit first: 0110 at
          # the top says it is a command at all, the next three which register, and the lowest bit
          # whether the console reads it. They go out on the wire in that order, highest bit first —
          # and since the routine below sends a byte lowest bit first, each is kept with its bits
          # turned round.
          def self.turned(byte) = byte.to_s(2).rjust(8, "0").reverse.to_i(2)

          READ_DATE_AND_TIME = turned(0x65)
          READ_SETTINGS = turned(0x63)
          WRITE_SETTINGS = turned(0x62)

          # In the settings: count the hours 0 to 23, and the battery has run out since the time
          # was last set.
          HOURS_24 = 0x40
          POWER_LOST = 0x80

          # Each byte of the answer, in the order it comes, with the bits that hold its digits —
          # the chip uses the top bits of some for flags of its own.
          ANSWER = Ractor.make_shareable([[:year, 0xFF], [:month, 0x1F], [:day, 0x3F], [:weekday, 0x07],
                                          [:hour, 0x3F], [:minute, 0x7F], [:second, 0x7F]])

          # The chip's years count from 2000.
          CENTURY = 2000

          # The routines, each bracketed by its name and the same name with _end so a profile
          # names the time spent in it (GBA#lowered_routine_addresses).
          AT_POWER_ON = :__clock_chip_at_power_on
          AFTER_WAIT = :__clock_chip_each_pass
          SEND = :__clock_chip_send
          RECEIVE = :__clock_chip_receive
          ROUTINES = [AT_POWER_ON, AFTER_WAIT, SEND, RECEIVE].freeze

          # Where the copy of each reading is kept.
          def self.var(reading) = :"__clock_#{reading}"

          # THE REGISTERS THE ROUTINES WORK IN: ACC for the byte going out or coming back, TMP for
          # the pins' value, SPARE as the bit count, and HIGH holding the pins' address. All four
          # are a statement's own scratch, never held across one, and the routines are called only
          # between statements, so nothing the game holds is in them. The two outer routines reach
          # the copy through ADDR, as every variable is reached.
          BITS = 2 # GBA::SPARE, named here because this file loads before that one defines it
          BASE = 3 # GBA::HIGH, likewise
          LR = 14
          PC = 15

          def initialize(emitter:, primitives:, call_cold_routine:)
            @emitter = emitter
            @primitives = primitives
            @call_cold_routine = call_cold_routine
            @used = false
          end

          # Does this program read the clock at all? Nothing here is emitted for one that does not.
          def prepare(program) = @used = program.walk.any? { |node| node.kind == :clock }

          def used? = @used

          # A reading, from the copy the last wait left.
          def eval_clock(node) = @primitives.load_var(ACC, self.class.var(node.reading))

          # At power-on: is there a chip, was it ever set, and the reading before the first wait.
          def emit_call_at_power_on
            return unless @used

            @call_cold_routine.call(AT_POWER_ON)
            @call_cold_routine.call(AFTER_WAIT)
          end

          # After each wait for the screen.
          def emit_call_after_wait
            @call_cold_routine.call(AFTER_WAIT) if @used
          end

          # The routines themselves, in the cartridge: a reading is a long, slow conversation over
          # the cartridge's pins whether the code is fast or not.
          def emit_routines
            return unless @used

            emit_routine(AT_POWER_ON) { emit_at_power_on_body }
            emit_routine(AFTER_WAIT) { emit_after_wait_body }
            emit_send_routine
            emit_receive_routine
          end

          private

          def emit_routine(label)
            @emitter.place_label(label)
            @emitter.emit(ASM.push(LR))
            yield
            @emitter.emit(ASM.pop(PC))
            @emitter.place_label(:"#{label}_end")
          end

          # Every reading 0 to begin with — the console's memory is not nought at power-on — then
          # the settings read, the chip told to count in 24 hours, and the settings read again.
          def emit_at_power_on_body
            IR::Clock::READINGS.each do |reading|
              @emitter.emit(ASM.load_immediate(ACC, 0))
              @primitives.store_var(ACC, self.class.var(reading))
            end
            @emitter.emit_number(BASE, PINS)
            emit_pins_readable(1)
            emit_read_settings
            @primitives.store_var(ACC, self.class.var(:set)) # the settings before they are changed, for now
            emit_start_conversation(WRITE_SETTINGS)
            @emitter.emit(ASM.load_immediate(ACC, HOURS_24))
            @emitter.emit_branch(:bl, SEND)
            emit_end_conversation
            emit_read_settings
            emit_pins_readable(0)
            emit_present_and_set
          end

          # THE PINS READ BACK ONLY WHILE THE CONSOLE TALKS TO THE CHIP, as the console's own games
          # leave them: readable, their two bytes of the cartridge read as the pins; not, as the
          # cartridge's code. Uses TMP.
          def emit_pins_readable(on)
            @emitter.emit(ASM.load_immediate(TMP, on))
            @emitter.emit(ASM.store_halfword_offset(TMP, BASE, READABLE))
          end

          # Read the chip's settings into ACC.
          def emit_read_settings
            emit_start_conversation(READ_SETTINGS)
            @emitter.emit_branch(:bl, RECEIVE)
            emit_end_conversation
          end

          # THERE IS A CHIP when the settings read back with the 24-hour bit on and are not all
          # ones; ITS TIME WAS SET when, besides, the battery had not run out before the console
          # asked.
          def emit_present_and_set
            absent = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(ACC, 0xFF))
            @emitter.emit_branch(:bcond, absent, cond: :eq)
            @emitter.emit(ASM.tst_imm(ACC, HOURS_24))
            @emitter.emit_branch(:bcond, absent, cond: :eq)
            @emitter.emit(ASM.load_immediate(ACC, 1))
            @primitives.store_var(ACC, self.class.var(:present))
            @primitives.load_var(ACC, self.class.var(:set))
            @emitter.emit(ASM.tst_imm(ACC, POWER_LOST))
            @emitter.emit(ASM.mov_imm_cond(:eq, ACC, 1))
            @emitter.emit(ASM.mov_imm_cond(:ne, ACC, 0))
            @primitives.store_var(ACC, self.class.var(:set))
            @emitter.emit_branch(:b, done)
            @emitter.place_label(absent)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, self.class.var(:set))
            @emitter.place_label(done)
          end

          # A READING: nothing at all unless the chip is there and set, and then the date and time,
          # each byte's two digits made one number as it comes.
          def emit_after_wait_body
            skip = @emitter.gensym
            @primitives.load_var(ACC, self.class.var(:set))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, skip, cond: :eq)
            @emitter.emit_number(BASE, PINS)
            emit_pins_readable(1)
            emit_start_conversation(READ_DATE_AND_TIME)
            ANSWER.each do |reading, digits|
              @emitter.emit_branch(:bl, RECEIVE)
              emit_digits_to_number(digits)
              if reading == :year
                @emitter.emit_number(TMP, CENTURY)
                @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
              end
              @primitives.store_var(ACC, self.class.var(reading))
            end
            emit_end_conversation
            emit_pins_readable(0)
            @emitter.place_label(skip)
          end

          # ACC holds two decimal digits, one in each half of its low byte; it is left holding
          # the number they make, tens times ten plus units. Uses TMP and BITS.
          def emit_digits_to_number(digits)
            @emitter.emit(ASM.and_imm(ACC, ACC, digits))
            @emitter.emit(ASM.lsr_imm(TMP, ACC, 4))          # the tens
            @emitter.emit(ASM.and_imm(ACC, ACC, 0x0F))       # the units
            @emitter.emit(ASM.lsl_imm(BITS, TMP, 3))         # tens * 8
            @emitter.emit(ASM.add_reg(ACC, ACC, BITS))
            @emitter.emit(ASM.lsl_imm(BITS, TMP, 1))         # ...and tens * 2
            @emitter.emit(ASM.add_reg(ACC, ACC, BITS))
          end

          # A CONVERSATION STARTS: every pin the console's, CS low with the clock high, which tells
          # the chip to forget any conversation half done, then CS raised and +command+ sent — and,
          # for a command the console reads, SIO handed over to the chip. The pins are pointed
          # first: at power-on they point nowhere, and a pin that is not the console's ignores what
          # is written to it, so the chip would never hear CS go low.
          def emit_start_conversation(command)
            @emitter.emit(ASM.load_immediate(TMP, SCK | SIO | CS))
            @emitter.emit(ASM.store_halfword_offset(TMP, BASE, DIRECTION))
            emit_pins(SCK)
            emit_pins(SCK | CS)
            @emitter.emit(ASM.load_immediate(ACC, command))
            @emitter.emit_branch(:bl, SEND)
            return if command.nobits?(0x80) # the read bit, as the byte is kept turned round

            @emitter.emit(ASM.load_immediate(TMP, SCK | CS))
            @emitter.emit(ASM.store_halfword_offset(TMP, BASE, DIRECTION))
          end

          # ...and it ends with CS low.
          def emit_end_conversation = emit_pins(SCK)

          def emit_pins(value)
            @emitter.emit(ASM.load_immediate(TMP, value))
            @emitter.emit(ASM.store_halfword(TMP, BASE))
          end

          # SEND THE BYTE IN ACC, lowest bit first: each bit put on SIO with the clock low, then
          # the clock raised, which is when the chip takes it. The low half is written three times,
          # as the console's own games do, so a real chip has time to see it. Uses ACC, TMP and
          # BITS, with the pins' address in BASE.
          def emit_send_routine
            bit = @emitter.gensym
            @emitter.place_label(SEND)
            @emitter.emit(ASM.load_immediate(BITS, 8))
            @emitter.place_label(bit)
            @emitter.emit(ASM.and_imm(TMP, ACC, 1))
            @emitter.emit(ASM.lsl_imm(TMP, TMP, 1))           # the bit, on SIO
            @emitter.emit(ASM.orr_imm(TMP, TMP, CS))
            3.times { @emitter.emit(ASM.store_halfword(TMP, BASE)) }
            @emitter.emit(ASM.orr_imm(TMP, TMP, SCK))
            @emitter.emit(ASM.store_halfword(TMP, BASE))
            @emitter.emit(ASM.lsr_imm(ACC, ACC, 1))
            @emitter.emit(ASM.subs_imm(BITS, BITS, 1))
            @emitter.emit_branch(:bcond, bit, cond: :ne)
            @emitter.emit(ASM.return)
            @emitter.place_label(:"#{SEND}_end")
          end

          # TICK A BYTE BACK INTO ACC, lowest bit first: the clock lowered, which is when the chip
          # puts its next bit on SIO, then raised, and SIO read. Each bit goes in at the top and
          # moves down, so the first one sent ends at the bottom. The low half is written five
          # times, as the console's own games do when they read, so a real chip has its bit on SIO
          # before it is read. Uses ACC, TMP and BITS, with the pins' address in BASE.
          def emit_receive_routine
            bit = @emitter.gensym
            @emitter.place_label(RECEIVE)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @emitter.emit(ASM.load_immediate(BITS, 8))
            @emitter.place_label(bit)
            emit_pins(CS)
            4.times { @emitter.emit(ASM.store_halfword(TMP, BASE)) }
            emit_pins(CS | SCK)
            @emitter.emit(ASM.load_halfword(TMP, BASE))
            @emitter.emit(ASM.lsr_imm(TMP, TMP, 1))
            @emitter.emit(ASM.and_imm(TMP, TMP, 1))           # SIO
            @emitter.emit(ASM.lsr_imm(ACC, ACC, 1))
            @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, TMP, 7))
            @emitter.emit(ASM.subs_imm(BITS, BITS, 1))
            @emitter.emit_branch(:bcond, bit, cond: :ne)
            @emitter.emit(ASM.return)
            @emitter.place_label(:"#{RECEIVE}_end")
          end
        end
      end
    end
  end
end
