# frozen_string_literal: true

require_relative "ruby_gba/version"
require_relative "ruby_gba/constants"
require_relative "ruby_gba/plain_words" # what a person calls this — the English a build says out loud
require_relative "ruby_gba/whole"
require_relative "ruby_gba/color"
require_relative "ruby_gba/sound"
require_relative "ruby_gba/asm"
require_relative "ruby_gba/progress" # what a build says it is doing while it does it
require_relative "ruby_gba/ir"
require_relative "ruby_gba/rom_validator"
require_relative "ruby_gba/build_record" # what the build worked out, for the cartridge to carry
require_relative "ruby_gba/rom"
require_relative "ruby_gba/font"
require_relative "ruby_gba/fonts"
require_relative "ruby_gba/music"
require_relative "ruby_gba/fraction"
require_relative "ruby_gba/builder"
require_relative "ruby_gba/effects" # the verb/effect pack registry, and the packs that ship on by default
require_relative "ruby_gba/evaluated_game" # the one place a game's block becomes a program
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
require_relative "ruby_gba/pager"
require_relative "ruby_gba/test_patterns"
require_relative "ruby_gba/emulator"
require_relative "ruby_gba/verifier"
require_relative "ruby_gba/tearing"
require_relative "ruby_gba/analyzer"
require_relative "ruby_gba/profiler"

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
  # @param progress [RubyGBA::Progress] what the build says it is doing while it does it.
  #   The default says nothing; `Progress.to($stderr)` names each phase and how far it has
  #   got. See {RubyGBA::Progress}.
  # @return [RubyGBA::ROM] finalized ROM ready to write
  # +out+/+err+ are the streams dump_func writes its disassembly and warnings to;
  # they default to the process streams and can be pointed at a StringIO in tests.
  def self.build(title, code:, maker:, validate: true, frame_sync: :auto, fast_cartridge: true,
                 fast_code: true, out: $stdout, err: $stderr, progress: Progress.silent, &block)
    progress.step("reading the game")
    evaluated = EvaluatedGame.new(block, frame_sync: frame_sync, progress: progress)
    program = evaluated.program

    # First prove the tree is well-formed — every value operand is a value node,
    # nothing structural is out of place. This checks the *library's* own
    # consistency, not the developer's game, so a failure is a ruby-gba bug and
    # raises loudly rather than joining the friendly guardrail report below. It
    # runs before the guardrails and the backend so a malformed tree can't reach
    # them and fail cryptically two passes downstream.
    progress.step("checking the tree")
    IR::Verifier.verify!(program)

    # Run the guardrails over the finished IR and collect every finding — its
    # plain-language explanation and the suggested fix. A warning is advisory (a
    # game loop with no frame sync, say): the build goes on. A fatal problem
    # (drawing with no screen mode, which would leave the screen black) stops the
    # build so the mistake can't ship silently. Nothing is auto-corrected — the fix
    # is suggested, never applied (an opt-in `--auto-fix` is future work). Skipped
    # for a debug_halt build, whose tree is deliberately truncated.
    #
    # NOTHING IS PRINTED HERE, and that is the point: the findings are held and
    # written at the end (see the ensure below). A build is a sequence of phases
    # saying how far they have got, and a paragraph of prose landing in the middle
    # of it breaks the sequence in half — the reader loses the shape of the build,
    # and on a terminal the warning lands on the line the phase is still rewriting.
    # A finding is worth reading either way; where it is worth reading is after the
    # build has finished saying what it did.
    unless evaluated.debug_halted?
      progress.step("the guardrails")
      # The default checks — the always-on builtins plus anything registered (an
      # effect pack's own guardrails) — walk the IR. The rest are appended per build
      # because they report from what the run learned rather than from the tree:
      # leftover Conditions (a native-`if` slip leaves no trace there), covered
      # `wait_vblank` calls, and the software sprites, whose layer lives on the handle.
      # All are just checks in the list, so the Validator treats them alike.
      checks = IR::Guardrails.default_checks +
               [IR::Guardrails::Checks::OrphanedCondition.new(evaluated.pending_conditions),
                IR::Guardrails::Checks::DroppedFrameSync.new(evaluated.dropped_syncs),
                IR::Guardrails::Checks::LayerHoldsNothing.new(evaluated.sprites),
                IR::Guardrails::Checks::StackNotHonored.new(evaluated.sprites)]
      findings = IR::Guardrails::Validator.new(checks: checks, progress: progress)
                                          .run(program, autofix: false)
      if findings.errors.any?
        raise ROMError,
              "build stopped by #{findings.errors.size} problem(s) — see the explanation(s) above"
      end
    end

    # The DSL built an IR tree as the block ran. Turn it into a ROM in two steps,
    # both behind this single call so building stays one operation: lower the tree
    # to machine code, then assemble that code into a cartridge. Lowering names its
    # own phases rather than being named from here — most of the time a build spends
    # is in there, and it is three phases, not one (see Placement#choose_fast_funcs).
    backend = IR::Backends::GBA.new(fast_cartridge: fast_cartridge, fast_code: fast_code,
                                    progress: progress)
    machine_code = backend.lower(program)
    record = backend.build_record(program)

    # The guardrails that quote a number run here instead of above, priced with what the
    # build actually decided. See Guardrails.build_checks for why they cannot run earlier.
    # Their findings join the ones from the first pass and print together at the end.
    unless evaluated.debug_halted?
      progress.step("the guardrails that need the build")
      model = IR::CostModel.new(**record.for_cost_model)
      priced = IR::Guardrails::Validator.new(checks: IR::Guardrails.build_checks(model), progress: progress)
                                        .run(program, autofix: false)
      findings = findings.with(findings: findings.findings + priced.findings)
    end
    # The findings ride on the record too, so a report asked for as data carries them.
    record = record.with(findings: findings.findings) if findings

    progress.step("assembling the cartridge")
    # The cartridge carries what the build worked out about it — the program it came from,
    # which routines went in the console's quick memory, where the variables landed, and so
    # on — so that a finished ROM can report on itself (see BuildRecord and rom.explain).
    # None of it is in the bytes, and nothing can recover it by reading them back.
    rom = ROM.assemble(machine_code, title: title, code: code, maker: maker,
                                     validate: evaluated.debug_halted? ? false : validate,
                                     built: record)

    # Every phase is over; a disassembly dump is a debugging aid, not a phase.
    progress.done
    unless evaluated.dump_requests.empty?
      FuncDumper.new(rom, backend.func_ranges, out: out, err: err).dump(evaluated.dump_requests)
    end
    rom
  ensure
    # HOWEVER THE BUILD ENDED: close the line, then say what the guardrails found.
    #
    # In that order, and both here rather than where they happen. A live progress line is held
    # open and rewritten in place, so anything printed while one is open lands in the middle of
    # it — and a build that stops half way through a phase (a guardrail error, a routine that
    # will not fit) has a message to print. Putting the findings here too is what keeps them
    # after the whole run of phases instead of splitting it: they are read once the build has
    # finished telling you what it did. On the way out of an error this still runs first, so a
    # reader sees the explanation and then the line saying the build stopped.
    progress.done
    findings&.emit(to: err)
  end
end
