# frozen_string_literal: true

module VBlank
  module IR
    # A CARTRIDGE'S SAVE MEMORY, held in Ruby: the bytes the chip keeps when the console is off.
    #
    # The interpreter reads and writes one of these where the console reads and writes its
    # chip, and it outlives the interpreter on purpose: hand the same one to a second run and
    # that is the console turned on again with the same cartridge in it. It is laid out exactly
    # the way the console lays out its chip (see SaveLayout) — `save_var`'s numbers and every
    # save_data record in the same bytes — so a game that overruns one part into another does it
    # on both, and the bytes one wrote can be handed to the other as a .sav file. The game built
    # as a desktop program keeps the same bytes again, in a file (runtime/rg_save.c is this
    # class in C), so a save goes between all three.
    #
    # A byte nothing ever wrote reads as 0xFF, which is what a fresh chip holds.
    #
    # It keeps the rules of the memory the program says it has. Battery-backed memory takes any
    # byte anywhere. Flash can only turn bits off in a write, and the only way to turn them back
    # on is to wipe the whole 4K block holding them, which leaves every byte of it 0xFF.
    class SaveImage
      FRESH_BYTE = 0xFF

      # What a byte of a block being wiped reads: the top bit the other way round from the
      # 0xFF it is on its way to, which is how a flash chip says it is busy.
      BUSY_BYTE = 0x00

      # Raised by a write once the power has gone off (see #cut_power_after).
      class PowerOff < StandardError; end

      # Raised by something the chip cannot do: a write flash cannot take where it was asked to,
      # or a place past the end of the chip.
      class Refused < StandardError; end

      # +kilobytes+ is the size of the chip, which also says what kind it is. Left out, it is
      # whatever the first program run on it says it has. +bytes+ is what the chip holds
      # already, address to byte — the save memory a console run left behind, say.
      def initialize(kilobytes: nil, bytes: {})
        @memory = kilobytes && SaveLayout.memory(kilobytes)
        @bytes = bytes.dup
        @power_left = nil
        @wiping = nil
      end

      # A copy holds its own bytes, so a test can start several runs from one moment. A cut
      # waiting on the original is not copied.
      def initialize_copy(source)
        super
        @bytes = source.written
        @power_left = nil
        @wiping = nil
      end

      # The kind and size of the chip (an IR::SaveLayout::Memory).
      def memory = @memory || SaveLayout::PACKED

      # Take the save memory +program_memory+ a program says it has. A chip cannot change, so
      # one that was already another size is refused.
      def use_memory!(program_memory)
        @memory ||= program_memory
        return if @memory == program_memory

        raise WrongSize.new(@memory.kilobytes, program_memory.kilobytes)
      end

      # Raised when save memory of one size is handed to a program that has another. It
      # keeps the two sizes, for whoever handed the save over to say it in their own words.
      class WrongSize < ArgumentError
        attr_reader :save_kilobytes, :program_kilobytes

        def initialize(save_kilobytes, program_kilobytes)
          @save_kilobytes = save_kilobytes
          @program_kilobytes = program_kilobytes
          super("This save memory is #{save_kilobytes}K, and the program has #{program_kilobytes}K. " \
                "Make a SaveImage for this program with kilobytes: #{program_kilobytes}.")
        end
      end

      # The +width+ bytes at +at+, lowest first, as an unsigned number.
      def read(at, width) = read_bytes(at, width).each_with_index.sum { |byte, i| byte << (8 * i) }

      # The word at +at+, as the signed number a variable holds.
      def word(at) = Int32.wrap(read(at, 4))

      # The +count+ bytes from +at+. While a block is being wiped (see #wipe_block), a byte of it
      # reads BUSY_BYTE, and that read is the one that finds the wipe finished.
      def read_bytes(at, count)
        refuse_outside_memory!("read", at, count)
        busy = false
        bytes = (at...(at + count)).map do |i|
          next @bytes.fetch(i, FRESH_BYTE) unless wiping?(i)

          busy = true
          BUSY_BYTE
        end
        @wiping = nil if busy
        bytes
      end

      # The checksum of the +length+ bytes from +at+ (see SaveLayout.checksum).
      def checksum(at, length) = SaveLayout.checksum(read_bytes(at, length))

      # Every byte something wrote, address to byte, for holding beside what the console wrote.
      def written = @bytes.dup

      # Write +value+'s low +width+ bytes at +at+, lowest first, one byte at a time — so the
      # power going off part way keeps the bytes before it. Raises PowerOff when it does, and
      # Refused when the chip cannot take a byte there.
      def write(at, value, width)
        refuse_outside_memory!("wrote to", at, width)
        width.times do |i|
          spend_power!
          byte = (value >> (8 * i)) & 0xFF
          if memory.flash?
            refuse_while_wiping!("wrote to", at + i)
            refuse_write_needing_wipe!(at + i, byte)
          end
          @bytes[at + i] = byte
        end
      end

      # Wipe the block holding +at+. Memory that takes any byte has no blocks to wipe, and
      # nothing is wiped once the power has gone off.
      #
      # A flash chip takes a while to wipe a block. With +wait+ the wipe is over when this
      # returns. Without, the chip is still at it: it is busy until the program reads the block
      # (see #read_bytes), and a write or another wipe before then is refused.
      #
      # A WIPE IS TWO STEPS of a cut (see #cut_power_after), because it takes long enough for
      # the power to go off in the middle of it. Cut before it starts, the block keeps what it
      # held; cut half way, the first half reads 0xFF and the rest is as it was. A real chip cut
      # in a wipe leaves the whole block in no state anybody can count on; this is one such
      # state — neither the old bytes nor a wiped block — which is what a save has to survive.
      def wipe_block(at, wait: true)
        return unless memory.flash?

        refuse_without_power!
        refuse_outside_memory!("wiped", at, 1)
        refuse_while_wiping!("wiped", at)
        start = (at / memory.block) * memory.block
        if @power_left == 1
          (start...(start + (memory.block / 2))).each { |byte| @bytes.delete(byte) }
          @power_left = 0
          raise PowerOff
        end
        @power_left -= 2 if @power_left
        (start...(start + memory.block)).each { |byte| @bytes.delete(byte) }
        @wiping = start unless wait
      end

      # TURN THE POWER OFF part way through a save: once +steps+ more steps are taken, the next
      # one raises PowerOff, with what was done kept and nothing after. A byte written is one
      # step and a wipe is two, so a cut can land in the middle of a wipe. The cut is for one
      # run, which ends it with #restore_power. Returns self.
      def cut_power_after(steps)
        @power_left = steps
        self
      end

      # How many more steps the cut waiting on this chip allows (see #cut_power_after), or nil
      # when none is waiting: what something else that plays the game needs to cut it at the
      # same step.
      attr_reader :power_left

      # The console is on again: no cut is waiting, whether or not the last one came, and no
      # wipe is still going on.
      def restore_power
        @power_left = nil
        @wiping = nil
      end

      # THE TABLE OF PLACES, written straight in as a good first half with +sequence+: what an
      # earlier build left in save memory, so a test can start a game from a table it chose.
      # +rows+ are SaveLayout::Table::Row, at most SaveLayout::TABLE_ROWS. Returns self.
      def write_table(rows, sequence: 1)
        words = SaveLayout::TABLE_COLUMNS.flat_map do |column|
          values = rows.map { |row| row.public_send(column) }
          [SaveLayout::TABLE_ROWS, *values, *Array.new(SaveLayout::TABLE_ROWS - values.size, 0)]
        end
        body = words.flat_map { |word| le_bytes(word) }
        header = [SaveLayout::MARKER, SaveLayout::Table.shape, sequence, SaveLayout::SAVED, SaveLayout.checksum(body)]
        (header.flat_map { |word| le_bytes(word) } + body).each_with_index do |byte, i|
          @bytes[memory.table_at + i] = byte
        end
        self
      end

      # The rows in use in the table of places, read from its newer good half, or nil when
      # neither half is good.
      def table
        body_bytes = SaveLayout::TABLE_BODY
        second = memory.table_at + memory.room(SaveLayout.half_bytes(body_bytes))
        halves = [memory.table_at, second].filter_map do |at|
          body = read_bytes(at + SaveLayout::HEADER, body_bytes)
          good = word(at + SaveLayout::MARKER_AT) == SaveLayout::MARKER &&
                 word(at + SaveLayout::SHAPE_AT) == SaveLayout::Table.shape &&
                 word(at + SaveLayout::CHECKSUM_AT) == SaveLayout.checksum(body)
          [word(at + SaveLayout::SEQUENCE_AT), at + SaveLayout::HEADER] if good
        end
        _, body_at = halves.max_by(&:first)
        return nil unless body_at

        columns = SaveLayout::TABLE_COLUMNS.each_with_index.to_h do |column, c|
          start = body_at + (c * (4 + (SaveLayout::TABLE_ROWS * 4)))
          [column, (0...SaveLayout::TABLE_ROWS).map { |r| word(start + 4 + (r * 4)) }]
        end
        (0...SaveLayout::TABLE_ROWS).map { |r| SaveLayout::Table::Row.new(**columns.transform_values { |values| values[r] }) }
                                    .reject { |row| row.key.zero? }
      end

      # The whole chip as the bytes of a .sav file, which is how an emulator is handed one.
      def to_sav = read_bytes(0, memory.size).pack("C*")

      # Write the whole chip to +path+ as a .sav file. The path is handed back.
      def write_sav(path)
        File.binwrite(path, to_sav)
        path
      end

      # Hold the bytes of a .sav file in place of everything this chip held: what a game that
      # keeps its save memory in a file (the desktop build) left there. A chip cannot change
      # size, so the file has to be as big as the chip. +from+ says where the bytes came from,
      # for the error to name. Returns self.
      def replace_with_sav(bytes, from: "These bytes")
        unless bytes.bytesize == memory.size
          raise ArgumentError, "#{from} are #{bytes.bytesize} bytes long, and this save memory is " \
                               "#{memory.kilobytes}K, which is #{memory.size} bytes. A save file is as big as its " \
                               "cartridge's save memory."
        end
        @bytes = self.class.from_sav(bytes, from: from).written
        self
      end

      # A chip holding the bytes of a .sav file, and as big as they are. Save memory comes
      # in a few sizes and a .sav file is exactly one of them, so bytes of any other length
      # are something else. +from+ says where they came from, for the error to name.
      def self.from_sav(bytes, from: "These bytes")
        kilobytes = SaveLayout::NAMEABLE.find { |size| bytes.bytesize == size * 1024 }
        unless kilobytes
          raise ArgumentError, "#{from} are #{bytes.bytesize} bytes long. A save file is as big as its cartridge's save " \
                               "memory, which here is #{SaveLayout::NAMEABLE.map { |size| "#{size}K" }.join(', ')}."
        end
        held = bytes.each_byte.with_index.reject { |byte, _| byte == FRESH_BYTE }
        new(kilobytes: kilobytes, bytes: held.to_h { |byte, at| [at, byte] })
      end

      # The chip the .sav file at +path+ holds.
      def self.read_sav(path) = from_sav(File.binread(path), from: "The bytes of the file at #{path}")

      private

      def spend_power!
        refuse_without_power!
        @power_left -= 1 if @power_left
      end

      def refuse_without_power!
        raise PowerOff if @power_left&.zero?
      end

      def wiping?(at) = @wiping && at >= @wiping && at < @wiping + memory.block

      # The chip has no byte past its end. The console's would land back at its start, or
      # nowhere, so the two backends could only agree by refusing it.
      def refuse_outside_memory!(did, at, count)
        return if at >= 0 && at + count <= memory.size

        raise Refused, Faults.save_outside(did, at, memory.size)
      end

      # A flash chip that is wiping a block takes no other command until it is done.
      def refuse_while_wiping!(did, at)
        return unless @wiping

        raise Refused, format("The program %<did>s flash save memory at 0x%<at>X while the chip was still " \
                                   "wiping the block at 0x%<block>X. After the program starts a wipe, it must " \
                                   "read the block until the block reads 0xFF.", did: did, at: at, block: @wiping)
      end

      # Flash can only turn bits OFF in a write. The chip would quietly keep the bits both
      # bytes have, which is a damaged save nobody sees until it is loaded, so it is refused.
      def refuse_write_needing_wipe!(at, byte)
        held = @bytes.fetch(at, FRESH_BYTE)
        return if (byte & ~held).zero?

        raise Refused, format("The program wrote 0x%<byte>02X to flash save memory at 0x%<at>X, which " \
                                   "holds 0x%<held>02X. Flash cannot take that byte there. Before the " \
                                   "program writes over a block of flash, it must wipe the block.",
                                   at: at, held: held, byte: byte)
      end

      def le_bytes(word) = (0...4).map { |i| (word >> (8 * i)) & 0xFF }
    end
  end
end
