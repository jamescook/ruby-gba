# frozen_string_literal: true

require_relative "ruby_gba/version"
require_relative "ruby_gba/constants"
require_relative "ruby_gba/color"
require_relative "ruby_gba/sound"
require_relative "ruby_gba/asm"
require_relative "ruby_gba/ir"
require_relative "ruby_gba/rom_validator"
require_relative "ruby_gba/rom"
require_relative "ruby_gba/font"
require_relative "ruby_gba/fonts"
require_relative "ruby_gba/music"
require_relative "ruby_gba/builder"
require_relative "ruby_gba/value"
require_relative "ruby_gba/condition"
require_relative "ruby_gba/branch"
require_relative "ruby_gba/builder/debug"
require_relative "ruby_gba/list"
require_relative "ruby_gba/direction"
require_relative "ruby_gba/grid"
require_relative "ruby_gba/sprite"
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
  # @param validate [Boolean] run the ROM-image validation after build (default: true)
  # @return [RubyGBA::ROM] finalized ROM ready to write
  # +out+/+err+ are the streams dump_func writes its disassembly and warnings to;
  # they default to the process streams and can be pointed at a StringIO in tests.
  def self.build(title, code:, maker:, validate: true, out: $stdout, err: $stderr, &block)
    builder = Builder.new
    catch(:debug_halt) do
      builder.instance_eval(&block)
    end
    builder.emit_pending_functions

    # First prove the tree is well-formed — every value operand is a value node,
    # nothing structural is out of place. This checks the *library's* own
    # consistency, not the developer's game, so a failure is a ruby-gba bug and
    # raises loudly rather than joining the friendly guardrail report below. It
    # runs before the guardrails and the backend so a malformed tree can't reach
    # them and fail cryptically two passes downstream.
    IR::Verifier.verify!(builder.program)

    # Run the guardrails over the finished IR and report every finding — its
    # plain-language explanation and the suggested fix — on the err stream. A
    # warning is advisory (a game loop with no frame sync, say): it's printed and
    # the build goes on. A fatal problem (drawing with no display mode, which
    # would leave the screen black) stops the build so the mistake can't ship
    # silently. Nothing is auto-corrected — the fix is suggested, never applied
    # (an opt-in `--auto-fix` is future work). Skipped for a debug_halt build,
    # whose tree is deliberately truncated.
    unless builder.debug_halted?
      # The default checks — the always-on builtins plus anything registered (an
      # effect pack's own guardrails) — walk the IR. The orphaned-Condition check
      # is appended per build because it reports from the builder's leftover
      # Conditions, not the tree (a native-`if` slip leaves no trace there). All
      # are just checks in the list, so the Validator treats them alike.
      checks = IR::Guardrails.default_checks +
               [IR::Guardrails::Checks::OrphanedCondition.new(builder.pending_conditions)]
      report = IR::Guardrails::Validator.new(checks: checks).run(builder.program, autofix: false)
      report.emit(to: err)
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
                                     validate: builder.debug_halted? ? false : validate)
    rom.source_program = builder.program # so the ROM can report on itself (rom.explain)

    unless builder.dump_requests.empty?
      FuncDumper.new(rom, backend.func_ranges, out: out, err: err).dump(builder.dump_requests)
    end
    rom
  end
end
