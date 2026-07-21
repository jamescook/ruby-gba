# frozen_string_literal: true

require_relative "ruby_gba/version"
require_relative "ruby_gba/constants"
require_relative "ruby_gba/color"
require_relative "ruby_gba/sound"
require_relative "ruby_gba/asm"
require_relative "ruby_gba/ir"
require_relative "ruby_gba/doctor"
require_relative "ruby_gba/rom"
require_relative "ruby_gba/font"
require_relative "ruby_gba/music"
require_relative "ruby_gba/builder"
require_relative "ruby_gba/expression"
require_relative "ruby_gba/image"
require_relative "ruby_gba/inspector"
require_relative "ruby_gba/func_dumper"
require_relative "ruby_gba/test_patterns"
require_relative "ruby_gba/verifier"

module RubyGBA
  class ROMError < StandardError; end
  # Build a GBA ROM using the DSL.
  #
  # @param title [String] Game title (up to 12 chars)
  # @param code [String] 4-char game code (e.g. "BTKE")
  # @param maker [String] 2-char maker code (e.g. "01")
  # @param doctor [Boolean] run Doctor validation after build (default: true)
  # @return [RubyGBA::ROM] finalized ROM ready to write
  # +out+/+err+ are the streams dump_func writes its disassembly and warnings to;
  # they default to the process streams and can be pointed at a StringIO in tests.
  def self.build(title, code:, maker:, doctor: true, out: $stdout, err: $stderr, &block)
    builder = Builder.new
    catch(:debug_halt) do
      builder.instance_eval(&block)
    end
    builder.emit_pending_functions

    # Run the guardrails over the finished IR and report every finding — its
    # plain-language explanation and the suggested fix — on the err stream. A
    # warning is advisory (a game loop with no frame sync, say): it's printed and
    # the build goes on. A fatal problem (drawing with no display mode, which
    # would leave the screen black) stops the build so the mistake can't ship
    # silently. Nothing is auto-corrected — the fix is suggested, never applied
    # (an opt-in `--auto-fix` is future work). Skipped for a debug_halt build,
    # whose tree is deliberately truncated.
    unless builder.debug_halted?
      report = IR::Guardrails::Validator.new.run(builder.program, autofix: false)
      report.findings.each { |finding| err.puts(finding.message) }
      if report.errors.any?
        raise ROMError,
              "build stopped by #{report.errors.size} problem(s) — see the explanation(s) above"
      end
    end

    # The DSL built an IR tree as the block ran. Turn it into a ROM in two steps,
    # both behind this single call so building stays one operation: lower the tree
    # to machine code, then assemble that code into a cartridge.
    backend = IR::Backends::GBA.new
    machine_code = backend.lower(builder.program)
    rom = ROM.assemble(machine_code, title: title, code: code, maker: maker,
                                     doctor: builder.debug_halted? ? false : doctor)

    unless builder.dump_requests.empty?
      FuncDumper.new(rom, backend.func_ranges, out: out, err: err).dump(builder.dump_requests)
    end
    rom
  end
end
