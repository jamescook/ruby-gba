# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Ruby
        # What tells a game played as Ruby from the same game played on the interpreter:
        # Native::Differences, in the same words but for what the checked side is called, and with
        # every pixel of every frame played as Ruby where a check needs to say where two pictures
        # differ.
        module Differences
          include Native::Differences

          def lowered_side = "Ruby"

          # The game as Ruby, played by the Ruby running this, as HeadlessRun plays it. There is
          # one way to build it, so the C's build +mode+ has nothing to say here.
          def run_headless_program(program, _mode, args:, input:)
            script = Ruby.new.build_headless(program)
            Native::Zig.run_program(RbConfig.ruby, args: ["--disable-gems", script, *args], input: input,
                                                   env: Ruby::PROGRAM_ENVIRONMENT)
          end
        end

        # A game played as Ruby (HeadlessRun), and then the same buttons, frame for frame, played
        # on the interpreter, stopping at the first frame the two disagree on. Everything it
        # compares, and how, is Native::CheckedRun's: every lowering is held to the interpreter by
        # one check, so none can be held to less.
        #
        #   run = VBlank::IR::Backends::Ruby::CheckedRun.new
        #   run.input_each_frame { |frame| frame < 30 ? [:right] : [] }.run(game.program, frames: 60)
        #   run[:x]
        class CheckedRun < Native::CheckedRun
          include Differences
          extend Differences

          private

          def headless_run(save) = HeadlessRun.new(save: save)
          def lowering_name = "the Ruby lowering"
        end
      end
    end
  end
end
