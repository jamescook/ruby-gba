# frozen_string_literal: true

require RubyGBA.root.join("lib/ruby_gba/ir/stacking").to_s

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # ONE SPRITE, PICTURES GIVEN DIFFERENT LISTS OF COLORS.
        #
        # A sprite's pixels are not colors. Each is a small number, a place in a list of
        # sixteen colors, and which list that is gets said once for the whole sprite, in its
        # row of the table the console composes from. So every picture a sprite can show is
        # drawn from the one list, and pictures that each came with a list of their own
        # cannot all be shown by one sprite: whichever list the row names, the others'
        # pictures come out in the wrong colors.
        #
        # A pool is the same thing many times over. Each of its places is a sprite, and any
        # of them can show any of the pool's pictures.
        #
        # Like the count of sprites, the rule lives here so the build, the interpreter and
        # the cartridge lowering refuse the same programs in the same words. The interpreter
        # has no table and no rows — it paints each picture in whatever colors it holds — so
        # without this a game's own tests were green there for a game that could not be built.
        class PosesWithDifferentColors
          NAME = :poses_with_different_colors
          PLAIN_NAME = "a sprite whose pictures have different lists of colors"

          def detect(program)
            lists = program.walk.select { |node| node.kind == :bitmap }.to_h { |node| [node.name, node.colors] }
            sprites = Stacking.objects_in_draw_order(program).uniq { |node| [node.declared || node.name, node.poses] }
            sprites.filter_map do |node|
              by_list = picture_for_each_list(node, lists)
              next if by_list.size < 2

              Finding.new(check: NAME, severity: :error, node: node, message: message(node, by_list))
            end
          end

          # Why the sprites are refused, or nil when every one draws from one list.
          def refusal_message(program)
            detect(program).first&.message
          end

          private

          # Each different list this sprite's pictures were given, with the first picture given
          # it. A picture given none is filed under nil. A pose naming no declared picture is
          # left out: that is a different mistake, with words of its own.
          def picture_for_each_list(node, lists)
            node.poses.uniq.select { |pose| lists.key?(pose) }.group_by { |pose| lists[pose] }.transform_values(&:first)
          end

          def message(node, by_list)
            "#{SpriteWords.owner_capitalized(node)} #{disagreement_sentence(by_list)} The console draws all " \
              "the pictures of one sprite from one list of colors.#{pool_note(node)} To fix this, give all " \
              "its pictures the same `colors:` list. Or give none of them a `colors:` list. Then the " \
              "framework makes the list. To change the colors of one #{SpriteWords.member_word(node)}, tell " \
              "it to `draw_with` a list that `colors` declares."
          end

          # A picture with a list beside one with none is said as that, since "different lists"
          # would send the author looking for a second list that is not there.
          def disagreement_sentence(by_list)
            bare = by_list[nil]
            listed = by_list.except(nil).values
            if bare
              return "shows a picture that has a `colors:` list (:#{listed.first}) and a picture that has " \
                     "none (:#{bare})."
            end

            named = listed.first(3).map { |picture| ":#{picture}" }.join(" and ")
            "shows pictures that have different `colors:` lists (#{named})."
          end

          def pool_note(node)
            SpriteWords.pool?(node) ? " Each instance of a pool is one sprite." : ""
          end
        end
      end
    end
  end
end
