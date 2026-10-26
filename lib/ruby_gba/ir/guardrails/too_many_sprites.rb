# frozen_string_literal: true

require RubyGBA.root.join("lib/ruby_gba/ir/stacking").to_s
require RubyGBA.root.join("lib/ruby_gba/ir/movement").to_s
require RubyGBA.root.join("lib/ruby_gba/ir/sprite_rows").to_s
require RubyGBA.root.join("lib/ruby_gba/ir/modes").to_s
require RubyGBA.root.join("lib/ruby_gba/console/hardware").to_s

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # MORE SPRITES THAN A GAME CAN KEEP PLACES FOR.
        #
        # The console composes its sprites from one table of 128 rows, and every sprite a
        # game declares is given a row while the cartridge is built. Sprites of two scenes
        # that are never up together take turns at the same rows (see IR::SpriteRows), so
        # what has to fit is the busiest screen: one scene's sprites with the ones every
        # scene shows.
        #
        # A GAME CAN KEEP MORE ROWS THAN THE CONSOLE DRAWS, up to MOST: a pool keeps a row for
        # every thing it can hold, and a room shows a handful of them. Past 128 the cartridge
        # keeps its rows in a bigger copy of the table and copies the ones showing something
        # into the console's before each frame (see Backends::GBA::SpriteDrawing::HeldTable),
        # so what has to fit in 128 is one frame's sprites. MOST is the most any backend draws
        # in a frame; a game over that has a sprite with nowhere to go.
        #
        # This used to be a number an author counted, until tiled text: the console draws
        # every character of a tiled `draw_text` as a sprite of its own, and a menu is two
        # of those per row, so a game crosses the line by rewording a label. The count
        # alone is no help then. The tree says what every sprite is — a letter's is named
        # by the framework, a pool's comes from its pool, and the rest from the picture
        # the game named — so the refusal says how the places were spent.
        #
        # Like the background layers, the rule lives here so the build, the interpreter
        # and the cartridge lowering refuse the same programs in the same words. A picture
        # too big for one sprite spends several, and that is counted by the lowering,
        # which is the only part that cuts pictures up.
        class TooManySprites
          NAME = :too_many_sprites
          PLAIN_NAME = "more sprites than a game can keep places for"

          MOST = 512

          def detect(program)
            most = most_places(program)
            plan = SpriteRows.plan(program) { 1 }
            return [] if plan.count <= most

            sprites = Stacking.objects_in_draw_order(program)
            message = plan.busiest.count > most ? busiest_message(plan, sprites, most) : between_message(plan, sprites, most)
            [Finding.new(check: NAME, severity: :error, node: sprites.max_by { |node| plan.rows.fetch(node.name) },
                         message: message)]
          end

          # Why the sprites are refused, or nil when they fit.
          def refusal_message(program)
            detect(program).first&.message
          end

          private

          # How many places a game built for +program+'s console can keep: MOST on the Advance,
          # whose cartridge keeps a bigger table than its 128 rows; the forty of a Game Boy Color,
          # which keeps none.
          def most_places(program)
            console = program.described_console
            console.name == Console::DEFAULT ? MOST : console.sprites
          end

          # The busiest screen is over by itself: say how its places were spent.
          def busiest_message(plan, sprites, most)
            on_screen = sprites.select { |node| plan.busiest.names.include?(node.name) }
            letters, rest = on_screen.partition { |node| node.declared.nil? }
            pooled, declared = rest.partition { |node| SpriteWords.pool?(node) }
            shares = [letters_sentence(letters), *pool_sentences(pooled), declared_sentence(declared)].compact
            "#{count_sentence(plan, most)} #{shares.join(' ')}#{between_sentence(plan, sprites)} " \
              "To fix this, use fewer sprites.#{letters_hint(letters)}#{pool_hint(pooled)}"
          end

          # Every screen fits, and the sprites standing between two scenes' are what put the
          # game over: the fix is where they are drawn, not how many there are.
          def between_message(plan, sprites, most)
            names = between_names(plan, sprites)
            "This game needs #{plan.count} places for sprites. A game can keep places for #{most} sprites. " \
              "Each scene fits.#{between_sentence(plan, sprites)} To fix this, put #{names} in a layer " \
              "behind the sprites of every scene, or in a layer in front of all of them."
          end

          def count_sentence(plan, most)
            scenes = plan.busiest.scenes
            return "This game has #{plan.busiest.count} sprites. A game can keep places for #{most} sprites." if scenes.empty?

            named = scenes.map { |scene| ":#{Modes.strip_scene_prefix(scene)}" }
            opening = if named.one?
                        "The #{named.first} scene has #{plan.busiest.count} sprites."
                      else
                        "The #{named.join(' and ')} scenes are on the screen at the same time. Together " \
                          "they have #{plan.busiest.count} sprites."
                      end
            "#{opening} This count includes the sprites that every scene shows. A game can keep places " \
              "for #{most}. The sprites of two scenes that are not on the screen at the same time use " \
              "the same places, so each scene must fit."
          end

          def between_sentence(plan, sprites)
            return "" unless plan.rows_lost_between.positive?

            " But #{between_names(plan, sprites)} keeps the same places in every scene, and it is drawn " \
              "in front of the sprites of one scene and behind the sprites of another. So those two " \
              "scenes cannot use the same places, and #{plan.rows_lost_between} more places are necessary."
          end

          # The sprites standing between two scenes', by the pictures the game named.
          def between_names(plan, sprites)
            pictures = sprites.select { |node| plan.between.include?(node.name) }
                              .map { |node| node.declared ? ":#{node.declared}" : "letters of text" }.uniq
            pictures.join(", ")
          end

          def letters_sentence(letters)
            return nil if letters.empty?

            "#{letters.size} are letters of text: on a tiled screen, the console draws each " \
              "character as a sprite."
          end

          def pool_sentences(pooled)
            pooled.group_by(&:declared).map do |pool, slots|
              "#{slots.size} are the places of pool :#{pool}."
            end
          end

          def declared_sentence(declared)
            return nil if declared.empty?

            pictures = declared.map(&:declared).uniq.map { |name| ":#{name}" }
            "#{declared.size} are sprites the game declared (#{pictures.join(', ')})."
          end

          def letters_hint(letters)
            return "" if letters.empty?

            " For the text, use shorter words. Or draw the text on a `screen :bitmap`, where " \
              "text takes no sprites."
          end

          def pool_hint(pooled)
            return "" if pooled.empty?

            " A pool takes one place for each instance it can hold. For a pool, give it a " \
              "smaller `capacity:`."
          end
        end
      end
    end
  end
end
