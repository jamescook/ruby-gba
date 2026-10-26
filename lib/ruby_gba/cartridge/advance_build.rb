# frozen_string_literal: true

module RubyGBA
  module Cartridge
    # THE GAME BOY ADVANCE'S CARTRIDGE, from a checked program (see Console::AdvanceKit): lowered
    # to ARM by IR::Backends::GBA, checked again for what the lowering decided, and assembled.
    module AdvanceBuild
      module_function

      # The cartridge for +request+ (a Cartridge::BuildRequest), with the findings of the
      # guardrails that read the build's own decisions added to the request's.
      def build(request)
        program = request.program
        evaluated = request.evaluated
        # The DSL built an IR tree as the block ran. Turn it into a ROM in two steps, both behind
        # this single call so building stays one operation: lower the tree to machine code, then
        # assemble that code into a cartridge. Lowering names its own phases rather than being
        # named from here — most of the time a build spends is in there, and it is three phases,
        # not one (see Placement#choose_fast_funcs).
        measured = load_routine_profile(request.profile, program, request.err)
        backend = IR::Backends::GBA.new(**request.options.lowering, progress: request.progress,
                                                                    routine_profile: measured)
        machine_code = backend.lower(program)
        record = backend.build_record(program)

        # The guardrail that reads a decision the build made runs here instead of with the rest,
        # because the decision does not exist until the build has made it. Its findings join the
        # ones from the first pass and print together at the end.
        unless evaluated.debug_halted?
          request.progress.step("the guardrails that need the build")
          checks = IR::Guardrails.build_checks(record.placement)
          priced = IR::Guardrails::Validator.new(checks: checks, progress: request.progress)
                                            .run(program, autofix: false)
          request.findings = request.findings.with(findings: request.findings.findings + priced.findings)
        end
        # The findings ride on the record too, so a report asked for as data carries them.
        record = record.with(findings: request.findings.findings) if request.findings

        request.progress.step("assembling the cartridge")
        # The cartridge carries what the build worked out about it — the program it came from,
        # which routines went in the console's quick memory, where the variables landed, and so
        # on — so that a finished ROM can report on itself (see BuildRecord and rom.profile).
        # None of it is in the bytes, and nothing can recover it by reading them back.
        rom = ROM.assemble(machine_code, title: request.title, code: request.code, maker: request.maker,
                                         validate: evaluated.debug_halted? ? false : request.validate,
                                         built: record)

        # Every phase is over; a disassembly dump is a debugging aid, not a phase.
        request.progress.done
        unless evaluated.dump_requests.empty?
          Diagnostics::FuncDumper.new(rom, backend.func_ranges, tables: backend.number_tables,
                                                                out: request.out, err: request.err)
                                 .dump(evaluated.dump_requests)
        end
        rom
      end

      # A PROFILE THAT HAS DRIFTED FROM ITS GAME still decides what goes in the quick memory, and
      # would go on doing it, quietly and increasingly wrongly, as the game moved on. So a routine
      # the profile names that the program no longer has is said out loud.
      #
      # It is a warning and not an error on purpose: renaming one routine should not stop a build,
      # and the profile is still right about everything else it names. What it means is that the
      # game has been measured less recently than it has been changed.
      # What the caller handed over, read into a {RoutineProfile} — or nothing, which means the
      # choice is made from the shape of the program.
      def load_routine_profile(profile, program, err)
        measured = profile.is_a?(Diagnostics::RoutineProfile) ? profile : Diagnostics::RoutineProfile.read(profile || nil)
        warn_of_stale_profile(measured, program, err)
        measured
      end

      def warn_of_stale_profile(measured, program, err)
        return unless measured

        known = program.walk.filter_map { |node| node.name if node.kind == :func }.to_set
        known << IR::Backends::GBA::Placement::FRAME_ROUTINE
        known << IR::Backends::GBA::Placement::IRQ_ROUTINE
        gone = measured.stale_routines(known)
        return if gone.empty?

        err.puts("This game was measured when it had #{gone.map { |name| "`#{name}`" }.join(', ')}, " \
                 "and it does not now. The measurement decides which routines stay in the console's " \
                 "quick memory, so it is out of date. To fix this, measure the game again and save " \
                 "the result.")
      end
      private_class_method :load_routine_profile, :warn_of_stale_profile
    end
  end
end
