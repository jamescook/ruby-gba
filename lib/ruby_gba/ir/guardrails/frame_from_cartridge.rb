# frozen_string_literal: true

require_relative "../cost_model"
require_relative "../../plain_words"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # The game loop's body is the single most valuable thing to keep in the console's
        # quick memory — it is where nearly all of a frame's time goes, and code there runs
        # about two and a half times faster than code fetched from the cartridge. The build
        # offers it the memory first. When it does not FIT, the whole frame runs from the
        # cartridge, and the game is slower by that factor for a reason nothing else in a
        # build can show.
        #
        # WHY THIS ONE NEEDS SAYING OUT LOUD: everything about it points the wrong way. It
        # happened on games/wolf3d: ten guards were given a few dozen statements of thinking
        # each frame, and a 468-scanline frame went to 1140. None of it was the work — taking
        # the thinking out put the frame straight back, taking any one part of it out changed
        # nothing. The statements made the loop's body too big to fit, so the loop was left in
        # the cartridge and the rays, the columns and the fills all ran from there. The symptom
        # is a slowdown spread evenly over code the author did not touch; bisecting by removing
        # the new work finds nothing, because the new work is not the cost, its presence is;
        # and the instinct to optimise what was just added is exactly wrong. The fix was one
        # word — put the thinking in a routine of its own, marked `fast: false` — and that is
        # what the message says.
        #
        # The chooser records what it passed over (see Backends::GBA::Placement#place_by_frame_cost),
        # so this only has to read it. A build with no chooser at all (`fast_code: false`)
        # passes nothing over and says nothing.
        class FrameFromCartridge
          NAME = :frame_from_cartridge
          PLAIN_NAME = "the game loop running from the cartridge"

          def initialize(model)
            @model = model
          end

          def detect(program)
            frame = Backends::GBA::Placement::FRAME_ROUTINE
            over = @model.placement&.passed_over&.find { |o| o.name == frame } or return []
            loop_node = program.children.find { |node| node.kind == :loop } or return []

            [Finding.new(check: NAME, severity: :warning, message: message(over), node: loop_node)]
          end

          private

          def message(over)
            "The game loop's body did not fit in the console's #{PlainWords::QUICK_MEMORY}. It needs " \
              "#{kb(over.bytes)}, and #{kb(over.room)} was free when its turn came. So the whole frame " \
              "runs from the cartridge, at about two and a half times slower than it could. The cause " \
              "is not the work the loop does. The cause is how much code is in it. The usual cause is a " \
              "large piece of code in the loop that seldom runs. To fix this, move that code into a " \
              "`func` of its own, and mark it `fast: false`. Then the loop is small enough to fit, and " \
              "the rare code runs from the cartridge only when it runs. To see what was kept in the " \
              "#{PlainWords::QUICK_MEMORY} and what was not, call `rom.explain` on the built ROM."
          end

          def kb(bytes) = format("%.1fK", bytes / 1024.0)
        end
      end
    end
  end
end
