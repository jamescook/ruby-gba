# frozen_string_literal: true

require_relative "../modes"
require_relative "../stacking"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # MORE BACKGROUND LAYERS THAN THE CONSOLE CAN STACK.
        #
        # The console arranges its tile layers one of two ways: four that scroll and
        # none that turn, or two that scroll plus one that turns and resizes. Nothing
        # in a program picks between them — a background turns because the program
        # turns it, and the build reads the arrangement off that. So a game that turns
        # a layer trades two scrolling ones for it, and a game that declares more than
        # the arrangement holds has a layer with nowhere to go.
        #
        # A layer with nowhere to go is simply not drawn, which reads as a bug in the
        # art rather than as a budget. So this refuses the program and names both
        # counts.
        #
        # WHY IT IS A GUARDRAIL AND NOT ONLY THE LOWERING'S BUSINESS. The rule is a
        # fact about the console, knowable from the program the moment it is written.
        # Left in the lowering it reached only a game that built a cartridge — and a
        # game's own tests run on the headless interpreter, because that is fast and
        # needs no emulator. So the author got a green suite and, later and from a
        # backend they were not working in, a failed build. Both backends now come
        # here, and so does the build before either of them, so all three refuse the
        # same programs in the same words.
        #
        # TWO REFUSALS, IN THE ORDER THAT DIAGNOSES BEST. A program with two turning
        # backgrounds AND too many scrolling ones is told about the second turner
        # first: cutting a scrolling layer would not save it, and the arrangement it
        # was counted against is not one the console has anyway.
        class TooManyBackgroundLayers
          NAME = :too_many_background_layers
          PLAIN_NAME = "more backgrounds than the console stacks"

          # The four layers the console stacks when nothing turns...
          MAX_SCROLLING_LAYERS = 4

          # ...and how many are left once one of them turns. That is the console's own
          # arithmetic, not a budget this framework invented.
          MAX_SCROLLING_LAYERS_BESIDE_TURNING = 2

          # One background can turn and resize; the second has no hardware to turn on.
          MAX_TURNING_LAYERS = 1

          def detect(program)
            # A `background` on a bitmap screen is stamped into that screen's one picture
            # where it is declared and is not a layer afterwards, so a program with no
            # tile screen anywhere has no layers to run out of however many it writes.
            return [] unless Modes.draws_with_tiles?(program)

            turning, scrolling = Stacking.picture(program).scenery.partition(&:affine)
            return [refusal_of(turning.last, only_one_can_turn(turning))] if turning.size > MAX_TURNING_LAYERS

            # WHICH SIDE IS COUNTED PER SCREEN. A program can put two screens on in turn
            # and each holds its own layers, so a background that turns on `screen
            # :rotozoom` is up at a different moment and costs the tiled screen nothing
            # — a title that zooms handing over to a game with four scrolling layers is
            # two arrangements one after the other, and it fits.
            #
            # The SCROLLING ones are counted across the whole program, because the build
            # hands every declared background a hardware layer up front rather than per
            # scene. So two tiled scenes of three layers each are counted as six. That is
            # the lowering's arithmetic and this repeats it deliberately: the two must
            # refuse the same programs, and loosening it here alone would let a build
            # through that then has nowhere to put the layers.
            sharing = Modes.resolve(program).on_the_tiled_screen(turning)
            room = room_beside(sharing)
            return [] if scrolling.size <= room

            # The layer blamed is the first one with nowhere to go, so the author is
            # sent to a line that really is past the end rather than to the stack's
            # first layer, which fits.
            [refusal_of(scrolling[room], no_room_to_stack(scrolling, sharing))]
          rescue Modes::Conflict
            # One drawing routine reached from two screens. That error names it, and
            # until it is fixed there is no telling which screen a background is on.
            []
          end

          # Why the layers are refused, or nil when they fit. The two backends come
          # through here, so one rule and one wording serve the build and both of them.
          def refusal(program)
            detect(program).first&.message
          end

          private

          def refusal_of(node, message)
            Finding.new(check: NAME, severity: :error, node: node, message: message)
          end

          # How many scrolling backgrounds the tiled screen has room for, which depends
          # on whether that screen itself holds one that turns.
          def room_beside(sharing)
            sharing.empty? ? MAX_SCROLLING_LAYERS : MAX_SCROLLING_LAYERS_BESIDE_TURNING
          end

          def only_one_can_turn(turning)
            "This game turns or resizes #{turning.size} backgrounds (#{named(turning)}). The " \
              "console can turn #{MAX_TURNING_LAYERS} background. To fix this, turn " \
              "#{MAX_TURNING_LAYERS} background, and let the others scroll."
          end

          def no_room_to_stack(scrolling, sharing)
            return nothing_turns(scrolling) if sharing.empty?

            beside_a_turning_layer(scrolling, sharing.first)
          end

          def nothing_turns(scrolling)
            "#{how_many(scrolling)} The console stacks #{MAX_SCROLLING_LAYERS} scrolling " \
              "backgrounds. To fix this, use #{MAX_SCROLLING_LAYERS} scrolling backgrounds."
          end

          def beside_a_turning_layer(scrolling, turner)
            most = MAX_SCROLLING_LAYERS_BESIDE_TURNING
            "Background :#{turner.name} turns or resizes. Beside a background that turns, the " \
              "console holds #{most} scrolling backgrounds. #{how_many(scrolling)} To fix this, " \
              "use #{most} scrolling backgrounds. Or stop turning :#{turner.name}, and then " \
              "#{MAX_SCROLLING_LAYERS} scrolling backgrounds fit."
          end

          def how_many(scrolling)
            "This game declares #{scrolling.size} scrolling backgrounds (#{named(scrolling)})."
          end

          def named(nodes) = nodes.map { |node| ":#{node.name}" }.join(", ")
        end
      end
    end
  end
end
