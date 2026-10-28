# frozen_string_literal: true

require "json"

module VBlank
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
    # The cartridge has an MBC5, or with +clock+ an MBC3 and the clock chip beside it, as the
    # console's own games with a clock had (Pokemon Gold, Silver and Crystal): the two switch banks
    # the same way as far as this runtime drives them, the MBC3 over fewer of them
    # (GBC::Linker::MOST_CLOCK_BANKS). With +save_bytes+ it also has battery-backed memory, the kind
    # a save is kept in: 8K, or 32K in four banks. Without, it has none, and a clock still has a
    # battery of its own.
    #
    # Reference: https://gbdev.io/pandocs/The_Cartridge_Header.html
    class GBCROM
      include Console::GBCHardware

      TITLE_LENGTH = 11

      # The ROM size byte names a size of 32K × 2^n.
      SMALLEST = 0x8000

      # The RAM size byte, by the memory a save needs.
      RAM_SIZE_CODES = { 0 => 0x00, 0x2000 => 0x02, 0x8000 => 0x03 }.freeze

      # The cartridge type byte, by whether it has a clock chip and whether it has battery-backed
      # memory: an MBC5 alone or with that memory, or an MBC3 with its clock (a "timer") and the
      # battery that keeps it, with that memory or without.
      MBC5 = 0x19
      MBC3_TIMER_BATTERY = 0x0F
      MBC3_TIMER_RAM_BATTERY = 0x10
      CARTRIDGE_TYPES = Ractor.make_shareable({ [false, false] => MBC5, [false, true] => MBC5_RAM_BATTERY,
                                                [true, false] => MBC3_TIMER_BATTERY,
                                                [true, true] => MBC3_TIMER_RAM_BATTERY })

      # ...and an MBC5 with a rumble motor (Runtime::Rumble), by whether it has that memory.
      MBC5_RUMBLE = 0x1C
      MBC5_RUMBLE_RAM_BATTERY = 0x1E
      RUMBLE_TYPES = Ractor.make_shareable({ false => MBC5_RUMBLE, true => MBC5_RUMBLE_RAM_BATTERY })

      attr_reader :bytes

      # What the build worked out about the cartridge (where its variables are, the program it
      # came from), for the tools that read a running one back, or nil.
      attr_reader :built

      # +banks+ is the linked cartridge, bank 0 first, each 16K. +rumble+ says it carries a motor.
      def initialize(banks, title:, save_bytes: 0, clock: false, rumble: false, built: nil)
        @built = built
        unless RAM_SIZE_CODES.key?(save_bytes)
          raise ArgumentError, "a Game Boy Color cartridge here keeps 0, 8K or 32K of save memory, not #{save_bytes} bytes"
        end
        raise ArgumentError, "a Game Boy Color cartridge with a clock has no rumble motor" if clock && rumble

        @bytes = padded(banks.join.b)
        write_header(title, save_bytes, clock, rumble)
      end

      def size = @bytes.bytesize

      # Whether its header says it carries a clock chip.
      def clock? = [MBC3_TIMER_BATTERY, MBC3_TIMER_RAM_BATTERY].include?(@bytes.getbyte(CARTRIDGE_TYPE_AT))

      # WHAT EVERY GAME BOY CARTRIDGE'S HEADER SAYS, the Color's too, whoever made it — asked of a
      # cartridge file too (Diagnostics::CartridgeFile), which has nothing but its bytes.
      #
      # The console a cartridge of this kind is for; whether +bytes+ are one (every Game Boy
      # cartridge carries the logo the console's start-up program compares before it will start
      # one); and the title field of its header, eleven bytes padded with noughts.
      def self.console = :gbc
      def self.header?(bytes) = bytes.byteslice(LOGO_AT, LOGO.size)&.bytes == LOGO
      def self.title_field_of(bytes) = bytes.byteslice(TITLE_AT, TITLE_LENGTH)

      # What a reader over a running cartridge asks of any cartridge, the Advance's as well:
      # which console it is for, its title, its bytes, where the build put its variables, and
      # the program it was built from.
      def console = self.class.console
      def header_title = self.class.title_field_of(@bytes)
      alias buffer bytes
      def var_addresses = @built&.variables
      def source_program = @built&.source_program

      # The game's title as the header holds it.
      def title = header_title.delete("\0")

      def write(path) = ROM.write_bytes(path, @bytes)

      # WHERE ITS FRAMES WENT: the cartridge run in the emulator (Diagnostics::GBCProfiler), reported
      # for a person or as JSON. +keys+ are held from power-on, and +settle+ frames run before the
      # +frames+ measured. The Advance's profile can be told a scene or a saved moment to measure;
      # the Color's cannot yet, and says so.
      def profile(format: :human, out: $stdout, frames: Diagnostics::GBCProfiler::FRAMES,
                  settle: Diagnostics::GBCProfiler::SETTLE, keys: [], scene: nil, from: nil)
        if scene || from
          raise ArgumentError, "a Game Boy Color profile measures the game as it plays from power-on, and cannot be " \
                               "told a #{scene ? 'scene' : 'saved moment'} yet. To fix this, leave out " \
                               "#{scene ? '--scene' : '--from'}, and use --keys and --settle to reach the moment."
        end

        result = Diagnostics::GBCProfiler.run(self, frames: frames, settle: settle, keys: keys)
        case format
        when :human then Diagnostics::GBCProfiler.render(result, out: out)
        when :json then out.puts(JSON.generate(result.to_h))
        else raise ArgumentError, "unknown profile format #{format.inspect} (use :human or :json)"
        end
        result
      end

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

      def write_header(title, save_bytes, clock, rumble)
        @bytes[LOGO_AT, LOGO.size] = LOGO.pack("C*")
        @bytes[TITLE_AT, CGB_FLAG_AT - TITLE_AT] = "\0".b * (CGB_FLAG_AT - TITLE_AT)
        @bytes[TITLE_AT, TITLE_LENGTH] = title_field_for(title)
        @bytes.setbyte(CGB_FLAG_AT, CGB_ONLY)
        @bytes[NEW_LICENSEE_AT, 2] = "00"
        @bytes.setbyte(SGB_FLAG_AT, 0)
        kind = rumble ? RUMBLE_TYPES.fetch(!save_bytes.zero?) : CARTRIDGE_TYPES.fetch([clock, !save_bytes.zero?])
        @bytes.setbyte(CARTRIDGE_TYPE_AT, kind)
        @bytes.setbyte(ROM_SIZE_AT, Math.log2(@bytes.bytesize / SMALLEST).to_i)
        @bytes.setbyte(RAM_SIZE_AT, RAM_SIZE_CODES.fetch(save_bytes))
        @bytes.setbyte(DESTINATION_AT, 0x01)
        @bytes.setbyte(OLD_LICENSEE_AT, USE_NEW_LICENSEE)
        @bytes.setbyte(VERSION_AT, 0)
        @bytes.setbyte(HEADER_CHECKSUM_AT, header_checksum)
        write_global_checksum
      end

      # Upper-case letters, digits and spaces, as the cartridges of the day wrote them.
      def title_field_for(title)
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
