# frozen_string_literal: true

module VBlank
  module Testing
    # A checked run's disagreement with the interpreter reported as a failed test rather than as
    # an error, the way every other check in a suite fails.
    module DisagreementFailsTest
      def run(program, max_steps: nil, frames: nil)
        super
      rescue IR::Backends::RunComparison::Disagreement => e
        raise Minitest::Assertion, e.message
      end
    end

    # What a test's player is on the native lowering's run: the game played as C and checked
    # against the interpreter on every frame (Native::CheckedRun says what it compares).
    class CheckedPlayer < IR::Backends::Native::CheckedRun
      include DisagreementFailsTest
    end

    # The same, on the JavaScript lowering's run: the game played as JavaScript under node
    # (JS::CheckedRun), checked against the interpreter on every frame by the same check.
    class JSCheckedPlayer < IR::Backends::JS::CheckedRun
      include DisagreementFailsTest
    end

    # The same, on the Ruby lowering's run: the game played as Ruby (Ruby::CheckedRun), checked
    # against the interpreter on every frame by the same check. What its runtime cannot do yet is a
    # skip naming it, so the run's count of skips by reason says what is left to do.
    class RubyCheckedPlayer < IR::Backends::Ruby::CheckedRun
      include DisagreementFailsTest

      def run(program, max_steps: nil, frames: nil)
        super
      rescue IR::Backends::Ruby::RuntimeGap => e
        raise MissingFeature, gap_reason(e)
      end

      # What the runtime cannot do yet a test asks of the run before or after it, a skip too.
      def method_missing(name, ...)
        super
      rescue IR::Backends::Ruby::RuntimeGap => e
        raise MissingFeature, gap_reason(e)
      end

      def respond_to_missing?(name, include_private = false) = super

      private

      def gap_reason(gap) = "Ruby's runtime does not have yet: #{gap.part}"
    end

    # The same, on the run of a console whose own cartridge is played — the Game Boy Color's, the
    # Super Nintendo's: the game built as that console's cartridge and played in the emulator (the
    # checked run its kit names, Console::CheckedKit#checked_run), checked against the interpreter
    # after every pass, each test's program played as a program for that console. One player
    # serves every such console, made from its kit (CartridgeCheckedPlayer.for).
    #
    # A test of what the console's hardware cannot do is not here to play at all: it lives with
    # the Advance's tests, which such a run never loads (test/console/gba in this
    # repository). What its build does not make yet is a skip naming the part (the picture, the
    # sound), when the lowering says so (IR::Backends::NotMadeYet), so the run's count of skips by
    # reason says what is left to make; any other refusal fails, since it is a fault. What the run
    # cannot answer of the cartridge is a skip too.
    module CartridgeCheckedPlayer
      include DisagreementFailsTest

      # The player class for the console named +console+, a subclass of its kit's checked run.
      def self.for(console) = PLAYERS.fetch(console)

      # What the class of a player answers: the console it plays a game as, and a program as it
      # plays it.
      module OfConsole
        attr_reader :console

        # +program+ as this run plays it: one that names no console, as a program for this one.
        def program_played(program)
          return program unless program.kind == :program && program.console.nil?

          program.copy.tap { |copy| copy.console = console }
        end

        def inspect = "VBlank::Testing::CartridgeCheckedPlayer.for(#{console.inspect})"
        alias_method :to_s, :inspect
      end

      def run(program, max_steps: nil, frames: nil)
        program = self.class.program_played(program)
        super
      rescue IR::Backends::RunComparison::CannotAnswer => e
        raise MissingFeature, cannot_answer_reason(e)
      rescue IR::Backends::NotMadeYet => e
        raise MissingFeature, "#{kit.title} build does not make yet: #{e.part}"
      end

      # What the cartridge cannot answer yet a test asks of it after its run, a skip too.
      def method_missing(name, ...)
        super
      rescue IR::Backends::RunComparison::CannotAnswer => e
        raise MissingFeature, cannot_answer_reason(e)
      end

      def respond_to_missing?(name, include_private = false) = super

      private

      def kit = Console.for(self.class.console)

      def cannot_answer_reason(error) = "#{kit.title} cannot answer: #{error.message[/`(\w+\??)`/, 1] || error.message}"

      # One player class for each console whose kit names a checked run, made once as the library
      # loads.
      PLAYERS = Ractor.make_shareable(Console.kits.grep(Console::CheckedKit).to_h do |console_kit|
        player = Class.new(console_kit.checked_run) { include CartridgeCheckedPlayer }
        player.extend(OfConsole)
        player.instance_variable_set(:@console, console_kit.name)
        [console_kit.name, player]
      end)
    end
  end
end
