# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # A game played as C (HeadlessRun), and then the same buttons, frame for frame, played on
        # the interpreter — stopping at the first frame the two disagree on, about any variable,
        # any list or pool, any pixel, which sprites were drawn and where, or which recordings
        # the mixer is sounding — and at the end, about every slice of mixed sound and how many
        # sounds a full mixer lost. A game that saves is played both ways from the same save
        # memory, and the two have to end the run with the same bytes in it.
        #
        # It takes the interpreter's calls, so a test written against Reference.new can be handed
        # one of these instead and play its game as C with nothing else changed:
        #
        #   run = RubyGBA::IR::Backends::Native::CheckedRun.new
        #   run.input_each_frame { |frame| frame < 30 ? [:right] : [] }.run(game.program, frames: 60)
        #   run[:x]
        #
        # A run the two disagree on raises Disagreement, saying the frame and everything that
        # differs there. It needs zig, as every native build does.
        #
        # A test that watches the run (each_vblank) watches the game as C, as it goes; the
        # interpreter is played afterwards, and nothing is watched twice.
        #
        # That is what makes playing a test's game this way worth more than the test's own checks.
        # Those look at the pixels and variables whoever wrote them thought to look at; this looks
        # at everything, at every frame, so a native lowering that draws something wrong where no
        # test was looking still fails. The buttons are the ones the native run was actually
        # given, so an input script that decided from what the game was doing is replayed exactly,
        # without being asked again. (A run by step budget does ask the script once more,
        # beforehand: see #frames_within.)
        #
        # Pictures are compared by a check number for each frame (see HeadlessRun::Moment), which
        # is what keeps a long run cheap; only a run that fails is played again in full, to say
        # where.
        class CheckedRun
          include Differences
          extend Differences

          Moment = HeadlessRun::Moment

          # The game as C and the interpreter disagreed. The message says the frame and everything
          # that differs there.
          class Disagreement < StandardError; end

          # Why a game the interpreter stops only by its step budget cannot be played as C.
          NO_STEP_COUNT = "the native lowering keeps no count of its steps"

          # Every frame's buttons reach the native run through one script, which keeps them for
          # the replay: the test's own script when it gave one, else whatever it held for the
          # whole run. +save+ is the save memory the game starts with, as the interpreter takes
          # it, and it holds what the game as C left in it once the run is over.
          def initialize(save: SaveImage.new)
            @save = save
            @native = headless_run(save)
            @played = {}
            @held = []
            @native.input_each_frame { |frame| @played[frame] = buttons_for(frame) }
          end

          # Held from power-on too, before the game's first statement, on both sides.
          def hold(*buttons)
            @held = buttons
            @native.hold(*buttons)
            self
          end

          def input_each_frame(&script)
            @script = script
            self
          end

          # The native run does the watching, so the block reads the game as C at each frame
          # boundary. This is what comes back, and not the native run: the run a test goes on to
          # make from here has to be the checked one.
          def each_vblank(&block)
            @native.each_vblank(&block)
            self
          end

          # +frames+ as the interpreter counts them. A step budget alone (+max_steps+) is the
          # interpreter's own measure, and the C keeps no count of its steps — so the interpreter
          # says how many frames fit in the budget, and the C plays that many. Beside +frames+ a
          # budget only guards one frame of the interpreter, and means nothing here.
          def run(program, max_steps: nil, frames: nil)
            frames ||= max_steps ? frames_within(program, max_steps) : Reference::DEFAULT_FRAMES
            refuse_endless_game_without_frames!(program, max_steps)
            interpreters_save = save_as_handed_over
            @native.run(program, frames: frames)
            interpreter, moments = play_on_interpreter(program, frames, interpreters_save)
            difference = self.class.first_difference(moments, @native.moments) ||
                         self.class.sounds_difference(interpreter.audio, @native.audio_played) ||
                         self.class.mix_difference(interpreter.mixed_sound, @native.mixed_sound) ||
                         self.class.drops_difference(interpreter.sound_drops, @native.sound_drops) ||
                         self.class.save_difference(interpreters_save, @save)
            raise Disagreement, disagreement_message(difference, program, frames) if difference

            self
          end

          def [](name) = @native[name]
          def screen = @native.screen

          # Everything else is the native run's to answer, or to say it cannot yet.
          def method_missing(name, ...) = @native.public_send(name, ...)
          def respond_to_missing?(name, include_private = false) = @native.respond_to?(name, include_private)

          private

          # The run of the game this checks: the game as C with no window. JS::CheckedRun checks
          # the game as JavaScript, by the same moments, and makes its own run here.
          def headless_run(save) = HeadlessRun.new(save: save)

          # What a disagreement calls the lowering it found.
          def lowering_name = "the native lowering"

          # How many frames the interpreter plays in +max_steps+ steps: it stops a game on the
          # frame boundary after the budget runs out, so a run by budget is a run of that many
          # whole frames. The buttons are asked of the test's own script here and again on the
          # native run, so a script that reads the game sees it as it stood before this run.
          def frames_within(program, max_steps)
            lead = interpreter_from(save_as_handed_over).input_each_frame { |frame| buttons_for(frame) }
                                                        .run(program, max_steps: max_steps)
            return lead.frame unless lead.frame.zero? && lead.stopped_at_budget?

            raise HeadlessRun::CannotAnswer, "this game spends the whole step budget before it first waits for the " \
                                             "screen, so the budget is all that stops it, and #{NO_STEP_COUNT}"
          end

          # A game that never waits for the screen has no frames for a count of them to stop. The
          # interpreter stops it at its step budget; the C keeps no count of its steps, and would
          # play on until HeadlessRun gave up on it a minute later. Such a game never asks for a
          # frame's buttons, so the interpreter can be asked first, with only the buttons held
          # from power-on, whether it comes to an end by itself, inside the test's own step
          # budget when it gave one.
          #
          # A game whose only wait is in a routine nothing calls, or after a loop that never ends,
          # is not caught here and still runs for that minute: asking the interpreter first about
          # every game would play every test twice over.
          def refuse_endless_game_without_frames!(program, max_steps)
            return if program.walk.any? { |node| node.kind == :wait_vblank }
            return unless interpreter_from(save_as_handed_over).run(program, max_steps: max_steps).stopped_at_budget?

            raise HeadlessRun::CannotAnswer, "this game never waits for the screen, so it has no frames to count: the " \
                                             "interpreter's step budget is all that stops it, and #{NO_STEP_COUNT}"
          end

          # The interpreter starting from +save+, with the buttons held for the whole run down
          # from power-on, as the game as C has them.
          def interpreter_from(save) = Reference.new(save: save).hold(*@held)

          def buttons_for(frame) = @script ? Array(@script.call(frame)) : @held

          # A save memory of the interpreter's own holding what this run's holds now, and cut at
          # the same step where a cut is waiting — taken before the game as C plays, which leaves
          # its own bytes in the one the test handed over.
          def save_as_handed_over
            copy = @save.dup
            copy.cut_power_after(@save.power_left) if @save.power_left
            copy
          end

          # The interpreter played on the same buttons from +save+, and its moments.
          def play_on_interpreter(program, frames, save)
            interpreter = interpreter_from(save)
            moments = []
            interpreter.input_each_frame { |frame| @played.fetch(frame, []) }
                       .each_vblank { |frame| moments << moment_of(interpreter, frame) }
                       .run(program, frames: frames)
            [interpreter, moments << moment_of(interpreter, :end)]
          end

          def moment_of(interpreter, frame)
            Moment.new(frame: frame, variables: interpreter.vars.dup, picture: HeadlessRun.picture_check(interpreter.screen.shown),
                       sounds: interpreter.audio.size, sprites: interpreter.sprites,
                       collections: interpreter.game_state.except(:vars), sounding: interpreter.active_samples)
          end

          # A picture that differs is played again with every pixel of every frame, to say where.
          def disagreement_message(difference, program, frames)
            message = "#{lowering_name} and the interpreter disagree at #{difference}"
            return message unless difference.include?("picture")

            want = reference_snapshots(program, frames: frames, buttons: @played, held: @held)
            got = lowered_snapshots(program, frames: frames, buttons: @played, mode: :checked, held: @held)
            first = want.zip(got).find { |reference, native| reference.picture != native.picture }
            first ? "#{message} (#{first.last.heading}: #{picture_difference(first.first.picture, first.last.picture)})" : message
          end
        end
      end
    end
  end
end
