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

            # EVERY COUNT HERE IS ONE SCREENFUL AT A TIME, never across the whole program.
            # The console spends a layer while something is being DRAWN, so what has to fit
            # is what can be on screen together — and two scenes that take turns never are.
            # A game with four scrolling backgrounds in each of two scenes asks for four
            # layers, twice, and fits; so do two scenes that each turn a background of their
            # own. See IR::Stacking#screenfuls, which the lowering allocates from, so the
            # two cannot disagree about which programs fit.
            modes = Modes.resolve(program)
            Stacking.screenfuls(program).each do |screenful|
              found = screenful_finding(screenful, modes)
              return [found] if found
            end
            []
          rescue Modes::Conflict
            # One drawing routine reached from two screens. That error names it, and
            # until it is fixed there is no telling which screen a background is on.
            []
          end

          # Why the layers are refused, or nil when they fit. The two backends come
          # through here, so one rule and one wording serve the build and both of them.
          def refusal_message(program)
            detect(program).first&.message
          end

          private

          # What is wrong with ONE screen, or nil when it fits.
          #
          # The two refusals are in the order that diagnoses best. A screen with two turning
          # backgrounds AND too many scrolling ones is told about the second turner first:
          # cutting a scrolling layer would not save it, and the arrangement it was counted
          # against is not one the console has anyway.
          def screenful_finding(screenful, modes)
            sharing = screenful.turning_on_tiled_screen(modes)
            if sharing.size > MAX_TURNING_LAYERS
              return error_finding(sharing.last, too_many_turning_message(sharing, screenful.scene))
            end

            # HOW MANY SCROLLING ONES FIT depends on whether THIS screen holds a turning
            # layer, because that is what decides which arrangement the console is put in as
            # the screen is set up.
            room = scrolling_layer_limit(sharing)
            scrolling = screenful.scrolling
            return nil if scrolling.size <= room

            # The layer blamed is the first one with nowhere to go, so the author is sent to
            # a line that really is past the end rather than to the stack's first layer,
            # which fits.
            error_finding(scrolling[room], too_many_scrolling_message(scrolling, sharing, screenful.scene))
          end

          def error_finding(node, message)
            Finding.new(check: NAME, severity: :error, node: node, message: message)
          end

          # How many scrolling backgrounds the tiled screen has room for, which depends
          # on whether that screen itself holds one that turns.
          def scrolling_layer_limit(sharing)
            sharing.empty? ? MAX_SCROLLING_LAYERS : MAX_SCROLLING_LAYERS_BESIDE_TURNING
          end

          def too_many_turning_message(turning, scene)
            "#{screen_subject(scene)} turns or resizes #{turning.size} backgrounds at one time " \
              "(#{name_list(turning)}). The console can turn #{MAX_TURNING_LAYERS} background at " \
              "one time. To fix this, turn #{MAX_TURNING_LAYERS} background, and let the " \
              "others scroll.#{move_turner_hint(scene)}"
          end

          # The way out a game with scenes has: scenes take turns, so a background turned in
          # one of them stops counting against the others. Said about the TURNING one here,
          # where #move_into_scene_hint below is about a scrolling one — pointing at the wrong one is
          # advice that cannot be followed.
          def move_turner_hint(scene)
            return "" unless scene

            " Each scene turns its own, so you can also move a background that turns into " \
              "the scene that turns it."
          end

          def too_many_scrolling_message(scrolling, sharing, scene)
            return scrolling_limit_message(scrolling, scene) if sharing.empty?

            scrolling_beside_turner_message(scrolling, sharing.first, scene)
          end

          def scrolling_limit_message(scrolling, scene)
            "#{scrolling_count_sentence(scrolling, scene)} The console shows #{MAX_SCROLLING_LAYERS} scrolling " \
              "backgrounds at one time. To fix this, show #{MAX_SCROLLING_LAYERS} scrolling " \
              "backgrounds.#{move_into_scene_hint(scene)}"
          end

          def scrolling_beside_turner_message(scrolling, turner, scene)
            most = MAX_SCROLLING_LAYERS_BESIDE_TURNING
            "Background :#{turner.name} turns or resizes. Beside a background that turns, the " \
              "console shows #{most} scrolling backgrounds at one time. #{scrolling_count_sentence(scrolling, scene)} " \
              "To fix this, show #{most} scrolling backgrounds. Or stop turning :#{turner.name}. " \
              "Then #{MAX_SCROLLING_LAYERS} scrolling backgrounds fit.#{move_into_scene_hint(scene)}"
          end

          # WHAT THE COUNT IS ABOUT, said plainly, because the number only makes sense
          # beside it: a game can have many more backgrounds than this, as long as no one
          # screen shows too many. A game that declares no scenes shows everything at once,
          # so for that one the screenful IS the game and saying so would only puzzle.
          def scrolling_count_sentence(scrolling, scene)
            "#{screen_subject(scene)} shows #{scrolling.size} scrolling backgrounds at one time " \
              "(#{name_list(scrolling)})."
          end

          def screen_subject(scene) = scene ? "The scene :#{Modes.strip_scene_prefix(scene)}" : "This game"

          # The way out a game with scenes has and a game without does not: scenes take
          # turns, so scenery moved into one of them stops counting against the others.
          def move_into_scene_hint(scene)
            return "" unless scene

            " Each scene gets its own layers, so you can also move a background into a " \
              "scene that has room."
          end

          def name_list(nodes) = nodes.map { |node| ":#{node.name}" }.join(", ")
        end
      end
    end
  end
end
