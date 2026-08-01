# frozen_string_literal: true

module RubyGBA
  # Validates a finished ROM image — the raw cartridge bytes — for the structural
  # problems that make the BIOS or an accurate emulator reject it or misread its
  # header: too small, a wrong fixed byte or Nintendo logo, a bad header checksum,
  # an entry branch that doesn't point at the code, no code at all, an empty title.
  #
  # These checks only make sense AFTER lowering, once there's a real ROM to look
  # at, so they run at finalization — unlike the IR guardrails, which reason about
  # the program before any bytes exist. An error means the ROM won't run; a
  # warning means it runs but something's off.
  #
  # @example
  #   result = RubyGBA::ROMValidator.check(rom)
  #   result.ok? # => true if no errors
  class ROMValidator
    include Constants

    Result = Struct.new(:errors, :warnings) do
      def ok?
        errors.empty?
      end

      def report
        lines = []
        errors.each { |e| lines << "ERROR:   #{e}" }
        warnings.each { |w| lines << "WARNING: #{w}" }
        lines << "OK. No issues found." if ok? && warnings.empty?
        lines.join("\n")
      end
    end

    # Check a ROM object.
    # @param rom [RubyGBA::ROM] a finalized ROM
    # @return [Result]
    def self.check(rom)
      new(rom.buffer).run
    end

    # Check a .gba file on disk.
    # @param path [String] path to a .gba file
    # @return [Result]
    def self.check_file(path)
      new(File.binread(path)).run
    end

    def initialize(buffer)
      @buf = buffer
      @errors = []
      @warnings = []
    end

    def run
      check_minimum_size
      check_fixed_byte
      check_logo
      check_checksum
      check_entry_branch
      check_code_region
      check_title
      Result.new(@errors, @warnings)
    end

    private

    def check_minimum_size
      if @buf.bytesize < 0xC0
        @errors << "The ROM is only #{@buf.bytesize} bytes. The minimum valid size is 192 bytes (0xC0) for the header. Make the ROM 192 bytes or larger."
      end
    end

    def check_fixed_byte
      return if @buf.bytesize <= HEADER_FIXED
      val = @buf.getbyte(HEADER_FIXED)
      if val != 0x96
        @errors << "The fixed byte at 0xB2 is 0x#{format('%02X', val)}. This byte must be 0x96. If this byte is not 0x96, the BIOS and mGBA reject the ROM."
      end
    end

    def check_logo
      logo_len = HEADER_LOGO_BYTES.bytesize
      return if @buf.bytesize < HEADER_LOGO + logo_len
      actual = @buf[HEADER_LOGO, logo_len].b
      return if actual == HEADER_LOGO_BYTES

      if actual.each_byte.all?(&:zero?)
        @errors << "The Nintendo logo (0x04..0x9F) is all zeros. The BIOS checks this logo at boot. " \
                   "If the logo is wrong, the ROM does not run on real hardware or on accurate emulators. mGBA does not check the logo."
      else
        @errors << "The Nintendo logo (0x04..0x9F) does not match the required bytes. " \
                   "The BIOS rejects the ROM on real hardware."
      end
    end

    def check_checksum
      return if @buf.bytesize <= HEADER_CHECKSUM
      stored = @buf.getbyte(HEADER_CHECKSUM)
      sum = (HEADER_TITLE..0xBC).sum { |i| @buf.getbyte(i) }
      expected = (-(sum + 0x19)) & 0xFF
      if stored != expected
        @errors << "The header checksum is 0x#{format('%02X', stored)}. The correct value is 0x#{format('%02X', expected)}. Make sure finalize! is called."
      end
    end

    def check_entry_branch
      return if @buf.bytesize < 4
      word = @buf[0, 4].unpack1("V")
      cond = (word >> 24) & 0xFF

      unless cond == 0xEA
        @errors << "The entry point at 0x00 is not an unconditional branch. The value there is 0x#{format('%08X', word)}. Make sure finalize! is called."
        return
      end

      offset = word & 0x00FFFFFF
      offset -= 0x1000000 if offset >= 0x800000
      target = (offset + 2) * 4

      if target < 0xC0
        @errors << "The entry branch jumps to 0x#{format('%02X', target)}. This address is inside the header (before 0xC0). The code corrupts the header data at this address."
      elsif target >= @buf.bytesize
        @errors << "The entry branch jumps to 0x#{format('%X', target)}. This address is beyond the end of the ROM (#{@buf.bytesize} bytes)."
      end
    end

    def check_code_region
      return if @buf.bytesize <= 0xC0

      # Check if there's any non-zero code after the header
      code_region = @buf[0xC0..]
      if code_region.bytes.all?(&:zero?)
        @warnings << "The code region (0xC0+) is all zeros. The ROM has no instructions. Add code in the build block."
      end
    end

    def check_title
      return if @buf.bytesize < HEADER_TITLE + 12
      title = @buf[HEADER_TITLE, 12]
      if title.bytes.all?(&:zero?)
        @warnings << "The game title is empty. The ROM works, but nothing identifies it by name."
      end
    end
  end
end
