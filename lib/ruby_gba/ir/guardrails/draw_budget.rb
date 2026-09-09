# frozen_string_literal: true

require_relative "../cost_model"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # The console draws to a single screen the TV is reading at the same time,
        # and there's only a brief safe window each frame to change it. A game that
        # does more drawing than fits in that window spills into the visible frame,
        # so the picture tears — a jagged, flickering image, often with the last
        # thing drawn missing — and it gets worse as the game grows. The classic
        # cause is clearing and repainting the whole screen every frame.
        #
        # This is the cost-model-driven warning: it estimates the *steady* per-frame
        # drawing (what recurs every frame — a once-per-round transition or an
        # every() tick doesn't count) and flags it when it's over the budget. Like
        # the other soft checks it's advisory, not an error: the estimate is rough,
        # and the build still produces a ROM. `rom.explain` shows the breakdown.
        class DrawBudget
          NAME = :draw_budget
          PLAIN_NAME = "drawing that overruns a frame"

          # Takes the cost model rather than building one, because the number in the
          # message is only right when the model knows how the build turned out — which
          # routines went in the quick memory, what shape each loop got. See
          # Guardrails.build_checks.
          def initialize(model)
            @model = model
          end

          def detect(program)
            model = @model
            return [] unless model.looping?(program)

            # A game that switches modes between scenes has no single budget: judge
            # each scene against its own mode's budget, so a heavy direct-color
            # scene is caught even when a buffered scene would otherwise widen the
            # whole-program budget and hide it.
            return per_scene(model, program) if model.mixed?(program)

            budget = model.budget_for(program)
            buffered = model.buffered?(program)
            # What races the vblank window is everything the frame does up to its last write
            # to the screen — the drawing, and whatever the frame did first, which pushed
            # that write later. A double-buffered game can't tear at all, so its risk is the
            # whole frame's recurring work (drawing + logic + sound) against the 60fps budget.
            mixer = model.mixer_verdict(program)&.cost || 0
            steady = buffered ? model.steady_cost(program) + mixer : model.steady_tear_cost(program)
            # A number that is not a number is a fault in the cost model, and this check
            # warns an author about their GAME — so it says nothing rather than something
            # untrue. `rom.explain` banners the fault where it belongs.
            return [] unless steady.to_f.finite?
            return [] if steady <= budget

            message = buffered ? buffered_message(steady, budget) : message(steady, budget)
            # Blame the game loop: the cost this warns about is the work that recurs inside
            # it, so that's where the author starts reading.
            [Finding.new(check: NAME, severity: :warning, message: message, node: game_loop(program))]
          end

          private

          # One warning per over-budget scene, phrased for that scene's mode and
          # blaming that scene, since only its own drawing is over.
          def per_scene(model, program)
            model.scene_verdicts(program).select(&:over?).map do |scene|
              body = if scene.mode == IR::Modes::BUFFERED
                       buffered_message(scene.steady_cost, scene.budget)
                     else
                       message(scene.steady_cost, scene.budget)
                     end
              Finding.new(check: NAME, severity: :warning,
                          message: "Scene :#{scene.name}. #{body}", node: scene.node)
            end
          end

          # The top-level game loop — the same one the cost model's #looping? asks
          # about, so whenever this check speaks there is one to blame.
          def game_loop(program)
            program.children.find { |node| node.kind == :loop }
          end

          # Single-buffered: over budget means the drawing spills past the safe
          # window and the picture tears.
          def message(steady, budget)
            "This game draws a lot every frame: about #{format('%.0f', steady)} scanlines, against a budget of " \
              "about #{budget}. This is more than the console can finish in the short moment it has to change " \
              "the screen. So the picture can tear or flicker, and it gets worse as things grow. The usual " \
              "cause is a full clear and draw of the whole screen each frame. To fix this, draw the fixed parts " \
              "one time. Then each frame, draw only what moved. Or enable double buffering, which cannot tear. " \
              "To see where the per-frame drawing goes, call `rom.explain` on the built ROM."
          end

          # Double-buffered: it can't tear, but drawing this much every frame is
          # more than fits in a frame, so the frame rate drops below 60fps.
          #
          # WHAT THAT LOOKS LIKE is worth getting right, because it is how an author recognises
          # the fault in front of them. It is not choppiness. A game moves what it moves once per
          # pass of its loop, so fewer passes a second is less movement a second: the whole game
          # runs in SLOW MOTION, smoothly. Saying "choppy" sends the reader looking for the wrong
          # thing — and choppy is what the other way of pacing a game looks like.
          def buffered_message(steady, budget)
            "This game draws a lot every frame: about #{format('%.0f', steady)} scanlines, against a whole-frame " \
              "budget of about #{budget}. It does not tear, because double buffering prevents that. But it is " \
              "more than fits in one frame. So the game runs at less than 60 frames a second. A game moves " \
              "things once a frame, so everything in it will also move more slowly: the game runs in slow " \
              "motion rather than losing frames. To fix this, draw less each frame: draw only what moved, not " \
              "the whole screen. To see where the per-frame drawing goes, call `rom.explain` on the built ROM."
          end
        end
      end
    end
  end
end
