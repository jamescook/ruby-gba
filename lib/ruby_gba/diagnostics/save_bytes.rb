# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # THE BYTES OF A SAVE FILE, KEPT AS THEY ARE: the save memory of a cartridge whose chip is
    # not one this framework's own cartridges have.
    #
    # Save memory comes in more kinds than the framework builds with. It models the ones it
    # builds — what is in them, how each takes a write — as an IR::SaveImage. A cartridge
    # somebody else made can carry another kind, and all that is known of it is the file an
    # emulator keeps it in. So that file's bytes are held whole and handed back whole: enough
    # to start a playthrough from the save, to write it to a file again and to tell two saves
    # apart, and nothing that pretends to know what the bytes mean.
    #
    # It answers the two things a playthrough asks of any save: its bytes as a .sav file, and
    # to be written to one.
    class SaveBytes
      attr_reader :to_sav

      # Where the bytes came from, for an error to name.
      attr_reader :from

      def initialize(bytes, from: "This save")
        @to_sav = bytes.b.freeze
        @from = from
      end

      # THE SAVE THESE BYTES ARE: an IR::SaveImage when they are the size of a chip this
      # framework's cartridges have, and otherwise the bytes kept as they are.
      def self.save_holding(bytes, from:)
        modelled = IR::SaveLayout::NAMEABLE.any? { |kilobytes| bytes.bytesize == kilobytes * 1024 }
        modelled ? IR::SaveImage.from_sav(bytes) : new(bytes, from: from)
      end

      def bytesize = to_sav.bytesize

      # Write the bytes to +path+ as a .sav file. The path is handed back.
      def write_sav(path)
        Cartridge::ROM.write_bytes(path, to_sav)
        path
      end

      def ==(other) = other.is_a?(SaveBytes) && other.to_sav == to_sav
    end
  end
end
