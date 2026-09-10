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
require_relative "ruby_gba/video_memory" # how much room the pictures took, and what the storage saved
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
require_relative "ruby_gba/build_report" # the exact half of a profile: what the build made
require_relative "ruby_gba/profiler"
require_relative "ruby_gba/routine_profile"

module RubyGBA
  class ROMError < StandardError; end
  # A saved profile that cannot be read, or that no longer matches the game it decides for.
  class ProfileError < StandardError; end
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
  #   (default: true). `rom.profile` says what it chose. Pass false to stop it choosing —
  #   a routine you mark `func :name, fast: true` yourself still goes there.
  # @param progress [RubyGBA::Progress] what the build says it is doing while it does it.
  #   The default says nothing; `Progress.to($stderr)` names each phase and how far it has
  #   got. See {RubyGBA::Progress}.
  # @param profile [true, false, String, RubyGBA::RoutineProfile] where this game's frames
  #   really go, which decides which routines are kept in the console's quick memory.
  #
  #   TRUE MEASURES IT: the build builds the game once, runs it, and builds it again knowing
  #   what its frames were really spent on — see {.build_measured}. Nothing has to be run or
  #   saved by hand, and nothing is guessed. It is what {Game#build_rom} asks for, so a
  #   cartridge somebody is going to play gets it.
  #
  #   FALSE, THE DEFAULT HERE, skips the measuring and chooses from the shape of the program
  #   instead: the frame's own body first, then out along what it calls. It is the default on
  #   this method because this is the primitive — the suite builds thousands of cartridges
  #   through it to check pixels and guardrails and emitted code, and not one of them cares
  #   where a routine ended up. Measuring them all would double the suite for nothing. It is
  #   also what a reproducible build wants, since it depends on nothing but the source.
  #
  #   A PATH or a {RoutineProfile} uses a measurement taken earlier, for the case the automatic
  #   one cannot reach: a game measures each of its scenes, so a moment WITHIN one — a boss with
  #   half its health gone, a floor with sixty guards — has to be measured by hand and saved.
  # @return [RubyGBA::ROM] finalized ROM ready to write
  # +out+/+err+ are the streams dump_func writes its disassembly and warnings to;
  # they default to the process streams and can be pointed at a StringIO in tests.
  def self.build(title, code:, maker:, validate: true, frame_sync: :auto, fast_cartridge: true,
                 fast_code: true, out: $stdout, err: $stderr, progress: Progress.silent,
                 profile: false, &block)
    if profile == true
      return build_measured(title, code: code, maker: maker, validate: validate,
                            frame_sync: frame_sync, fast_cartridge: fast_cartridge,
                            fast_code: fast_code, out: out, err: err, progress: progress, &block)
    end

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
    measured = given_profile(profile, program, err)
    backend = IR::Backends::GBA.new(fast_cartridge: fast_cartridge, fast_code: fast_code,
                                    progress: progress, routine_profile: measured)
    machine_code = backend.lower(program)
    record = backend.build_record(program)

    # The guardrail that reads a decision the build made runs here instead of above, because
    # the decision does not exist until the build has made it. Its findings join the ones from
    # the first pass and print together at the end.
    unless evaluated.debug_halted?
      progress.step("the guardrails that need the build")
      checks = IR::Guardrails.build_checks(record.placement)
      priced = IR::Guardrails::Validator.new(checks: checks, progress: progress)
                                        .run(program, autofix: false)
      findings = findings.with(findings: findings.findings + priced.findings)
    end
    # The findings ride on the record too, so a report asked for as data carries them.
    record = record.with(findings: findings.findings) if findings

    progress.step("assembling the cartridge")
    # The cartridge carries what the build worked out about it — the program it came from,
    # which routines went in the console's quick memory, where the variables landed, and so
    # on — so that a finished ROM can report on itself (see BuildRecord and rom.profile).
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

  # BUILD IT, RUN IT, BUILD IT AGAIN — which is how the build knows what a game spends its
  # frames on instead of guessing.
  #
  # The one decision a build cannot measure its way to on its own is which routines to keep in
  # the console's quick memory, where code runs about two and a third times faster. The choice
  # is an INPUT to the lowering, so it has to be made before the game it would run exists. So
  # the game is built once, with the choice made from the shape of the program; that cartridge
  # is run and measured; and then it is built again, this time knowing.
  #
  # NOBODY HAS TO PLAY IT. A game keeps which screen it is on in a variable and the build knows
  # where that variable lives, so each scene is entered by writing it — see
  # {Profiler.every_scene}. Without that the measuring would only ever see a title screen,
  # which is the wrong thing to make a game fast for.
  #
  # THE FIRST BUILD'S FINDINGS ARE HELD BACK, and only its findings. They are about a cartridge
  # nobody gets, and they can differ from the real ones in exactly the way that matters: a
  # warning is priced with what the build decided, so the throwaway one can say a frame goes
  # over budget where the measured cartridge comfortably fits. Printing both would be printing
  # a warning that is not true of the game.
  #
  # BUT A BUILD THAT STOPS HAS TO SAY WHY. A guardrail error stops the first build, and its
  # explanation is the whole point of stopping — so what was held back is let out on the way
  # past. Anything else swallows the one message an author needs.
  #
  # WITH NO EMULATOR THERE IS NOTHING TO RUN, and a build still has to work, so it falls back
  # to choosing from the shape of the program. `rom.profile` says which of the two happened.
  def self.build_measured(title, code:, maker:, out:, err:, progress:, **options, &block)
    held = StringIO.new
    first = begin
      build(title, code: code, maker: maker, profile: false,
            out: out, err: held, progress: progress, **options, &block)
    rescue StandardError
      err.write(held.string)
      raise
    end

    survey = Profiler.every_scene(first)
    warn_of_slow_scenes(survey, err)
    measurement = RoutineProfile.from_work(survey.work, game: title)
    build(title, code: code, maker: maker, profile: measurement,
          out: out, err: err, progress: progress, **options, &block)
  rescue LoadError
    # No emulator to run it on. Choose from the shape of the program instead.
    build(title, code: code, maker: maker, profile: false,
          out: out, err: err, progress: progress, **options, &block)
  end

  # A GAME THAT DOES NOT KEEP UP IS SAID SO AT BUILD TIME, from what the build just measured.
  #
  # This is what the framework used to guess at: a frame priced in scanlines against a budget,
  # with a warning when the total came out over. That was a second statement of what the
  # hardware costs and every mispricing was a bug. The build now RUNS the game to decide what
  # goes in the quick memory, so the frame rate is already in its hands and costs nothing to
  # report — and it is a fact rather than an arithmetic.
  #
  # WHAT IT LOOKS LIKE MATTERS, and it is not choppiness. A game moves what it moves once per
  # pass of its loop, so fewer passes a second is less movement a second: the whole game runs
  # in SLOW MOTION, smoothly. Saying "choppy" sends a reader looking for the wrong thing.
  def self.warn_of_slow_scenes(survey, err)
    slow = survey.struggling
    return if slow.empty?

    slow.each do |scene, reading|
      where = scene ? "The #{scene.inspect} scene runs" : "This game runs"
      err.puts <<~MSG

        #{where} at about #{reading.fps.round} frames a second, not 60. It does more work each
        frame than one frame has room for. Everything moves once a frame, so the whole game
        moves that much more slowly — smoothly, not choppily. To see where the frames go, call
        `rom.profile` on the built ROM.
      MSG
    end
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
  def self.given_profile(profile, program, err)
    measured = profile.is_a?(RoutineProfile) ? profile : RoutineProfile.read(profile || nil)
    warn_of_forgotten_routines(measured, program, err)
    measured
  end

  def self.warn_of_forgotten_routines(measured, program, err)
    return unless measured

    known = program.walk.filter_map { |node| node.name if node.kind == :func }.to_set
    known << IR::Backends::GBA::Placement::FRAME_ROUTINE
    known << IR::Backends::GBA::Placement::IRQ_ROUTINE
    gone = measured.forgotten(known)
    return if gone.empty?

    err.puts("This game was measured when it had #{gone.map { |name| "`#{name}`" }.join(', ')}, " \
             "and it does not now. The measurement decides which routines stay in the console's " \
             "quick memory, so it is out of date. To fix this, measure the game again and save " \
             "the result.")
  end
end
