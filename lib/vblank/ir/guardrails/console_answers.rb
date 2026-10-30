# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A GAME TOLD AT EACH LINE THAT ASKS FOR SOMETHING ITS CONSOLE CANNOT DO, in the words that
        # console's answers have for the verb: an error, before anything is made. What a console
        # cannot do is the answers' to say (Console::Answers#refusals), and this only reports it.
        # Nothing is shown differently on any console, so nothing is only warned of but a crowded
        # row (below).
        #
        # It asks the console the program was made for, through its kit, so a game for two
        # consoles hears on each build only what that console cannot do. The Advance does every
        # verb and has every part of one, so a game for it alone is never told anything here.
        #
        # One thing is not a verb's: a console that draws only so many sprites on one row of the
        # screen leaves the rest out of that row. Where sprites that never move — a line of tiled
        # text, say — put more than that on a row, that row is named.
        class ConsoleAnswers
          NAME = :console_answers
          PLAIN_NAME = "something the console cannot do"

          def detect(program)
            return [] unless program.kind == :program

            console = program.described_console
            nodes = program.walk.to_a
            refused = Console.for(console.name).answers.refusals(nodes, console).map do |refusal|
              Finding.new(check: NAME, severity: :error, node: refusal.node, message: refusal.words)
            end
            refused + crowded_rows(program, nodes, console)
          end

          private

          # Rows of the screen where sprites that never move — their place and picture written in
          # the program — come to more than +console+ draws on one row in one scene, each row named
          # once. A console whose rows the build does not count (Console::Description#sprites_a_row)
          # is told nothing.
          def crowded_rows(program, nodes, console)
            most = console.sprites_a_row or return []
            pictures = nodes.select { |node| node.kind == :bitmap }.to_h { |node| [node.name, node] }
            nodes.select { |node| node.kind == :object && fixed?(node) }.group_by(&:scene).flat_map do |_, objects|
              counts = Hash.new(0)
              objects.each do |obj|
                picture = pictures[obj.poses.first]
                next unless picture

                top = obj.y.value
                columns = (picture.width + 7) / 8
                (top...(top + picture.height)).each { |row| counts[row] += columns }
              end
              row, count = counts.select { |r, c| c > most && r.between?(0, console.screen_height - 1) }.min_by(&:first)
              next [] unless row

              blamed = objects.find { |obj| obj.y.value <= row } || :program
              [Finding.new(check: NAME, severity: :warning, node: blamed.respond_to?(:source) ? blamed : program,
                           message: "#{count} pieces of sprites stand on row #{row} of the screen at once. A " \
                                    "#{console.title} draws #{most} on any one row and leaves the rest out of it. " \
                                    "To fix this, move some of them to another row, or use fewer letters there.")]
            end
          end

          def fixed?(obj) = %i[x y pose].all? { |field| obj.public_send(field).kind == :int }
        end
      end
    end
  end
end
