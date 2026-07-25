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

          def detect(program)
            model = CostModel.new
            return [] unless model.looping?(program)

            # A game that switches modes between scenes has no single budget: judge
            # each scene against its own mode's budget, so a heavy direct-color
            # scene is caught even when a buffered scene would otherwise widen the
            # whole-program budget and hide it.
            return per_scene(model, program) if model.mixed?(program)

            steady = model.steady_cost(program)
            budget = model.budget_for(program)
            return [] if steady <= budget

            message = model.buffered?(program) ? buffered_message(steady, budget) : message(steady, budget)
            [Finding.new(check: NAME, severity: :warning, message: message, fix: nil)]
          end

          private

          # One warning per over-budget scene, phrased for that scene's mode.
          def per_scene(model, program)
            model.scene_verdicts(program).select { |scene| scene[:over] }.map do |scene|
              body = if scene[:mode] == IR::Modes::BUFFERED
                       buffered_message(scene[:steady_cost], scene[:budget])
                     else
                       message(scene[:steady_cost], scene[:budget])
                     end
              Finding.new(check: NAME, severity: :warning, message: "Scene :#{scene[:name]} — #{body}", fix: nil)
            end
          end

          # Single-buffered: over budget means the drawing spills past the safe
          # window and the picture tears.
          def message(steady, budget)
            "This game looks like it draws a lot every frame (roughly #{format('%.0f', steady)} scanlines vs a " \
              "budget of about #{budget}) — more than the console can finish in the brief moment it has to " \
              "change the screen, so the picture may tear or flicker, and worse as things grow. The usual " \
              "cause is clearing and repainting the whole screen each frame: instead, draw the parts that " \
              "don't change once, and each frame repaint only what actually moved. Or switch on double " \
              "buffering, which can't tear. Call `rom.explain` on the built ROM to see where the per-frame " \
              "drawing goes."
          end

          # Double-buffered: it can't tear, but drawing this much every frame is
          # more than fits in a frame, so the frame rate drops below 60fps.
          def buffered_message(steady, budget)
            "This game draws a lot every frame (roughly #{format('%.0f', steady)} scanlines vs a whole-frame " \
              "budget of about #{budget}). It won't tear — double buffering prevents that — but it's more than " \
              "fits in one " \
              "frame, so the game will run slower than 60 frames a second and feel choppy. Draw less each " \
              "frame: repaint only what actually moved rather than redrawing the whole screen. Call " \
              "`rom.explain` on the built ROM to see where the per-frame drawing goes."
          end
        end
      end
    end
  end
end
