# frozen_string_literal: true

module RubyGBA
  module IR
    # WHERE SAVE DATA LIVES IN SAVE MEMORY, and how a copy of it says whether it is good.
    #
    # A fact about the program's save memory rather than about any machine, so every backend
    # reads it from here: the console lays its chip out this way and the interpreter lays its
    # store out the same way, which is what lets a test cut the power half way through a save
    # and mean the same thing on both.
    #
    # THE FIRST BLOCK IS `save_var`'s, as it always was: a marker and a word per saved
    # number. Save data starts after it, at a place nothing a game adds can move — so a game
    # that grows another `save_var` still finds last week's save files where it left them.
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

      # Where save data starts: past the block `save_var` keeps.
      START = 0x1000

      # How much there is to put it in. The console's battery-backed memory is 32K.
      SIZE = 0x8000

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
    end
  end
end
