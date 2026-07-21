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
        lines << "OK — no issues found" if ok? && warnings.empty?
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
        @errors << "ROM is only #{@buf.bytesize} bytes — minimum valid size is 192 (0xC0) for header"
      end
    end

    def check_fixed_byte
      return if @buf.bytesize <= HEADER_FIXED
      val = @buf.getbyte(HEADER_FIXED)
      if val != 0x96
        @errors << "Fixed byte at 0xB2 is 0x#{format('%02X', val)} — must be 0x96 or BIOS/mGBA will reject the ROM"
      end
    end

    def check_logo
      logo_len = HEADER_LOGO_BYTES.bytesize
      return if @buf.bytesize < HEADER_LOGO + logo_len
      actual = @buf[HEADER_LOGO, logo_len].b
      return if actual == HEADER_LOGO_BYTES

      if actual.each_byte.all?(&:zero?)
        @errors << "Nintendo logo (0x04..0x9F) is all zeros — the BIOS validates it on boot, " \
                   "so the ROM won't run on real hardware or accuracy-focused emulators (mGBA skips the check)"
      else
        @errors << "Nintendo logo (0x04..0x9F) doesn't match the required bytes — " \
                   "the BIOS will reject the ROM on real hardware"
      end
    end

    def check_checksum
      return if @buf.bytesize <= HEADER_CHECKSUM
      stored = @buf.getbyte(HEADER_CHECKSUM)
      sum = (HEADER_TITLE..0xBC).sum { |i| @buf.getbyte(i) }
      expected = (-(sum + 0x19)) & 0xFF
      if stored != expected
        @errors << "Header checksum is 0x#{format('%02X', stored)} — expected 0x#{format('%02X', expected)}. Was finalize! called?"
      end
    end

    def check_entry_branch
      return if @buf.bytesize < 4
      word = @buf[0, 4].unpack1("V")
      cond = (word >> 24) & 0xFF

      unless cond == 0xEA
        @errors << "Entry point at 0x00 is not an unconditional branch (got 0x#{format('%08X', word)}). Missing finalize!?"
        return
      end

      offset = word & 0x00FFFFFF
      offset -= 0x1000000 if offset >= 0x800000
      target = (offset + 2) * 4

      if target < 0xC0
        @errors << "Entry branch jumps to 0x#{format('%02X', target)} — inside the header (before 0xC0). Code will corrupt header data"
      elsif target >= @buf.bytesize
        @errors << "Entry branch jumps to 0x#{format('%X', target)} — beyond end of ROM (#{@buf.bytesize} bytes)"
      end
    end

    def check_code_region
      return if @buf.bytesize <= 0xC0

      # Check if there's any non-zero code after the header
      code_region = @buf[0xC0..]
      if code_region.bytes.all?(&:zero?)
        @warnings << "Code region (0xC0+) is all zeros — ROM has no instructions. Did you forget to add code in the build block?"
      end
    end

    def check_title
      return if @buf.bytesize < HEADER_TITLE + 12
      title = @buf[HEADER_TITLE, 12]
      if title.bytes.all?(&:zero?)
        @warnings << "Game title is empty — ROM will work but won't be identifiable"
      end
    end
  end
end
