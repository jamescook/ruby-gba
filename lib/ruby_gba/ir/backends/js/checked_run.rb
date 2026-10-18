# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class JS
        # What tells a game played as JavaScript from the same game played on the interpreter:
        # Native::Differences, in the same words but for what the checked side is called, and with
        # every pixel of every frame played as JavaScript where a check needs to say where two
        # pictures differ.
        module Differences
          include Native::Differences

          def lowered_side = "JS"

          # The snapshots the windowless program printed, as Native::Differences reads the C's.
          # There is only one way to build JavaScript, so +mode+ is taken and not read.
          def native_snapshots(program, frames:, buttons:, mode: nil, held: [])
            script = JS.new.build_headless(program)
            input = (1..frames).map { |frame| "#{Native::HeadlessRun.button_mask(buttons.fetch(frame, []))}\n" }.join
            from_power_on = held.empty? ? [] : ["--held-from-power-on", Native::HeadlessRun.button_mask(held)]
            parse_snapshots(Node.run_program(script, args: [frames, "--every-picture", *from_power_on], input: input), program)
          end
        end

        # A game played as JavaScript (HeadlessRun), and then the same buttons, frame for frame,
        # played on the interpreter, stopping at the first frame the two disagree on. Everything it
        # compares, and how, is Native::CheckedRun's: the two lowerings are held to the interpreter
        # by one check, so neither can be held to less.
        #
        #   run = RubyGBA::IR::Backends::JS::CheckedRun.new
        #   run.input_each_frame { |frame| frame < 30 ? [:right] : [] }.run(game.program, frames: 60)
        #   run[:x]
        #
        # It needs node, as every JavaScript run without a browser does.
        class CheckedRun < Native::CheckedRun
          include Differences
          extend Differences

          private

          def headless_run(save) = HeadlessRun.new(save: save)
          def lowering_name = "the JavaScript lowering"
        end
      end
    end
  end
end
