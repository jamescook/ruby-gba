# frozen_string_literal: true

require "zlib"

module RubyGBA
  module IR
    # WHERE SAVE DATA LIVES IN SAVE MEMORY, and how a copy of it says whether it is good.
    #
    # A fact about the program's save memory rather than about any machine, so every backend
    # reads it from here: the console lays its chip out this way and the interpreter lays its
    # store out the same way, which is what lets a test cut the power half way through a save
    # and mean the same thing on both.
    #
    # THE FIRST BLOCK OF THE 32K MEMORY IS `save_var`'s, as it always was: a marker and a word
    # per saved number. Save data starts after it, at a place nothing a game adds can move — so a game
    # that grows another `save_var` still finds last week's save files where it left them.
    #
    # THEN A TABLE OF PLACES: one row per record, saying where in save memory it lives, how
    # big a half of it is and how many copies it has, found by a number worked out from the
    # record's name. A record's place is read from here at power-on rather than worked out
    # from the records declared before it, so a game updated after it shipped — a record
    # added, grown, dropped or declared in another order — leaves every record it did not
    # change where the player's saves are. The table is kept exactly the way a record is (two
    # halves, the newer one wins, a checksum last), so the power going off while it is being
    # written leaves the last good one.
    #
    # EVERY COPY IS KEPT TWICE. A save goes into the older of the two, and only once the whole
    # of it is written does its header say it is newer. So a save cut off half way — the
    # power going off, the cartridge pulled — leaves the other one as it was, and the copy is
    # still the last good save. Each half starts with a header:
    #
    #   marker    a word saying save data was written here at all
    #   shape     a word worked out from what the record keeps, so a game whose record has
    #             changed shape reads last version's saves as empty rather than as nonsense
    #   sequence  a word, one more than the other half's, so the newer half is known
    #   kind      a word: this half holds a save, or says the copy was erased
    #   checksum  a word over the half's bytes, written LAST: until it is, the half cannot
    #             pass for good
    module SaveLayout
      module_function

      # Where save data starts in the 32K memory: past the block `save_var` keeps. Anything
      # that places save data asks a Memory (below), which knows flash starts elsewhere.
      START = 0x1000

      # HOW `save_var` KEEPS ITS NUMBERS in that first block: the game's marker in the first
      # word, then a word a variable in the order they were declared. A block of 4K holds the
      # marker and 1023 of them, and that is a limit rather than a starting point: one more
      # would land on the table of places, and every save file would go with it.
      SAVE_VARS = (START / 4) - 1

      # Where save_var's marker is kept.
      SAVE_VAR_MARKER_AT = 0

      # Where the number of the save_var in +slot+ (counting from 0) is kept. A slot past
      # what the block holds is refused here, which is where both backends and the builder ask.
      def save_var_at(slot)
        raise ArgumentError, too_many_save_vars_message(slot + 1) if slot >= SAVE_VARS

        SAVE_VAR_MARKER_AT + 4 + (slot * 4)
      end

      # Why a game with +count+ save_vars cannot be built.
      def too_many_save_vars_message(count)
        "This game has #{count} save_var variables. Save memory holds #{SAVE_VARS} of them. To fix " \
          "this, keep the rest in a save_data record, which can hold lists and many more numbers."
      end

      # The 32K memory's size.
      SIZE = 0x8000

      # THE SAVE MEMORIES A CARTRIDGE CAN HAVE, in kilobytes: the 32K above, or a flash chip of
      # 64K or 128K. Flash keeps a save with no battery, and real cartridges shipped both sizes.
      MEMORIES = [32, 64, 128].freeze

      # Flash is wiped a block at a time before it can be written again, and this is the block.
      # So on flash every half of a record starts on one and covers whole ones: wiping a half
      # can never touch the copy beside it.
      SECTOR = 0x1000

      # THE SHAPE OF ONE SAVE MEMORY: how big it is, where the table of places and the records
      # go, and how much room a half of a record takes. Everything that works out a place in
      # save memory asks this — the build's check that the records fit, the routines that
      # place them at power-on, and the address of each half — so none of them can lay the
      # memory out one way while another checks it another.
      #
      # The 32K memory is packed: the table straight after save_var's block, and each half of a
      # record straight after the last. Flash is wiped a block at a time, so on it each half of
      # the table takes one block of its own and every half of a record whole blocks of its
      # own: wiping a half can never touch the one beside it. Flash keeps no block for
      # save_var, whose numbers are kept there in a record like any other (see
      # Builder::SaveVarRecord), so the table starts at the very beginning.
      Memory = Data.define(:kilobytes) do
        def flash? = kilobytes != MEMORIES.first

        # How many bytes there are.
        def size = kilobytes * 1024

        # Where the table of places starts.
        def table_at = flash? ? 0 : START

        # Where records can go: past both halves of the table.
        def data_start = table_at + (2 * room(SaveLayout.half_bytes(TABLE_BODY)))

        # What a half's room is counted in: whole blocks on flash, single bytes in the packed
        # 32K. Anything that rounds a half to its room — here, or in a routine that works it
        # out as the game runs — rounds up to a whole number of these.
        def block = flash? ? SECTOR : 1

        # How many bytes a half of +half+ bytes takes, which is how far apart the halves sit.
        def room(half) = ((half + block - 1) / block) * block

        # How many bytes a record with halves of +half+ bytes and +copies+ copies takes.
        def record_room(half, copies) = room(half) * 2 * copies

        # Do records taking +halves+ — one [half_bytes, copies] pair a record — all fit at once?
        def fits?(halves) = halves.sum { |half, copies| record_room(half, copies) } <= size - data_start
      end

      # The save memory of +kilobytes+.
      def memory(kilobytes) = Memory.new(kilobytes)

      # The packed 32K memory, which a table is read from and written to unless it says otherwise.
      PACKED = memory(MEMORIES.first)

      # The save memory +program+ says it has (a `save_memory` node), or the 32K when it says
      # nothing. Every backend asks this, so none can run a program on memory another lays out
      # differently.
      def memory_of(program)
        named = program.walk.find { |node| node.kind == :save_memory }
        named ? memory(named.kilobytes) : PACKED
      end

      # Does a game whose records take +halves+ — one [half_bytes, copies] pair a record — fit
      # in +kilobytes+ of save memory?
      def fits?(kilobytes, halves) = memory(kilobytes).fits?(halves)

      # The smallest save memory those records fit in, or nil when none holds them.
      def smallest_fitting(halves) = MEMORIES.find { |kilobytes| fits?(kilobytes, halves) }

      MARKER = 0x5441_4453 # "SDAT" as its bytes
      HEADER = 20
      MARKER_AT = 0
      SHAPE_AT = 4
      SEQUENCE_AT = 8
      KIND_AT = 12
      CHECKSUM_AT = 16

      SAVED = 1
      ERASED = 2

      # What a copy can be, in the order a game's `state` counts them.
      STATES = %i[empty erased good damaged].freeze

      # How many bytes one half of a copy takes: its header and its body, kept to whole words.
      def half_bytes(body) = HEADER + (((body + 3) / 4) * 4)

      # THE CHECKSUM, said once so both backends compute the same one. Two running totals,
      # the bytes and the totals so far, each kept to sixteen bits: the second is what notices
      # two bytes that swapped places, which a plain sum does not.
      def checksum(bytes)
        low = 0
        high = 0
        bytes.each do |byte|
          low = (low + byte) & 0xFFFF
          high = (high + low) & 0xFFFF
        end
        Int32.wrap((high << 16) | low)
      end

      # How many records the table has rows for.
      TABLE_ROWS = 16

      # What a row says, each a column of its own: the record's name as a number, where it
      # starts, how many bytes one half of a copy takes, and how many copies it has.
      TABLE_COLUMNS = %i[key at half copies].freeze

      # How many bytes the table's body takes: each column is kept as a list, its length and
      # then a word a row.
      TABLE_BODY = TABLE_COLUMNS.length * (4 + (TABLE_ROWS * 4))

      # A record's name as a number, which is how its row in the table is found. Never 0, which
      # marks a row nothing uses.
      def record_key(name)
        key = Int32.wrap(Zlib.crc32("save_data:#{name}"))
        key.zero? ? 1 : key
      end

      # A record's shape: a number worked out from what it keeps, in order — each thing's kind,
      # name, width and count — so a record that keeps something else reads the last build's
      # saves as someone else's.
      def shape(items)
        Int32.wrap(Zlib.crc32(items.map { |kind, name, width, count| [kind, name, width, count].join(":") }.join(";")))
      end

      # THE TABLE OF PLACES' OWN FACTS. The build writes the table through the same routines a
      # record uses; SaveImage#write_table and SaveImage#table say the same layout directly, for
      # a test that wants to start a game from a table it chose and see where each record went.
      module Table
        # One row: the record's key (see SaveLayout.record_key), where it starts, how many
        # bytes one half of a copy takes, and how many copies it has.
        Row = Data.define(:key, :at, :half, :copies)

        module_function

        # The table's own shape — it is kept the way a record keeping four lists is.
        def shape
          SaveLayout.shape(TABLE_COLUMNS.map do |column|
            [:list, Messages::MadeNames.make(:save_table, column: column), :word, TABLE_ROWS]
          end)
        end
      end
    end
  end
end
