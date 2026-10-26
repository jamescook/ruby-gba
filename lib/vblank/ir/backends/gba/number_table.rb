# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # ONE ROUTINE'S BIG NUMBERS, KEPT AS DATA AFTER ITS LAST INSTRUCTION.
        #
        # THE HARDWARE, briefly. An instruction on this chip is four bytes, and a number
        # written inside one has twelve bits to live in: a single byte, and how far round
        # to turn it. So a number is one instruction only when it is a byte's worth of bits
        # sitting together (or every bit of it is, turned over). Anything else is built a
        # byte at a time, up to four instructions — and an address of something in the
        # cartridge is always four, because it is filled in after the code around it has
        # been laid out and cannot change size then.
        #
        # The chip offers one other way, and it is what this is. Keep the number as a word
        # of plain data next to the code, and READ it: a load instruction can name a word
        # by how far ahead of itself it sits. That is one instruction whatever the number
        # is, plus the word. Three instructions become two words, and four become two.
        #
        # WHY ONLY SOME ROUTINES. The saving is worth having in exactly one place: the
        # console's quick memory, where 32K is shared by everything that wants to run
        # fast (see {Placement}). A routine there is competing for room, and a routine
        # that is smaller leaves room for the next one. In the cartridge the bytes are
        # free and the read is the slowest kind the console makes, so there a number is
        # still built.
        #
        # WHY AFTER THE LAST INSTRUCTION. The table has to travel with the routine, since
        # a read names its word by distance and the routine is copied somewhere else at
        # boot — so it sits inside the routine's own span. And it has to be somewhere the
        # chip never runs into, which the far side of the return is: nothing falls
        # through a return.
        #
        # WHAT A READ CAN REACH. The distance has twelve bits too, so a word must be
        # within about four thousand bytes of the instruction that reads it. The longest
        # routines a game keeps in the quick memory are longer than that, so a load near
        # the top of one cannot reach a table at the bottom and is built the old way.
        # That has to be settled when the load is emitted, which is before anybody knows
        # where the routine ends.
        #
        # WHERE THE LINE IS, THEN. A routine shrinks as its numbers become reads, so "how
        # far is the end" keeps changing while the routine is emitted. What does not
        # change is where a load sits in the routine AS IT WAS MEASURED, with every
        # number built: that is this load's place plus everything the reads above it
        # saved. The build works out from the measurement how far from the measured end
        # a load can be and still reach — every load below it will be a read too, and it
        # counts what those save — and hands that distance over (+read_within+). A load
        # nearer the measured end than that is a read; one further is built. The reads
        # are always the bottom of the routine, and exactly the ones the build charged
        # the routine for (see Placement#table_effect).
        #
        # Being wrong about that is a read that names the wrong word: a wrong number in
        # a register with nothing to say so. So it is checked again when the table is
        # written, against where the words really landed, and a read that cannot reach
        # stops the build.
        class NumberTable
          # How far ahead a read may be asked to name a word, in bytes. The chip allows a
          # little more (see FURTHEST); what is left over is margin and nothing else.
          REACH = 4000

          # The furthest the chip itself can name, counted the way it counts: from two
          # instructions past the one that reads.
          FURTHEST = 0xFFF

          # A read waiting to be told how far ahead its word is: where it sits, the
          # register it fills, and which word of the table is its own.
          Read = Data.define(:pos, :reg, :word)

          # A WORD THAT HOLDS AN ADDRESS NOBODY KNOWS YET, where every other word is simply
          # its number: +kind+ says of what (:data_word for something embedded in the
          # cartridge, :label_word for a place in the code) and +target+ which one. The
          # table keeps room for it and the second pass writes it in. Two loads of the same
          # address are the same word, as two loads of the same number are.
          Address = Data.define(:kind, :target)

          # +measured_end+ is where the routine would end with every number built: where
          # it starts plus the size it was measured at. +read_within+ is how far from there,
          # counted in that same all-built routine, a load can be and still be a read.
          # +routine+ is its name, for the one message this can cause.
          def initialize(measured_end:, read_within:, routine:)
            @measured_end = measured_end
            @read_within = read_within
            @routine = routine
            @words = [] # each a number, or an Address
            @reads = []
            @saved = 0  # the bytes the reads so far are shorter than the loads they replaced
          end

          attr_reader :words, :reads, :routine

          # Is a load at +pos+ one to read? +pos+ is where it really is, which is nearer
          # the top than it was measured by whatever the reads above it saved; adding that
          # back says where it sat in the routine as measured.
          def reaches?(pos)
            @measured_end - (pos + @saved) <= @read_within
          end

          # Note a read at +pos+ into +reg+ of +word+, in place of a load that would have
          # been +built_bytes+ long, giving the word a place if it has none.
          def note_read(pos, reg, word, built_bytes:)
            @words << word unless @words.include?(word)
            @reads << Read.new(pos: pos, reg: reg, word: @words.index(word))
            @saved += built_bytes - 4
          end

          # How far ahead of +read+ its word is, as the chip counts it, once the table has
          # been written starting at +table_start+.
          def distance_ahead(read, table_start)
            (table_start + (4 * read.word)) - (read.pos + 8)
          end

          # Can the chip name a word that far ahead?
          def self.within_reach?(ahead) = (0..FURTHEST).cover?(ahead)
        end
      end
    end
  end
end
