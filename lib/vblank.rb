# frozen_string_literal: true

require_relative "vblank/version"
require_relative "vblank/root"

module VBlank
  # A BUILD THAT STOPPED, whichever console or format it was for and whatever stopped it: the
  # checks found a mistake, a lowering cannot make what the game asks for, the cartridge came out
  # wrong. Each says what happened and what to do in its message, so a caller that turns a failed
  # build into words for a person rescues this one class.
  #
  # Defined here, before the modules, because each lowering's own error is one of these and is
  # defined while its module loads.
  class BuildError < StandardError; end

  # A build the checks stopped, or a cartridge that came out wrong.
  class ROMError < BuildError; end
end

# THE WHOLE LIBRARY, A LINE FOR EACH MODULE, and this is the only place that says so. Each one loads a
# module through a front door of its own (or, for version and pager, a single file); what is
# inside a module is that module's business and is listed in its own front door.
#
# THE ORDER IS NOT ALPHABETICAL AND CANNOT BE. It is what each piece needs to have been defined
# before its own class bodies run, and every step of it is a dependency worth knowing about:
#
#   ir needs BUILDERROR (above, before every module), because each lowering's error, the
#     guardrails' and the colour table's are kinds of it.
#   cartridge, audio, builder, diagnostics and ir all need CONSOLE first, the table of the
#     hardware's addresses and flags. It needs nothing itself, so it goes at the top.
#   ir needs AUDIO, because a backend sizes its music player from what a tune is.
#   dsl needs IR, because a handle a game holds is a way of building a node.
#   effects needs BUILDER, because an effect pack adds verbs to it.
#   playthroughs needs CONSOLE and GRAPHICS, because a comparison takes the size of the screen
#     and the colour it marks a difference in while its classes are being defined.
#
# Everything else is free to move. Adding a require here means a new module, not a new file —
# a file goes in its own module's front door.
require_relative "vblank/console" # the hardware's addresses and flags, named
require_relative "vblank/messages" # what a build says to the person running it, while it builds
require_relative "vblank/cartridge" # the bytes on the card, and the card itself
require_relative "vblank/graphics" # what a picture is made of
require_relative "vblank/audio" # what a beep, a note and a tune are
require_relative "vblank/ir" # the op-tree a program becomes, and the backends that consume it
require_relative "vblank/dsl" # the handles a game holds: a Value, a Sprite, a List, a Pool
require_relative "vblank/builder" # ...and the verbs that hand them back
require_relative "vblank/effects" # the verb/effect pack registry, and the packs that ship on by default
require_relative "vblank/diagnostics" # reading a built or running cartridge back
require_relative "vblank/playthroughs" # ...and playing one with nobody at the controls, or two side by side
require_relative "vblank/pager" # a long report shown a screen at a time

