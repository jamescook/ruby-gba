# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # A CARTRIDGE THAT IS ONLY ITS FILE: the bytes of a .gba or a .gbc, and nothing the build
    # worked out about them. A cartridge somebody else made is one, and so is one this framework
    # built once it has been written to a file — what the build knew is in the program that
    # built it and never in the file.
    #
    # It can be run, and its screen and its memory read. What it cannot do is say what
    # anything in it is called: no variable has a name and no sprite does, because the
    # names were the build's. A reader that is asked for one says so (see Verifier).
    #
    # It answers what a running console asks of a cartridge — which console it is for, its
    # title, its bytes, and to be written to a file for the emulator to open — with nothing
    # where a build record would be. What a cartridge can only say of itself with a record
    # (its size by routine, its profile) it does not answer at all.
    class CartridgeFile
      # The kinds of cartridge a file can be, each knowing its own header.
      KINDS = [Cartridge::ROM, Cartridge::GBCROM].freeze
      private_constant :KINDS

      attr_reader :path, :buffer

      def initialize(path)
        raise ArgumentError, "There is no cartridge file at #{path}. Give the path of a cartridge file." unless File.file?(path)

        @path = path.to_s
        @buffer = File.binread(path).freeze
        @kind = KINDS.find { |kind| kind.header?(@buffer) }
        refuse_non_cartridge!
      end

      # Nothing built this, so there is no record of how.
      def built = nil
      def source_program = nil
      def var_addresses = nil

      # The console the cartridge is for, and the title field of its header, read where that
      # console's cartridges keep it.
      def console = @kind.console
      def header_title = @kind.title_field_of(@buffer)

      # Write the cartridge's bytes to +path+, the way a built cartridge writes its own (see
      # Cartridge::ROM.write_bytes for why it is not an ordinary write).
      def write(path) = Cartridge::ROM.write_bytes(path, @buffer)

      private

      # A file whose header is no cartridge's is something else, given where a cartridge goes.
      def refuse_non_cartridge!
        return if @kind

        raise ArgumentError, "The file at #{@path} is not a cartridge. Every cartridge has the same bytes at one place " \
                             "in its heading, and this file does not. Give the path of a cartridge file."
      end
    end
  end
end
