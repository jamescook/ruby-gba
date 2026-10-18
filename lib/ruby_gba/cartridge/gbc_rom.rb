# frozen_string_literal: true

module RubyGBA
  module Cartridge
    # A GAME BOY COLOR CARTRIDGE: the banks the GBC lowering linked, with the header the console
    # reads before it will start one.
    #
    # The header sits at 0x0100 to 0x014F of bank 0. The processor starts at 0x0100, so the first
    # four bytes jump over the rest to the game. The logo after them is compared byte for byte by
    # the console's start-up program, which refuses a cartridge whose logo is not the one it knows.
    # Then the title, a byte saying the game is for the Color alone, which memory bank controller
    # the cartridge has (an MBC5, the chip that switches banks), how big it is and how much memory
    # it keeps, and two checksums: one over the header, which the start-up program also checks,
    # and one over the whole cartridge, which nothing checks but a flash cart's software.
    #
    # The cartridge always has an MBC5. With +save_bytes+ it also has battery-backed memory, the
    # kind a save is kept in: 8K, or 32K in four banks. Without, it has none.
    #
    # Reference: https://gbdev.io/pandocs/The_Cartridge_Header.html
    class GBCROM
      include Console::GBCHardware

      TITLE_LENGTH = 11

      # The ROM size byte names a size of 32K × 2^n.
      SMALLEST = 0x8000

      # The RAM size byte, by the memory a save needs.
      RAM_SIZE_CODES = { 0 => 0x00, 0x2000 => 0x02, 0x8000 => 0x03 }.freeze

      # The cartridge type byte: an MBC5 alone, or with battery-backed memory.
      MBC5 = 0x19

      attr_reader :bytes

      # What the build worked out about the cartridge (where its variables are, the program it
      # came from), for the tools that read a running one back, or nil.
      attr_reader :built

      # +banks+ is the linked cartridge, bank 0 first, each 16K.
      def initialize(banks, title:, save_bytes: 0, built: nil)
        @built = built
        unless RAM_SIZE_CODES.key?(save_bytes)
          raise ArgumentError, "a Game Boy Color cartridge here keeps 0, 8K or 32K of save memory, not #{save_bytes} bytes"
        end

        @bytes = padded(banks.join.b)
        write_header(title, save_bytes)
      end

      def size = @bytes.bytesize

      # The game's title as the header holds it.
      def title = @bytes.byteslice(TITLE_AT, TITLE_LENGTH).delete("\0")

      def write(path) = ROM.write_bytes(path, @bytes)

      # Whether the header checksum and the logo are what the console checks for.
      def valid_header? = @bytes.getbyte(HEADER_CHECKSUM_AT) == header_checksum && logo_intact?

      def logo_intact? = @bytes.byteslice(LOGO_AT, LOGO.size).bytes == LOGO

      private

      # A whole number of banks, a power of two, at least two.
      def padded(bytes)
        size = SMALLEST
        size *= 2 while size < bytes.bytesize
        bytes + ("\xFF".b * (size - bytes.bytesize))
      end

      def write_header(title, save_bytes)
        @bytes[LOGO_AT, LOGO.size] = LOGO.pack("C*")
        @bytes[TITLE_AT, CGB_FLAG_AT - TITLE_AT] = "\0".b * (CGB_FLAG_AT - TITLE_AT)
        @bytes[TITLE_AT, TITLE_LENGTH] = header_title(title)
        @bytes.setbyte(CGB_FLAG_AT, CGB_ONLY)
        @bytes[NEW_LICENSEE_AT, 2] = "00"
        @bytes.setbyte(SGB_FLAG_AT, 0)
        @bytes.setbyte(CARTRIDGE_TYPE_AT, save_bytes.zero? ? MBC5 : MBC5_RAM_BATTERY)
        @bytes.setbyte(ROM_SIZE_AT, Math.log2(@bytes.bytesize / SMALLEST).to_i)
        @bytes.setbyte(RAM_SIZE_AT, RAM_SIZE_CODES.fetch(save_bytes))
        @bytes.setbyte(DESTINATION_AT, 0x01)
        @bytes.setbyte(OLD_LICENSEE_AT, USE_NEW_LICENSEE)
        @bytes.setbyte(VERSION_AT, 0)
        @bytes.setbyte(HEADER_CHECKSUM_AT, header_checksum)
        write_global_checksum
      end

      # Upper-case letters, digits and spaces, as the cartridges of the day wrote them.
      def header_title(title)
        title.to_s.upcase.gsub(/[^A-Z0-9 ]/, " ").byteslice(0, TITLE_LENGTH).b.ljust(TITLE_LENGTH, "\0")
      end

      # What the start-up program checks: every header byte from the title to the version
      # subtracted from nought, one more each time.
      def header_checksum
        (TITLE_AT..VERSION_AT).reduce(0) { |sum, at| (sum - @bytes.getbyte(at) - 1) & 0xFF }
      end

      def write_global_checksum
        @bytes.setbyte(GLOBAL_CHECKSUM_AT, 0)
        @bytes.setbyte(GLOBAL_CHECKSUM_AT + 1, 0)
        sum = @bytes.sum(16) # every byte added, kept to 16 bits
        @bytes.setbyte(GLOBAL_CHECKSUM_AT, sum >> 8)
        @bytes.setbyte(GLOBAL_CHECKSUM_AT + 1, sum & 0xFF)
      end
    end
  end
end