module VBlank
  # A saved profile that cannot be read, or that no longer matches the game it decides for.
  class ProfileError < StandardError; end
  # Build a GBA ROM using the DSL.
  #
  # @param title [String] Game title (up to 12 chars)
  # @param code [String, nil] the 4 characters an emulator tells one cartridge from another
  #   by. Leave it out: the framework works a free one out from the title, and a code a real
  #   cartridge already carries is refused (see {GameCode}).
  # @param maker [String, nil] the 2 characters that name a publisher. Leave it out and the
  #   cartridge says it has none, which is true — "01" is Nintendo's.
  # @param validate [Boolean] run the ROM-image validation after build (default: true)
  # @param fast_cartridge [Boolean, nil] ask the console for quick cartridge timing at boot
  #   (on unless said). Pass false to leave the cautious power-on timing alone — the
  #   escape hatch for a cartridge that can't keep up. The Game Boy Advance's alone.
  # @param fast_code [Boolean, nil] let the build work out which routines are worth keeping
  #   in the console's quick memory, where code runs about two and a half times faster
  #   (on unless said). `rom.profile` says what it chose. Pass false to stop it choosing —
  #   a routine you mark `func :name, fast: true` yourself still goes there. The Game Boy
  #   Advance's alone.
  # @param progress [VBlank::Messages::Progress] what the build says it is doing while it does it.
  #   The default says nothing; `Progress.to($stderr)` names each phase and how far it has
  #   got. See {VBlank::Messages::Progress}.
  # @param profile [true, false, String, VBlank::Diagnostics::RoutineProfile] where this game's frames
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
  # @return [VBlank::Cartridge::ROM] finalized ROM ready to write
  # +out+/+err+ are where the build prints — the disassembly dump_func was asked for, and the
  # warnings the guardrails found. Each takes an open stream (a StringIO, to capture them in a
  # test), the NAME of a file (opened and closed for you), or nil for a build that prints
  # nothing at all; they default to the process streams. See {Messages::BuildOutput}.
  # +code+ and +maker+ are the four characters an emulator tells one cartridge from another
  # by, and the two that name a publisher. Leave them out: the framework works a free code
  # out from the title (see {GameCode}), and a code a released cartridge already carries is
  # refused rather than quietly shipped.
  # +settings+ are what this one build is told, read by the game with `setting` (see
  # {Builder::Settings}) — so a variant is a value handed to one build, not something changed
  # for every build in the process.
  # +save_memory+ is how much save memory the cartridge has, in kilobytes: 8, 32, 64 or 128. Leave
  # it out and the build picks the smallest of 32, 64 and 128 that holds the game's save_data
  # records; 8, the EEPROM, a game has to ask for.
  # +stack_room+ is how many bytes of the console's quick memory the game's stack is given. Leave it
  # out and the build gives it 1024, or more for a game whose calls nest deeply; every byte held
  # for the stack is one the game's variables, lists and code cannot have.
  # +console+ is the console the cartridge is for (:gba, :gbc; see {Console::Kit}), and every build
  # names it: nothing is taken to be for the Advance.
  # +code+, +maker+, +fast_cartridge+, +fast_code+, +stack_room+ and a saved +profile+ are the Game
  # Boy Advance's alone (Cartridge::AdvanceBuild::SETTINGS): a build for another console that sets
  # one is refused.
  # +variant+ names the hardware this copy of +console+ has beyond the plain console (:superfx, a
  # Super FX 2 chip on a Super Nintendo cartridge; see {Console::Variant}), or is nil.
  # +sprite_piece_size+ is the size a console draws a sprite's pieces at, by console
  # (`{ gbc: [8, 16] }`); see {Cartridge::Options}.
  # +cartridge+ false stops once the program is checked and hands back the program, not a cartridge:
  # for a game played as Ruby (`vblank run`), which has no use for one. Every guardrail runs, and
  # what only making the cartridge finds (a game too big for it) is not asked.
  def self.build(title, code: nil, maker: nil, validate: true, frame_sync: :auto, fast_cartridge: nil,
                 fast_code: nil, out: $stdout, err: $stderr, progress: Messages::Progress.silent,
                 profile: false, settings: {}, save_memory: nil, stack_room: nil, console: nil, variant: nil,
                 sprite_piece_size: {}, cartridge: true, &block)
    # The eight that say how the game is built travel as one value from here on (see
    # {Cartridge::Options}), checked now so a setting that cannot be right stops the build first.
    options = Cartridge::Options.new(frame_sync: frame_sync, fast_cartridge: fast_cartridge,
                                     fast_code: fast_code, save_memory: save_memory, stack_room: stack_room,
                                     console: console, variant: variant, sprite_piece_size: sprite_piece_size)
    refuse_unnamed_console!(title) if options.console.nil?
    # A measurement taken earlier is a console setting; true and false only say whether to measure.
    said = Console.console_settings_said(code: code, maker: maker, **options.to_h,
                                         profile: ([true, false].include?(profile) ? nil : profile))
    Console.refuse_unusable_console_settings!(said, consoles: [options.console], title: title, named_in: "console:")
    # Settle where this build prints BEFORE anything is read or checked, so a caller
    # that named somewhere the build cannot write is told on every build rather than on
    # the one build that finally has a warning to give (see {Messages::BuildOutput}).
    output = Messages::BuildOutput.new(out: out, err: err)
    out = output.out
    err = output.err

    # Measuring chooses what goes in a quick memory, which only some consoles have.
    kit = Console.for(options.console)
    profile = false unless kit.measured_builds? && cartridge
    if profile == true
      return build_measured(title, code: code, maker: maker, validate: validate, out: out, err: err,
                            progress: progress, settings: settings, **options.to_h, &block)
    end

    progress.step("reading the game")
    evaluated = Cartridge::EvaluatedGame.new(block, options: options, progress: progress, settings: settings)
    program = evaluated.program

    # First prove the tree is well-formed — every value operand is a value node,
    # nothing structural is out of place. This checks the *library's* own
    # consistency, not the developer's game, so a failure is a VBlank bug and
    # raises loudly rather than joining the friendly guardrail report below. It
    # runs before the guardrails and the backend so a malformed tree can't reach
    # them and fail cryptically two passes downstream.
    progress.step("checking the tree")
    IR::Verifier.verify!(program)

    # Run the guardrails over the finished IR and collect every finding — its
    # plain-language explanation and the suggested fix. A warning is advisory (a
    # game loop with no frame sync, say): the build goes on. A fatal problem
    # (drawing on a tiled screen, which would leave the screen black) stops the
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
      # `wait_vblank` calls, the lines that gave an `estimate:`, and the software sprites,
      # whose layer lives on the handle.
      # All are just checks in the list, so the Validator treats them alike.
      checks = IR::Guardrails.default_checks + evaluated.game_pack_checks +
               [IR::Guardrails::Checks::OrphanedCondition.new(evaluated.unused_conditions),
                IR::Guardrails::Checks::OrphanedExpression.new(evaluated.expressions),
                IR::Guardrails::Checks::DroppedFrameSync.new(evaluated.dropped_syncs),
                IR::Guardrails::Checks::EstimateDoesNothing.new(evaluated.estimate_lines),
                IR::Guardrails::Checks::LayerHoldsNothing.new(evaluated.sprites),
                IR::Guardrails::Checks::StackNotHonored.new(evaluated.sprites)]
      findings = IR::Guardrails::Validator.new(checks: checks, progress: progress)
                                          .run(program, autofix: false)
      if findings.errors.any?
        raise ROMError,
              "build stopped by #{findings.errors.size} problem(s) — see the explanation(s) above"
      end
    end

    return program unless cartridge

    # The cartridge is made by the build the console's kit names, from the same checked tree. The
    # findings travel with the request, so what that build adds to them is printed below however
    # it ends.
    request = Cartridge::BuildRequest.new(program: program, evaluated: evaluated, findings: findings, title: title,
                                          code: code, maker: maker, validate: validate, options: options,
                                          profile: profile, progress: progress, out: out, err: err)
    kit.builder.build(request)
  ensure
    # HOWEVER THE BUILD ENDED: close the line, then say what the guardrails found — with what the
    # console's build added to them, once it was handed them.
    #
    # In that order, and both here rather than where they happen. A live progress line is held
    # open and rewritten in place, so anything printed while one is open lands in the middle of
    # it — and a build that stops half way through a phase (a guardrail error, a routine that
    # will not fit) has a message to print. Putting the findings here too is what keeps them
    # after the whole run of phases instead of splitting it: they are read once the build has
    # finished telling you what it did. On the way out of an error this still runs first, so a
    # reader sees the explanation and then the line saying the build stopped.
    progress.done
    findings = request.findings if request
    findings&.print_findings(to: err)
    # A build cut short by `debug_halt` says so where it says the rest, so a test that captures
    # the build's words has these too and the terminal is spared them.
    if evaluated&.debug_halted?
      err&.puts "debug_halt stops the build here. The code after debug_halt is not in the ROM. Remove " \
                "debug_halt when you are done."
    end
    # Last of all, because the lines above are the last thing anybody prints: hand back any
    # file this build opened for itself. A stream the caller opened is left alone.
    output&.close
  end

  def self.refuse_unnamed_console!(title)
    raise ArgumentError, "#{title} names no console to build for. Add `console:` to VBlank.build. Use " \
                         "`console: :gba` for the Game Boy Advance, or `console: :gbc` for the Game Boy Color."
  end
  private_class_method :refuse_unnamed_console!

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
  # {Profiler.survey_scenes}. Without that the measuring would only ever see a title screen,
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
  #
  # WHAT IT SAYS WHILE IT WORKS is one list of phases, the real build's: the first build is one
  # line of it and playing the scenes another, and what the playing found is said after the
  # real build has finished, with its findings, never in the middle of a phase.
  def self.build_measured(title, code:, maker:, out:, err:, progress:, **options, &block)
    # code/maker are passed through as they arrived, nil included — the cartridge header
    # is where a missing one is settled (see {GameCode}), and both builds below have to
    # settle it the same way or the second would measure a different cartridge.
    built = ->(**how) { build(title, code: code, maker: maker, **{ out: out, err: err, **options }.merge(how), &block) }
    return built.call(profile: false, progress: progress) unless Diagnostics::Emulator.available?

    first = build_once_to_measure(built, err, progress)
    survey = play_each_scene(first, progress)
    found = StringIO.new
    warn_of_slow_scenes(survey, found)
    warn_of_collections_that_fill(survey, found)
    warn_of_late_hand_overs(survey, found)
    begin
      built.call(profile: Diagnostics::RoutineProfile.from_survey(survey, game: title), progress: progress)
    ensure
      err.write(found.string)
    end
  rescue LoadError
    # An emulator that is there and will not run. Choose from the shape of the program instead.
    progress.done
    built.call(profile: false, progress: progress)
  end

  # THE FIRST BUILD, said as one line of the real one: its own phases are only ever that line's
  # detail, since two lists of the same phases read as a build that ran twice by mistake. What it
  # finds and what it would print is about a cartridge nobody gets, so both are held back — and
  # let out if it stops, since then its explanation is the whole point.
  def self.build_once_to_measure(built, err, progress)
    held = StringIO.new
    first = built.call(profile: false, out: StringIO.new, err: held,
                       progress: progress.as_one_line("a first build, to measure"))
    progress.show_detail(nil) # finished: its line says how long it took and nothing about its last phase
    first
  rescue StandardError
    progress.done
    err.write(held.string)
    raise
  end

  # Play each scene of the first build in the emulator, saying which, and close the line if that
  # fails, so what is printed next is not printed into it.
  def self.play_each_scene(first, progress)
    progress.step("playing each scene to measure it")
    Diagnostics::Profiler.survey_scenes(first, progress: progress)
  rescue StandardError, LoadError
    progress.done
    raise
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
    slow = survey.slow_scenes
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

  # A GAME THAT KEEPS UP UNTIL ITS COLLECTIONS FILL is said so at build time too, and the
  # number in it is measured like the one above: the build ran the scene again with every list
  # and pool held at its capacity (see Profiler.growth_in). That is the bug a collection sized
  # for the worst moment of a game and walked item by item every frame causes — fine for the
  # whole of development, and too slow in the one session that fills it.
  def self.warn_of_collections_that_fill(survey, err)
    survey.growths.each do |growth|
      where = growth.scene ? "The #{growth.scene.inspect} scene keeps" : "This game keeps"
      named = growth.collections.map { |c| "#{c.label}, which can hold #{c.capacity}" }
      full = growth.together ? "With all of them full at the same time" : "With #{named.one? ? 'it' : 'them'} full"
      err.puts <<~MSG

        #{where} up at 60 frames a second now. But it uses
        #{named.join(', and ')}.
        #{full}, it runs at about #{growth.reading.fps.round} frames a second, and the whole game
        moves more slowly. To fix this, give #{named.one? ? 'it' : 'them'} a smaller capacity, or
        do less work for each item.
      MSG
    end
  end

  # A SCENE THAT RUNS LATE ON THE FRAME THE GAME HANDS OVER TO IT is said at build time too,
  # measured like the two above (see Diagnostics::HandOvers): the build handed over to each
  # scene once and read whether that frame finished. It is the one late frame no frame rate
  # shows, since every frame after it fits.
  def self.warn_of_late_hand_overs(survey, err)
    survey.late_hand_overs.each { |late| err.puts("\n#{Diagnostics::HandOvers.message(late)}") }
  end
end
