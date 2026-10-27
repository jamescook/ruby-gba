# frozen_string_literal: true

require VBlank.root.join("lib/vblank/ir/modes").to_s
require VBlank.root.join("lib/vblank/ir/stacking").to_s

module VBlank
  module IR
    module Guardrails
      module Checks
        # MORE BACKGROUND LAYERS THAN THE CONSOLE CAN STACK.
        #
        # A console stacks so many tile layers, and one that can turn a layer arranges them
        # one of two ways: the Advance has four that scroll and none that turn, or two that
        # scroll plus one that turns and resizes (Console::Description#backgrounds and the
        # two beside it). Nothing in a program picks between them — a background turns
        # because the program turns it, and the build reads the arrangement off that. So a
        # game that turns a layer trades scrolling ones for it, and a game that declares
        # more than the arrangement holds has a layer with nowhere to go. A console that
        # turns nothing, such as the Color, refuses the turning itself
        # (Checks::ConsoleAnswers), so here it is asked only about the layers that scroll.
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
            console = program.described_console
            Stacking.screenfuls(program).each do |screenful|
              found = screenful_finding(screenful, modes, console)
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
          def screenful_finding(screenful, modes, console)
            sharing = console.turns_backgrounds? ? screenful.turning_on_tiled_screen(modes) : []
            if sharing.size > console.turning_backgrounds
              return error_finding(sharing.last, too_many_turning_message(sharing, screenful.scene, console))
            end

            # HOW MANY SCROLLING ONES FIT depends on whether THIS screen holds a turning
            # layer, because that is what decides which arrangement the console is put in as
            # the screen is set up.
            room = console.scrolling_backgrounds(turning: sharing.any?)
            # A status bar is counted where it is one of the layers, and not where the console
            # keeps it a layer of its own (Checks::TooManyStatusBars counts those).
            scrolling = screenful.scrolling
            scrolling = scrolling.reject(&:bar?) unless console.bar_is_a_background
            return nil if scrolling.size <= room

            # The layer blamed is the first one with nowhere to go, so the author is sent to
            # a line that really is past the end rather than to the stack's first layer,
            # which fits.
            error_finding(scrolling[room], too_many_scrolling_message(scrolling, sharing, screenful.scene, console))
          end

          def error_finding(node, message)
            Finding.new(check: NAME, severity: :error, node: node, message: message)
          end

          def too_many_turning_message(turning, scene, console)
            most = console.turning_backgrounds
            "#{screen_subject(scene)} turns or resizes #{turning.size} backgrounds at one time " \
              "(#{name_list(turning)}). The #{console.title} can turn #{background_count_words(most)} at " \
              "one time. To fix this, turn #{background_count_words(most)}, and let the " \
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

          def too_many_scrolling_message(scrolling, sharing, scene, console)
            return scrolling_limit_message(scrolling, scene, console) if sharing.empty?

            scrolling_beside_turner_message(scrolling, sharing.first, scene, console)
          end

          def scrolling_limit_message(scrolling, scene, console)
            most = scrolling_count_words(console.backgrounds, console)
            "#{scrolling_count_sentence(scrolling, scene, console)} The #{console.title} shows #{most} at one time. " \
              "To fix this, show #{most}.#{move_into_scene_hint(scene)}"
          end

          def scrolling_beside_turner_message(scrolling, turner, scene, console)
            most = scrolling_count_words(console.backgrounds_beside_turning, console)
            room = console.backgrounds
            "Background :#{turner.name} turns or resizes. Beside a background that turns, the " \
              "#{console.title} shows #{most} at one time. #{scrolling_count_sentence(scrolling, scene, console)} " \
              "To fix this, show #{most}. Or stop turning :#{turner.name}. " \
              "Then #{scrolling_count_words(room, console)} #{room == 1 ? 'fits' : 'fit'}.#{move_into_scene_hint(scene)}"
          end

          def background_count_words(count) = "#{count} background#{'s' unless count == 1}"

          # A count of backgrounds that pan, said as "scrolling" only on a console where some
          # other kind turns: on one that turns nothing, every background scrolls.
          def scrolling_count_words(count, console)
            console.turns_backgrounds? ? "#{count} scrolling background#{'s' unless count == 1}" : background_count_words(count)
          end

          # WHAT THE COUNT IS ABOUT, said plainly, because the number only makes sense
          # beside it: a game can have many more backgrounds than this, as long as no one
          # screen shows too many. A game that declares no scenes shows everything at once,
          # so for that one the screenful IS the game and saying so would only puzzle.
          def scrolling_count_sentence(scrolling, scene, console)
            "#{screen_subject(scene)} shows #{scrolling_count_words(scrolling.size, console)} at one time " \
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
