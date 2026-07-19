# frozen_string_literal: true

module RubyGBA
  # Disassembles specific lowered functions out of a finished ROM and writes the
  # listing to an output stream — the machinery behind dump_func. It shows the
  # machine code the lowering actually produced, which is the one thing the IR,
  # being target-agnostic, can't reveal. The ROM, the function spans, and the
  # streams are all injected, so it's straightforward to drive from a test with a
  # StringIO.
  class FuncDumper
    # @param rom [ROM] the assembled ROM whose code to read
    # @param func_ranges [Hash{Symbol=>Range}] function name => byte span within
    #   the code, relative to the code start (as the GBA backend records it)
    # @param out [IO] where the disassembly is written
    # @param err [IO] where an unknown-function warning is written
    def initialize(rom, func_ranges, out: $stdout, err: $stderr)
      @rom = rom
      @func_ranges = func_ranges
      @out = out
      @err = err
      @inspector = Inspector.from_rom(rom)
    end

    # Dump each named function. A scene is a function named _scene_<name>, so a
    # bare scene name resolves to that.
    def dump(names)
      names.each { |name| dump_one(name) }
    end

    private

    def dump_one(name)
      actual = @func_ranges.key?(name) ? name : :"_scene_#{name}"
      range = @func_ranges[actual]
      return @err.puts("[dump_func] :#{name} not found or not emitted") unless range

      @out.puts(header(actual, range))
      disassemble(range).each { |line| @out.puts(line) }
    end

    def header(name, range)
      first = ROM::ENTRY_OFFSET + range.begin
      last = ROM::ENTRY_OFFSET + range.end
      "=== func :#{name} (0x#{format('%04X', first)}..0x#{format('%04X', last)}) ==="
    end

    def disassemble(range)
      regs = Array.new(16, 0)
      range.step(4).map do |code_offset|
        rom_offset = ROM::ENTRY_OFFSET + code_offset
        inst = @rom.buffer[rom_offset, 4].unpack1("V")
        desc, regs = @inspector.send(:disassemble, inst, regs)
        format("  0x%04X: %s", rom_offset, desc)
      end
    end
  end
end
