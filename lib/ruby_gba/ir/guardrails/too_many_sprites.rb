# frozen_string_literal: true

require_relative "../stacking"
require_relative "../../console/hardware"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # MORE SPRITES THAN THE CONSOLE HAS PLACES FOR.
        #
        # The console composes its sprites from one table of 128 rows, and every sprite a
        # game declares is given a row of its own for the whole game — in every scene, not
        # only the one showing — because the rows are handed out while the cartridge is
        # built. So a game with more than that has a sprite with nowhere to go.
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
          PLAIN_NAME = "more sprites than the console has places for"

          MOST = Console::Hardware::MAX_SPRITES

          def detect(program)
            sprites = Stacking.objects_in_draw_order(program)
            return [] if sprites.size <= MOST

            [Finding.new(check: NAME, severity: :error, node: sprites[MOST], message: message(sprites))]
          end

          # Why the sprites are refused, or nil when they fit.
          def refusal_message(program)
            detect(program).first&.message
          end

          private

          def message(sprites)
            letters, rest = sprites.partition { |node| node.declared.nil? }
            pooled, declared = rest.partition { |node| pool?(node) }
            shares = [letters_sentence(letters), *pool_sentences(pooled), declared_sentence(declared)].compact
            "This game has #{sprites.size} sprites. The console has places for #{MOST}, and each " \
              "sprite takes one for the whole game, in every scene. #{shares.join(' ')} " \
              "To fix this, use fewer sprites.#{letters_hint(letters)}#{pool_hint(pooled)}"
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

          # A pool's slots carry the pool's name as the one they were declared under, and a
          # name of the framework's own.
          def pool?(node) = node.name.to_s.start_with?("__pool_#{node.declared}_")
        end
      end
    end
  end
end
