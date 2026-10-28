# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A Super Nintendo cartridge played in the emulator (HeadlessRun), and then the same buttons,
        # pass for pass, played on the interpreter — stopping at the first pass the two disagree on,
        # about any variable, any list or pool, or any pixel. Every checked run makes the same
        # comparison and says it in the same words (RunComparison).
        #
        # It takes the interpreter's calls, so a test written against Reference.new can be handed one
        # of these instead and play its game on a Super Nintendo with nothing else changed:
        #
        #   run = VBlank::IR::Backends::SNES::CheckedRun.new
        #   run.input_each_frame { |frame| frame < 30 ? [:right] : [] }.run(game.program, frames: 60)
        #   run[:x]
        #
        # The interpreter plays the program on the screen of the console it was built for, and the
        # two pictures are compared over the Super Nintendo's screen, the top-left 256×224 of it.
        class CheckedRun
          extend RunComparison

          Moment = HeadlessRun::Moment

          # The cartridge and the interpreter disagreed. The message says the pass and everything
          # that differs there.
          Disagreement = RunComparison::Disagreement

          def initialize(save: SaveImage.new)
            @save = save
            @cartridge = HeadlessRun.new(save: save)
            @played = {}
            @held = []
            @cartridge.input_each_frame { |frame| @played[frame] = buttons_for(frame) }
          end

          def hold(*buttons)
            @held = buttons
            @cartridge.hold(*buttons)
            self
          end

          def input_each_frame(&script)
            @script = script
            self
          end

          def each_vblank(&block)
            @cartridge.each_vblank(&block)
            self
          end

          def run(program, max_steps: nil, frames: nil)
            if max_steps
              raise HeadlessRun::CannotAnswer, "a Super Nintendo cartridge keeps no step budget, so it cannot run " \
                                               "with max_steps"
            end

            frames ||= Reference::DEFAULT_FRAMES
            refuse_endless_game_without_frames!(program)
            @cartridge.run(program, frames: frames)
            width, height = @cartridge.screen.then { |picture| [picture.width, picture.height] }
            moments = play_on_interpreter(program, frames, width, height)
            difference = self.class.first_difference(moments, @cartridge.moments)
            raise Disagreement, "the Super Nintendo lowering and the interpreter disagree at #{difference}" if difference

            self
          end

          def [](name) = @cartridge[name]
          def screen = @cartridge.screen

          def method_missing(name, ...) = @cartridge.public_send(name, ...)
          def respond_to_missing?(name, include_private = false) = @cartridge.respond_to?(name, include_private)

          def self.lowered_side = "cartridge"

          private

          def buttons_for(frame) = @script ? Array(@script.call(frame)) : @held

          # A game that never waits for the screen has no frames to count, so it is played on the
          # interpreter first, with the buttons held from power-on, to find whether it comes to an
          # end by itself: the cartridge keeps no count of its steps.
          def refuse_endless_game_without_frames!(program)
            return if program.walk.any? { |node| node.kind == :wait_vblank }
            return unless Reference.new(save: @save.dup).hold(*@held).run(program).stopped_at_budget?

            raise HeadlessRun::CannotAnswer, "this game never waits for the screen, so it has no frames to count: the " \
                                             "interpreter's step budget is all that stops it, and a Super Nintendo " \
                                             "cartridge keeps no count of its steps"
          end

          # The interpreter is told how many frames each pass took on the cartridge, so whatever keeps
          # real time moves on by the same frames on both.
          def play_on_interpreter(program, frames, width, height)
            interpreter = Reference.new(save: @save.dup).hold(*@held)
            moments = []
            interpreter.frames_each_pass { |pass| @cartridge.frames_took(pass) }
            interpreter.input_each_frame { |frame| @played.fetch(frame, []) }
                       .each_vblank { |frame| moments << moment_of(interpreter, frame, width, height) }
                       .run(program, frames: frames)
            moments << moment_of(interpreter, :end, width, height)
          end

          def moment_of(interpreter, frame, width, height)
            Moment.new(frame: frame, variables: interpreter.vars.dup, picture: picture_check(interpreter.screen, width, height),
                       sounds: 0, sprites: interpreter.sprites,
                       collections: interpreter.game_state.except(:vars), sounding: [])
          end

          # The interpreter's picture over the cartridge's screen.
          def picture_check(screen, width, height)
            shown = (0...height).flat_map { |y| (0...width).map { |x| screen.pixel(x, y) || 0 } }
            RunComparison.picture_check(shown)
          end
        end
      end
    end
  end
end
