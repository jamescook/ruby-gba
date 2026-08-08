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
require_relative "ruby_gba/fraction"
require_relative "ruby_gba/builder"
require_relative "ruby_gba/effects" # the verb/effect pack registry, and the packs that ship on by default
require_relative "ruby_gba/game"
require_relative "ruby_gba/value"
require_relative "ruby_gba/condition"
require_relative "ruby_gba/branch"
require_relative "ruby_gba/bounds"
require_relative "ruby_gba/pixel_bounds"
require_relative "ruby_gba/box"
require_relative "ruby_gba/builder/debug"
require_relative "ruby_gba/list"
require_relative "ruby_gba/table"
require_relative "ruby_gba/field_ref"
require_relative "ruby_gba/pool"
require_relative "ruby_gba/direction"
require_relative "ruby_gba/grid"
require_relative "ruby_gba/sprite"
require_relative "ruby_gba/hardware_sprite"
require_relative "ruby_gba/timer"
require_relative "ruby_gba/sample"
require_relative "ruby_gba/instrument"
require_relative "ruby_gba/wav"
require_relative "ruby_gba/background"
require_relative "ruby_gba/image"
require_relative "ruby_gba/aseprite"
require_relative "ruby_gba/inspector"
require_relative "ruby_gba/func_dumper"
require_relative "ruby_gba/test_patterns"
require_relative "ruby_gba/emulator"
require_relative "ruby_gba/verifier"
require_relative "ruby_gba/analyzer"

module RubyGBA
  class ROMError < StandardError; end
  # Build a GBA ROM using the DSL.
  #
  # @param title [String] Game title (up to 12 chars)
  # @param code [String] 4-char game code (e.g. "BTKE")
  # @param maker [String] 2-char maker code (e.g. "01")
  # @param validate [Boolean] run the ROM-image validation after build (default: true)
  # @param fast_cartridge [Boolean] ask the console for quick cartridge timing at boot
  #   (default: true). Pass false to leave the cautious power-on timing alone — the
  #   escape hatch for a cartridge that can't keep up.
  # @param fast_code [Boolean] let the build work out which routines are worth keeping
  #   in the console's quick memory, where code runs about two and a half times faster
  #   (default: true). `rom.explain` says what it chose. Pass false to stop it choosing —
  #   a routine you mark `func :name, fast: true` yourself still goes there.
  # @return [RubyGBA::ROM] finalized ROM ready to write
  # +out+/+err+ are the streams dump_func writes its disassembly and warnings to;
  # they default to the process streams and can be pointed at a StringIO in tests.
  def self.build(title, code:, maker:, validate: true, frame_sync: :auto, fast_cartridge: true,
                 fast_code: true, out: $stdout, err: $stderr, &block)
    builder = Builder.new(frame_sync: frame_sync)
    catch(:debug_halt) do
      builder.instance_eval(&block)
    end
    # Finalizing the tree is also what paces it: `game_loop` runs once per frame and
    # the builder writes that wait itself, so nothing below has to think about it.
    builder.emit_pending_functions
    program = builder.program

    # First prove the tree is well-formed — every value operand is a value node,
    # nothing structural is out of place. This checks the *library's* own
    # consistency, not the developer's game, so a failure is a ruby-gba bug and
    # raises loudly rather than joining the friendly guardrail report below. It
    # runs before the guardrails and the backend so a malformed tree can't reach
    # them and fail cryptically two passes downstream.
    IR::Verifier.verify!(program)

    # Run the guardrails over the finished IR and report every finding — its
    # plain-language explanation and the suggested fix — on the err stream. A
    # warning is advisory (a game loop with no frame sync, say): it's printed and
    # the build goes on. A fatal problem (drawing with no screen mode, which
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
               [IR::Guardrails::Checks::OrphanedCondition.new(builder.pending_conditions),
                IR::Guardrails::Checks::DroppedFrameSync.new(builder.dropped_syncs)]
      report = IR::Guardrails::Validator.new(checks: checks).run(program, autofix: false)
      report.emit(to: err)
      if report.errors.any?
        raise ROMError,
              "build stopped by #{report.errors.size} problem(s) — see the explanation(s) above"
      end
    end

    # The DSL built an IR tree as the block ran. Turn it into a ROM in two steps,
    # both behind this single call so building stays one operation: lower the tree
    # to machine code, then assemble that code into a cartridge.
    backend = IR::Backends::GBA.new(fast_cartridge: fast_cartridge, fast_code: fast_code)
    machine_code = backend.lower(program)
    rom = ROM.assemble(machine_code, title: title, code: code, maker: maker,
                                     validate: builder.debug_halted? ? false : validate)
    rom.source_program = program # so the ROM can report on itself (rom.explain)
    rom.placement = backend.iwram_report # ...including which routines it kept in quick memory

    # Record how far asset packing shrank the cart (tile pictures, palettes, maps) so
    # a caller can read it back or a verbose build can show it. Building it into the
    # library's output is a presentation choice that belongs to the CLI, not here — a
    # plain build stays quiet.
    rom.compression = backend.compression_report

    unless builder.dump_requests.empty?
      FuncDumper.new(rom, backend.func_ranges, out: out, err: err).dump(builder.dump_requests)
    end
    rom
  end
end
