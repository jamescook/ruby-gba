# frozen_string_literal: true

require "json"

module VBlank
  module Cartridge
    # A SUPER NINTENDO CARTRIDGE: the banks the SNES lowering linked, laid out the LoROM way, with
    # the header and vectors the console reads.
    #
    # The header sits at $FFC0 of the first bank, which in a LoROM file is offset $7FC0: a title of
    # 21 characters, the map mode (how the cartridge's bytes are laid out in the processor's view:
    # LoROM, read at the faster speed), the kind of cartridge (ROM alone, or with battery-backed
    # RAM for saves), how big the ROM and that RAM are (each as 2^n kilobytes), the region, the
    # maker and version, and a checksum: every byte of the cartridge added up, kept to 16 bits,
    # beside its complement. The console itself checks none of it; emulators and flash carts read
    # it to tell how to run the cartridge.
    #
    # After the header come the vectors, the 16-bit addresses in bank $00 where the processor goes
    # when it starts (reset) and when an interrupt comes. The processor starts in its 6502
    # emulation mode, so reset is the emulation one; the game switches to native mode at once, and
    # the vertical blank's interrupt (NMI) and the rest are the native ones from then on.
    #
    # No chip of any kind: no Super FX, SA-1, DSP or MSU-1. A cartridge with one would say so in
    # the cartridge type byte and be laid out for it.
    #
    # Reference: https://problemkaputt.de/fullsnes.htm#snescartridgeromheader
    class SNESROM
      include Console::SNESHardware

      SMALLEST = 0x8000

      # The native vectors, and the emulation ones, by the name the lowering gives them.
      VECTORS = { cop: NATIVE_COP_VECTOR, brk: NATIVE_BRK_VECTOR, abort: NATIVE_ABORT_VECTOR, nmi: NATIVE_NMI_VECTOR,
                  irq: NATIVE_IRQ_VECTOR, emulation_cop: EMULATION_COP_VECTOR, emulation_abort: EMULATION_ABORT_VECTOR,
                  emulation_nmi: EMULATION_NMI_VECTOR, reset: RESET_VECTOR,
                  emulation_irq: EMULATION_IRQ_VECTOR }.freeze

      attr_reader :bytes

      # What the build worked out about the cartridge, for the tools that read a running one
      # back, or nil.
      attr_reader :built

      # +banks+ is the linked cartridge, its first 32K first. +vectors+ names where each vector
      # points, by VECTORS's names; one not named points where reset does.
      # +save_bytes+ is how much battery-backed RAM it has, a power of two from 2K, or nought.
      def initialize(banks, title:, vectors:, save_bytes: 0, built: nil)
        @built = built
        unless save_bytes.zero? || (save_bytes >= 0x800 && (save_bytes & (save_bytes - 1)).zero?)
          raise ArgumentError, "a Super Nintendo cartridge keeps a power of two from 2K of save RAM, not #{save_bytes} bytes"
        end

        @bytes = padded(banks.join.b)
        write_header(title, save_bytes)
        write_vectors(vectors)
        write_checksum
      end

      def size = @bytes.bytesize

      # The console a cartridge of this kind is for; whether +bytes+ are one (a header whose
      # checksum and complement agree, and which says LoROM); and its title field.
      def self.console = :snes

      def self.header?(bytes)
        return false if bytes.bytesize < SMALLEST

        checksum, complement = bytes.byteslice(COMPLEMENT_AT, 4).unpack("v2").reverse
        (checksum ^ complement) == 0xFFFF && (bytes.getbyte(MAP_MODE_AT) & 0xEF) == 0x20
      end

      def self.title_field_of(bytes) = bytes.byteslice(TITLE_AT, TITLE_LENGTH)

      def console = self.class.console
      def header_title = self.class.title_field_of(@bytes)
      alias buffer bytes
      def var_addresses = @built&.variables
      def source_program = @built&.source_program

      # The game's title as the header holds it.
      def title = header_title.rstrip

      def write(path) = ROM.write_bytes(path, @bytes)

      # A Super Nintendo cartridge cannot be profiled yet.
      def profile(**)
        raise ArgumentError, "a Super Nintendo cartridge cannot be profiled yet. Profile the game's Game Boy " \
                             "Advance cartridge."
      end

      private

      # A whole number of 32K banks, a power of two of them.
      def padded(bytes)
        size = SMALLEST
        size *= 2 while size < bytes.bytesize
        bytes + ("\xFF".b * (size - bytes.bytesize))
      end

      def write_header(title, save_bytes)
        @bytes[TITLE_AT, TITLE_LENGTH] = title_field_for(title)
        @bytes.setbyte(MAP_MODE_AT, LOROM_FAST)
        @bytes.setbyte(CARTRIDGE_TYPE_AT, save_bytes.zero? ? ROM_ONLY : ROM_RAM_BATTERY)
        @bytes.setbyte(ROM_SIZE_AT, kilobyte_power(@bytes.bytesize))
        @bytes.setbyte(RAM_SIZE_AT, save_bytes.zero? ? 0 : kilobyte_power(save_bytes))
        @bytes.setbyte(DESTINATION_AT, NORTH_AMERICA)
        @bytes.setbyte(MAKER_AT, 0)
        @bytes.setbyte(VERSION_AT, 0)
      end

      def kilobyte_power(bytes) = Math.log2(bytes / 1024).to_i

      # Upper-case letters, digits and spaces, padded with spaces, as the cartridges of the day.
      def title_field_for(title)
        title.to_s.upcase.gsub(/[^A-Z0-9 ]/, " ").byteslice(0, TITLE_LENGTH).b.ljust(TITLE_LENGTH, " ")
      end

      def write_vectors(vectors)
        unknown = vectors.keys - VECTORS.keys
        raise ArgumentError, "a Super Nintendo has no #{unknown.join(', ')} vector" unless unknown.empty?

        reset = vectors.fetch(:reset)
        VECTORS.each do |name, at|
          @bytes[at - 0x8000, 2] = [vectors.fetch(name, reset) & 0xFFFF].pack("v")
        end
      end

      # Every byte added, with the checksum's own four bytes taken as $FFFF and $0000, which add
      # to what any checksum and its complement add to.
      def write_checksum
        @bytes[COMPLEMENT_AT, 4] = [0xFFFF, 0x0000].pack("v2")
        sum = @bytes.sum(16)
        @bytes[COMPLEMENT_AT, 4] = [sum ^ 0xFFFF, sum].pack("v2")
      end
    end
  end
end
