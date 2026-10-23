# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A GAME BUILT FOR A GAME BOY COLOR, told at each line that asks for something the Color's
        # hardware cannot do, in the words Console::GBCFeatures has for the verb: an error, before
        # anything is made. Nothing is shown differently on the Color, so nothing is only warned of
        # but a crowded row (below).
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
            refused(nodes) + second_backgrounds(program) + crowded_rows(program, nodes)
          end

          private

          def answer(verb) = Console::GBCFeatures.answer(verb)

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
            when :sample, :play_sample then [:sample, "This game plays a recording"]
            when :held, :pressed
              [:held, "This line reads the #{node.button.inspect} button"] if %i[l r].include?(node.button)
            when :fade
              [:fade, "This line fades part of the screen"] if node.under || node.reaches
            when :affine_background then [:background, "This line turns or resizes a background"]
            when :screen
              [:screen, "This game has a turning screen (`screen :rotozoom`)"] if node.mode == :rotozoom
            when :pixelate then [:pixelate, "This line shows the screen in blocks (`pixelate`)"]
            when :object
              [:sprite, "This sprite turns or resizes (`scale`, `face_angle`, `turn`, `pulse`)"] if turns?(node)
            end
          end

          # A sprite turns or resizes when its angle or its size is anything but the one it is drawn
          # at: upright, as drawn (Build#object's defaults).
          def turns?(obj)
            !(obj.angle.kind == :int && obj.angle.value.zero? && obj.scale.kind == :int && obj.scale.value == Build::SCALE_ONE)
          end

          # A SECOND BACKGROUND SHOWING AT ONCE. The Color shows one background: the backgrounds
          # up together while a scene runs are the scenery every screen shows and the scene's own
          # (IR::SceneHandover#showing), and a background declared in no scene — in the game loop or
          # a plain routine — is up on every screen. Each background past the first that shows with
          # another is refused at its line, once.
          def second_backgrounds(program)
            scenery = Stacking.picture(program).scenery
            handover = SceneHandover.of(program)
            [nil, *scenery.filter_map(&:scene)].uniq.flat_map { |scene| handover.showing(scene).drop(1) }.uniq.map do |bg|
              Finding.new(check: NAME, severity: :error, node: bg,
                          message: "This line shows a second background while another is showing, and a Game Boy " \
                                   "Color cannot: #{answer(:background).words}")
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
