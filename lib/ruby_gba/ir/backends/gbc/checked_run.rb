# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # A Game Boy Color cartridge played in the emulator (HeadlessRun), and then the same buttons,
        # pass for pass, played on the interpreter — stopping at the first pass the two disagree on,
        # about any variable, any list or pool, or any pixel. Native::CheckedRun is the same check of
        # the game as C, and the two say their disagreements in the same words (Native::Differences).
        #
        # It takes the interpreter's calls, so a test written against Reference.new can be handed one
        # of these instead and play its game on a Game Boy Color with nothing else changed:
        #
        #   run = RubyGBA::IR::Backends::GBC::CheckedRun.new
        #   run.input_each_frame { |frame| frame < 30 ? [:right] : [] }.run(game.program, frames: 60)
        #   run[:x]
        #
        # The interpreter plays the program on the screen of the console it was built for. A program
        # built for the Advance plays on the Advance's larger screen there, so the two pictures are
        # compared over the Color's screen, the top-left 160×144 of it: what is past that the
        # cartridge cannot show. (Whether a test of a program built for the Advance is played here at
        # all is RubyGBA::Testing's decision.)
        class CheckedRun
          include Native::Differences
          extend Native::Differences

          Moment = HeadlessRun::Moment

          # The cartridge and the interpreter disagreed. The message says the pass and everything
          # that differs there.
          class Disagreement < StandardError; end

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
              raise HeadlessRun::CannotAnswer, "a Game Boy Color cartridge keeps no step budget, so it cannot run " \
                                               "with max_steps"
            end

            frames ||= Reference::DEFAULT_FRAMES
            refuse_endless_game_without_frames!(program)
            before = @save.dup # the interpreter starts from the save memory the cartridge started from
            @cartridge.run(program, frames: frames)
            width, height = @cartridge.screen.then { |picture| [picture.width, picture.height] }
            moments, saved = play_on_interpreter(program, frames, width, height, before)
            difference = self.class.first_difference(moments, @cartridge.moments)
            raise Disagreement, "the Game Boy Color lowering and the interpreter disagree at #{difference}" if difference
            if Native::Saving.named_by?(program) && saved.to_sav != @save.to_sav
              raise Disagreement, "the Game Boy Color lowering and the interpreter end with different save memory"
            end

            self
          end

          def [](name) = @cartridge[name]
          def screen = @cartridge.screen

          def method_missing(name, ...) = @cartridge.public_send(name, ...)
          def respond_to_missing?(name, include_private = false) = @cartridge.respond_to?(name, include_private)

          def self.lowered_side = "the cartridge"

          # The first moment +got+ (the cartridge) disagrees with +want+ (the interpreter) on.
          def self.first_difference(want, got)
            if want.map(&:frame) != got.map(&:frame)
              return "how far the run went: the interpreter's moments were #{want.map(&:frame).last(3).inspect}, " \
                     "the cartridge's #{got.map(&:frame).last(3).inspect}"
            end

            want.zip(got).each do |reference, cartridge|
              differences = variable_differences(reference.variables, cartridge.variables)
              differences << "the picture differs" if reference.picture != cartridge.picture
              differences << "the sprites drawn differ" if reference.sprites != cartridge.sprites
              differences.concat(Native::CheckedRun.collections_differences(reference.collections, cartridge.collections))
              next if differences.empty?

              heading = reference.frame == :end ? "the end of the run" : "frame #{reference.frame}"
              return "#{heading}: #{differences.join('; ')}"
            end
            nil
          end

          private

          def buttons_for(frame) = @script ? Array(@script.call(frame)) : @held

          # A game that never waits for the screen has no frames to count, so it is played on the
          # interpreter first, with the buttons held from power-on, to find whether it comes to an
          # end by itself — as Native::CheckedRun does, and for the same reason: the cartridge
          # keeps no count of its steps. A game the interpreter stops with an error stops here
          # with it.
          def refuse_endless_game_without_frames!(program)
            return if program.walk.any? { |node| node.kind == :wait_vblank }
            return unless Reference.new(save: @save.dup).hold(*@held).run(program).stopped_at_budget?

            raise HeadlessRun::CannotAnswer, "this game never waits for the screen, so it has no frames to count: the " \
                                             "interpreter's step budget is all that stops it, and a Game Boy Color " \
                                             "cartridge keeps no count of its steps"
          end

          def play_on_interpreter(program, frames, width, height, save)
            interpreter = Reference.new(save: save).hold(*@held)
            moments = []
            interpreter.input_each_frame { |frame| @played.fetch(frame, []) }
                       .each_vblank { |frame| moments << moment_of(interpreter, frame, width, height) }
                       .run(program, frames: frames)
            [moments << moment_of(interpreter, :end, width, height), save]
          end

          def moment_of(interpreter, frame, width, height)
            Moment.new(frame: frame, variables: interpreter.vars.dup, picture: picture_check(interpreter.screen, width, height),
                       sounds: 0, sprites: interpreter.sprites, collections: interpreter.game_state.except(:vars),
                       sounding: [])
          end

          # The interpreter's picture over the cartridge's screen.
          def picture_check(screen, width, height)
            shown = (0...height).flat_map { |y| (0...width).map { |x| screen.pixel(x, y) || 0 } }
            Native::HeadlessRun.picture_check(shown)
          end
        end
      end
    end
  end
end
