# frozen_string_literal: true

module RubyGBA
  # Manages a raw GBA ROM byte buffer and writes the cartridge header.
  #
  # All offsets reference constants from {RubyGBA::Constants} — no magic
  # numbers in the logic. This makes it easy to sanity-check header writes
  # and catch offset mistakes early.
  #
  # Reference: https://problemkaputt.de/gbatek-gba-cartridge-header.htm
  class ROM
    include Constants

    HEADER_SIZE  = 0xC0
    ENTRY_OFFSET = HEADER_SIZE  # code starts after the full header
    TITLE_LENGTH = 12
    CODE_LENGTH  = 4
    MAKER_LENGTH = 2
    FIXED_VALUE  = 0x96
    CHECKSUM_RANGE = (HEADER_TITLE..0xBC).freeze

    attr_reader :buffer, :code_offset

    # Package finished machine code into a cartridge: write the header, drop the
    # code in after it, and finalize (entry branch, checksum, power-of-two
    # padding, and the ROM-image validation). This is the counterpart to a
    # backend's lowering — the backend produces the code, this lays out the ROM
    # around it.
    def self.assemble(machine_code, title:, code:, maker:, doctor: true)
      rom = new(title: title, code: code, maker: maker)
      rom.emit(machine_code)
      rom.finalize!(doctor: doctor)
      rom
    end

    def initialize(title:, code:, maker:)
      @buffer = ("\x00".b) * [512, HEADER_SIZE].max
      @code_offset = ENTRY_OFFSET

      write_logo
      write_title(title)
      write_code(code)
      write_maker(maker)
      @buffer.setbyte(HEADER_FIXED, FIXED_VALUE)
    end

    # Append raw bytes at the current code offset and advance.
    def emit(bytes)
      grow_if_needed(@code_offset + bytes.bytesize)
      @buffer[@code_offset, bytes.bytesize] = bytes
      @code_offset += bytes.bytesize
    end

    # Overwrite bytes at a specific offset (for patching branch placeholders).
    def patch(offset, bytes)
      @buffer[offset, bytes.bytesize] = bytes
    end

    # Finalize the ROM: write entry branch, header checksum, and validate.
    #
    # @param doctor [Boolean] run the ROM-image validation (structural header /
    #   image checks) after finalizing (default: true). Raises ROMError on a
    #   structural problem. Pass false to skip.
    def finalize!(doctor: true)
      # Entry point at 0x00: branch to ENTRY_OFFSET
      # Branch offset in words from PC+8: (target - 8) / 4 = (0x20 - 8) / 4 = 6
      entry_branch = [0xEA000000 | ((ENTRY_OFFSET / 4) - 2)].pack("V")
      @buffer[HEADER_ENTRY, 4] = entry_branch

      # Complement checksum over HEADER_TITLE..0xBC
      sum = CHECKSUM_RANGE.sum { |i| @buffer.getbyte(i) }
      @buffer.setbyte(HEADER_CHECKSUM, (-(sum + 0x19)) & 0xFF)

      # Real GBA cartridges are power-of-two sized. Pad up to the next one with
      # zeros — it's past the checksum range, so this is free, and it keeps the
      # ROM conventional for flashcarts and real-cart mastering.
      pad_to_power_of_two

      # Validate the finished ROM image — catch structural problems now, not in
      # the emulator. (Semantic footguns are caught earlier, on the IR, by the
      # guardrails.)
      if doctor
        result = ROMValidator.check(self)
        unless result.ok?
          raise ROMError, "ROM has errors:\n#{result.report}"
        end
      end
    end

    # Write the ROM to a file.
    def write(path)
      File.binwrite(path, @buffer)
    end

    # ROM size in bytes.
    def size
      @buffer.bytesize
    end

    private

    # The GBA BIOS validates the 156-byte Nintendo logo at 0x04..0x9F on boot.
    # It sits outside the header checksum range (0xA0..0xBC), so writing it here
    # doesn't affect the checksum computed in finalize!.
    def write_logo
      @buffer[HEADER_LOGO, HEADER_LOGO_BYTES.bytesize] = HEADER_LOGO_BYTES
    end

    def write_title(title)
      padded = title[0, TITLE_LENGTH].ljust(TITLE_LENGTH, "\x00")
      @buffer[HEADER_TITLE, TITLE_LENGTH] = padded
    end

    def write_code(code)
      raise ArgumentError, "game code must be #{CODE_LENGTH} chars" unless code.bytesize == CODE_LENGTH
      @buffer[HEADER_CODE, CODE_LENGTH] = code
    end

    def write_maker(maker)
      raise ArgumentError, "maker code must be #{MAKER_LENGTH} chars" unless maker.bytesize == MAKER_LENGTH
      @buffer[HEADER_MAKER, MAKER_LENGTH] = maker
    end

    def grow_if_needed(min_size)
      return if @buffer.bytesize >= min_size
      new_size = [@buffer.bytesize * 2, min_size].max
      @buffer << ("\x00".b) * (new_size - @buffer.bytesize)
    end

    def pad_to_power_of_two
      target = next_power_of_two(@buffer.bytesize)
      @buffer << ("\x00".b) * (target - @buffer.bytesize) if target > @buffer.bytesize
    end

    # The smallest power of two >= n (found by shifting, so no float rounding).
    def next_power_of_two(n)
      power = 1
      power <<= 1 while power < n
      power
    end
  end
end
