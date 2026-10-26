# frozen_string_literal: true

module RubyGBA
  module Cartridge
    # THE GAME BOY ADVANCE'S CARTRIDGE, from a checked program (see Console::AdvanceKit): lowered
    # to ARM by IR::Backends::GBA, checked again for what the lowering decided, and assembled.
    module AdvanceBuild
      module_function

      # THE SETTINGS ONLY THE ADVANCE HAS (its console settings), by the name each is set with. A
      # game for the Advance and the Color says them once, and its Color cartridge is built without
      # them; a build for the Color alone that sets one is refused
      # (Console.refuse_unusable_console_settings!).
      #
      #   code, maker     the four characters an emulator tells one cartridge from another by, and
      #                   the two that name a publisher, in the Advance's cartridge header
      #   fast_cartridge  the quick cartridge timing asked for at boot; on unless said false
      #   fast_code       letting the build choose which routines go in the quick memory; on
      #                   unless said false
      #   stack_room      how many bytes of the quick memory the game's stack is given; the build
      #                   decides unless said (see IR::Backends::GBA::TopOfQuickMemory)
      #   profile         a measurement taken earlier, a path or a Diagnostics::RoutineProfile,
      #                   which decides what goes in the quick memory
      SETTINGS = %i[code maker fast_cartridge fast_code stack_room profile].freeze

      # The least stack room a game can ask for: the console's own routines a game calls need this
      # much of it.
      LEAST_STACK_ROOM = 64

      def console_settings = SETTINGS

      # Refuses a value in +said+ (a setting's name to the value it was set to, for the settings
      # above) that the Advance's build cannot use, naming what it can.
      def refuse_unusable_settings!(said)
        refuse_unusable_stack_room!(said[:stack_room]) if said.key?(:stack_room)
      end

      # What the lowering is told, from +options+ (a Cartridge::Options): what the game said, and
      # for what it did not, what the Advance does when nothing is said. A finished cartridge
      # records the same (BuildRecord#build_options), which is what builds it the same way again.
      def lowering_options(options)
        { fast_cartridge: options.fast_cartridge != false, fast_code: options.fast_code != false,
          stack_room: options.stack_room }
      end

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
        backend = IR::Backends::GBA.new(**lowering_options(request.options), progress: request.progress,
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

      # The cartridge for +program+ alone, titled +title+: lowered as the Advance does when nothing
      # is said, with no guardrails and no validation. What a test that plays a cartridge builds
      # (Testing::Pictures).
      def cartridge_for(program, title:)
        backend = IR::Backends::GBA.new
        ROM.assemble(backend.lower(program), title: title, code: "TEST", maker: "01",
                                             built: backend.build_record(program))
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
      # A number of bytes the stack can hold whole numbers in, from the least the console's own
      # routines need to the most the quick memory can give it.
      def refuse_unusable_stack_room!(stack_room)
        most = IR::Backends::GBA::TopOfQuickMemory::MOST_STACK_BYTES
        return if stack_room.is_a?(Integer) && stack_room.between?(LEAST_STACK_ROOM, most) && (stack_room % 4).zero?

        raise ArgumentError, "stack_room: #{stack_room.inspect} is not a size the stack can have. It must be a " \
                             "number of bytes that is a multiple of 4, from #{LEAST_STACK_ROOM} to #{most}. To fix " \
                             "this, use such a number, or remove stack_room: and the build picks the size."
      end
      private_class_method :load_routine_profile, :warn_of_stale_profile, :refuse_unusable_stack_room!
    end
  end
end
