# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # A Game Boy Color cartridge played in the emulator (HeadlessRun), and then the same buttons,
        # pass for pass, played on the interpreter — stopping at the first pass the two disagree on,
        # about any variable, any list or pool, any pixel, or how far the sound log has grown — and
        # at the end, about every entry of the sound log (GBC::SoundLog reads the cartridge's) and the
        # save memory. Every checked run makes the same comparison and says it in the same words
        # (RunComparison).
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

          # The same clock on both sides, started at the same moment: the Color's chip, which keeps
          # no date, whichever console the program was built for.
          def clock_at(time, set: true)
            @cartridge.clock_at(time, set: set)
            @clock_started = time
            @clock_set = set
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
            moments, saved, sounds = play_on_interpreter(program, frames, width, height, before)
            difference = self.class.first_difference(moments, @cartridge.moments)
            # A log that grew differently says which entry it first differs at, read to the end.
            heard = self.class.sounds_difference(sounds, @cartridge.whole_audio)
            difference = [difference, heard].compact.join(", and ") if difference&.include?("sound log")
            difference ||= self.class.sounds_difference(sounds, @cartridge.audio_played)
            difference ||= self.class.save_difference(saved, @save) if SaveLayout.named_by?(program)
            raise Disagreement, "the Game Boy Color lowering and the interpreter disagree at #{difference}" if difference

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
          # end by itself — as the native lowering's checked run does, and for the same reason: the
          # cartridge keeps no count of its steps. A game the interpreter stops with an error stops here
          # with it.
          def refuse_endless_game_without_frames!(program)
            return if program.walk.any? { |node| node.kind == :wait_vblank }
            return unless Reference.new(save: @save.dup).hold(*@held).run(program).stopped_at_budget?

            raise HeadlessRun::CannotAnswer, "this game never waits for the screen, so it has no frames to count: the " \
                                             "interpreter's step budget is all that stops it, and a Game Boy Color " \
                                             "cartridge keeps no count of its steps"
          end

          # The interpreter is told how many frames each pass took on the cartridge, so whatever
          # keeps real time — the music, `once_a_frame`, a beat, the buttons read on every frame —
          # moves on by the same frames on both.
          def play_on_interpreter(program, frames, width, height, save)
            interpreter = Reference.new(save: save).hold(*@held)
            interpreter.clock_at(@clock_started, set: @clock_set, keeps_date: false) if @clock_started
            moments = []
            interpreter.frames_each_pass { |pass| @cartridge.frames_took(pass) }
            interpreter.input_each_frame { |frame| @played.fetch(frame, []) }
                       .each_vblank { |frame| moments << moment_of(interpreter, frame, width, height) }
                       .run(program, frames: frames)
            [moments << moment_of(interpreter, :end, width, height), save, interpreter.audio]
          end

          def moment_of(interpreter, frame, width, height)
            Moment.new(frame: frame, variables: interpreter.vars.dup, picture: picture_check(interpreter.screen, width, height),
                       sounds: interpreter.audio.size, sprites: interpreter.sprites,
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
