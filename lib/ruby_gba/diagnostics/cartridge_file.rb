# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # A CARTRIDGE THAT IS ONLY ITS FILE: the bytes of a .gba, and nothing the build worked
    # out about them. A cartridge somebody else made is one, and so is one this framework
    # built once it has been written to a file — what the build knew is in the program that
    # built it and never in the file.
    #
    # It can be run, and its screen and its memory read. What it cannot do is say what
    # anything in it is called: no variable has a name and no sprite does, because the
    # names were the build's. A reader that is asked for one says so (see Verifier).
    #
    # It answers what a running console asks of a cartridge — its bytes, and to be written
    # to a file for the emulator to open — with nothing where a build record would be. What
    # a cartridge can only say of itself with a record (its size by routine, its profile)
    # it does not answer at all.
    class CartridgeFile
      attr_reader :path, :buffer

      # Every cartridge carries this byte at this place in its header, whoever made it. A
      # file without it is something else that was given where a cartridge goes.
      FIXED_BYTE_AT = Cartridge::Header::HEADER_FIXED
      FIXED_BYTE = Cartridge::ROM::FIXED_VALUE
      private_constant :FIXED_BYTE_AT, :FIXED_BYTE

      def initialize(path)
        raise ArgumentError, "There is no cartridge file at #{path}. Give the path of a cartridge file." unless File.file?(path)

        @path = path.to_s
        @buffer = File.binread(path).freeze
        refuse_non_cartridge!
      end

      # Nothing built this, so there is no record of how.
      def built = nil
      def source_program = nil
      def var_addresses = nil

      # Write the cartridge's bytes to +path+, the way a built cartridge writes its own (see
      # Cartridge::ROM.write_bytes for why it is not an ordinary write).
      def write(path) = Cartridge::ROM.write_bytes(path, @buffer)

      private

      def refuse_non_cartridge!
        return if @buffer.getbyte(FIXED_BYTE_AT) == FIXED_BYTE

        raise ArgumentError, "The file at #{@path} is not a cartridge. Every cartridge has the same byte at one place " \
                             "in its heading, and this file does not. Give the path of a cartridge file."
      end
    end
  end
end
