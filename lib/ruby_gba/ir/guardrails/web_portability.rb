# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A GAME BUILT FOR A BROWSER TOO, told which of its lines keep it on the console.
        #
        # Nearly everything a game says — move, draw, play a note — means the same on the
        # console, on a desktop and in a browser, and the JavaScript lowering plays it the same.
        # A few kinds of step mean something only on the console itself: raw instructions handed
        # to its processor (`entry`), or a reading of where its display has got to. IR::Portability
        # tags those kinds; this check reads the tags rather than keeping a list of its own, so a
        # kind tagged there tomorrow is flagged here with nothing to change.
        #
        # It is not one of the checks every build runs: a game made only for the console is free
        # to reach for the console, and nobody should be told off for it. It runs on every web
        # build (JS#checked_program), where a console-only step is an error, said before anything
        # is written. A game meant for both can also register it, so its cartridge builds say the
        # same thing early, while the line is still fresh — as a warning there, since the
        # cartridge itself is fine:
        #
        #   RubyGBA::IR::Guardrails.register(RubyGBA::IR::Guardrails::Checks::WebPortability.new)
        class WebPortability
          NAME = :web_portability
          PLAIN_NAME = "a step a browser cannot run"

          # What each console-only kind is, said for a person, and what to write instead. A kind
          # with no words here is still found (Portability decides that), and is said in the
          # words of OTHERWISE.
          SAID = Ractor.make_shareable({
                                         raw: ["raw instructions for the console's processor (`entry`)",
                                               "Do the same with the framework's own words, such as `set!`, " \
                                               "`pixel` and `if_held`, which every build understands."],
                                         read_scanline: ["a reading of which line the console's screen is drawing",
                                                         "Work it out from the frame count instead, which every " \
                                                         "build keeps."]
                                       })
          OTHERWISE = ["a step that only the console itself can run",
                       "Do the same with the framework's own words, which every build understands."].freeze

          # +severity+ is :warning where the build goes ahead regardless (a cartridge), and :error
          # where the step stops it (the web build).
          def initialize(severity: :warning)
            @severity = severity
          end

          # One finding for each console-only step, in the order the program holds them, each
          # blaming its own line.
          def detect(program)
            program.walk.select { |node| Portability.hardware_only?(node) }.map do |node|
              Finding.new(check: NAME, severity: @severity, message: message_for(node.kind), node: node)
            end
          end

          private

          def message_for(kind)
            what, instead = SAID.fetch(kind, OTHERWISE)
            "This line uses #{what}. A browser does not have that processor or that screen, so a game " \
              "with this line cannot be built for the web. #{instead} A game built only for the console " \
              "can keep this line."
          end
        end
      end
    end
  end
end
