# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A GAME BUILT FOR A GAME BOY COLOR, told what the Color does with what it asks for, in
        # the words Console::GBCFeatures has for each verb: once for each thing that is shown
        # differently there (a warning, and the build goes on), and at each line that asks for
        # something the Color cannot do at all (an error, before anything is made).
        #
        # It reads the program the game made for the Color, so a game built for the Advance alone
        # is never told anything here, and one built for both hears it only on the Color's build.
        #
        # One thing is not a verb's: the Color draws ten sprites on any one row of the screen and
        # leaves the rest out of that row. Where sprites that never move — a line of tiled text,
        # say — put more than ten on a row, that row is named.
        class ColorAnswers
          NAME = :color_answers
          PLAIN_NAME = "something a Game Boy Color does differently"

          # The most sprites the Color draws on one row of the screen.
          SPRITES_A_ROW = Console::GBCHardware::SPRITES_ON_A_LINE

          def detect(program)
            return [] unless program.kind == :program && program.described_console.name == :gbc

            nodes = program.walk.to_a
            degraded(nodes) + refused(nodes) + crowded_rows(program, nodes)
          end

          private

          def answer(verb) = Console::GBCFeatures.answer(verb)

          # What is shown differently, once each: the first line that asks for it is blamed. The
          # interpreter shows the same difference when it plays the game for a Color, so the game
          # is still checked pixel for pixel.
          DEGRADED = Ractor.make_shareable({
            affine_background: "This game turns or resizes a background. A Game Boy Color cannot turn or resize a " \
                               "background, so there it is shown as it was drawn. The game plays the same.",
            rotozoom: "This game has a turning screen (`screen :rotozoom`). On a Game Boy Color it is a plain tiled " \
                      "screen, and its background is shown as it was drawn.",
            pixelate: "This game shows the screen in blocks. A Game Boy Color cannot do that, so there the picture " \
                      "stays sharp. The block size still changes, so a scene that waits on it changes on the same frame."
          })

          def degraded(nodes)
            said = {
              affine_background: nodes.find { |node| node.kind == :affine_background },
              rotozoom: nodes.find { |node| node.kind == :screen && node.mode == :rotozoom },
              pixelate: nodes.find { |node| node.kind == :pixelate }
            }
            said.filter_map do |what, node|
              node && Finding.new(check: NAME, severity: :warning, node: node, message: DEGRADED.fetch(what))
            end
          end

          # What the Color cannot do, at every line that asks for it.
          def refused(nodes)
            nodes.filter_map do |node|
              verb, what = refusal_of(node)
              next unless verb

              Finding.new(check: NAME, severity: :error, node: node,
                          message: "#{what}, and a Game Boy Color cannot: #{answer(verb).words}")
            end
          end

          # The verb whose answer refuses +node+, and what the node asks for, or nil.
          def refusal_of(node)
            case node.kind
            when :raw then [:entry, "This line hands the Advance's processor raw instructions (`entry`)"]
            when :shade_outside then [:spotlight, "This game has a light (`spotlight`)"]
            # The layers' declaration, which every see-through layer is in: one whose amounts are
            # written in the program is told to the console once and has no step of its own.
            when :layers
              [:layers, "This game shows one layer through another (`transparency:`)"] unless node.see_through.empty?
            when :camera then [:camera, "This line moves a camera over a painted picture"]
            when :sample, :play_sample then [:sample, "This game plays a recording"]
            when :held, :pressed
              [:held, "This line reads the #{node.button.inspect} button"] if %i[l r].include?(node.button)
            when :fade
              [:fade, "This line fades part of the screen"] if node.under || node.reaches
            end
          end

          # Rows of the screen where sprites that never move — their place and picture written in
          # the program — come to more than ten in one scene, each row named once.
          def crowded_rows(program, nodes)
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
              row, count = counts.select { |r, c| c > SPRITES_A_ROW && r.between?(0, Console::GBCHardware::SCREEN_HEIGHT - 1) }
                                 .min_by(&:first)
              next [] unless row

              blamed = objects.find { |obj| obj.y.value <= row } || :program
              [Finding.new(check: NAME, severity: :warning, node: blamed.respond_to?(:source) ? blamed : program,
                           message: "#{count} pieces of sprites stand on row #{row} of the screen at once. A Game Boy " \
                                    "Color draws ten on any one row and leaves the rest out of it. To fix this, " \
                                    "move some of them to another row, or use fewer letters there.")]
            end
          end

          def fixed?(obj) = %i[x y pose].all? { |field| obj.public_send(field).kind == :int }
        end
      end
    end
  end
end
