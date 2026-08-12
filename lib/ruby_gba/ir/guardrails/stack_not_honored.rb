# frozen_string_literal: true

require_relative "../modes"
require_relative "../stacking"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A stack a bitmap screen does not honor.
        #
        # The two screens hold a picture in ways that are not alike. A tiled screen
        # holds its backgrounds and sprites and paints them again for every frame, so
        # what is in front of what is a live question and the answer can be anything.
        # A bitmap screen has one picture and everything paints straight into it,
        # where it is declared — after which it is not a background or a sprite at
        # all, only pixels somebody already painted. So on a bitmap screen the order
        # is the order the declarations ran, and a layer does not change it.
        #
        # Most stacks ask for the order the declarations already give — scenery
        # declared first, the things that move after it — and those are silent,
        # because the picture is right and saying anything would be a false alarm on
        # a working game. This speaks only when the two orders differ, and then it
        # shows both: what the stack asks for, and what the screen will show. Nothing
        # else ever mentions it. The game runs, the picture is simply not the one the
        # stack describes, and the stack is the one line a reader trusts for this.
        #
        # It is handed the build's software sprites, because a software sprite's
        # layer is not in the tree — it paints with the same node an author's `blit`
        # builds, and that node belongs to the paint, not to the sprite.
        class StackNotHonored
          NAME = :stack_not_honored

          # @param sprites [Array<Sprite>] the build's software sprites, in the order
          #   they were declared. Empty for a check run over a tree alone.
          def initialize(sprites = [])
            @sprites = sprites
          end

          def detect(program)
            declared = program.walk.find { |node| node.kind == :layers }
            return [] if declared.nil? || declared.names.empty?

            # Fewer than two things in the stack come back unmoved, so the comparison
            # below answers "nothing to say" on its own and needs no case of its own.
            painted = painted_in_order(program)
            asked = Stacking.order(painted, declared.names, &:layer)
            return [] if asked.each_index.all? { |at| asked[at].equal?(painted[at]) }

            [Finding.new(check: NAME, severity: :warning, node: declared,
                         message: message(asked, painted))]
          end

          private

          # Everything a layer can hold that a bitmap screen paints, in the order the
          # painting happens. Backgrounds come off the tree; software sprites are the
          # ones the build handed us. Both are in declaration order, and a background
          # is declared before the sprites that stand on it, so one list after the
          # other is that order.
          #
          # Only the backgrounds are asked which screen they are on. A sprite does not
          # have to be: the build's sprite list is the SOFTWARE ones, and a tiled scene
          # makes hardware sprites the console composites in whatever order it is told.
          def painted_in_order(program)
            modes = Modes.resolve(program)
            scenery = program.walk.select do |node|
              node.kind == :background && Modes::BITMAP_MODES.include?(modes.mode_at(node))
            end
            (scenery + @sprites).select(&:layer)
          rescue Modes::Conflict
            # One drawing routine reached from two screen modes. That error names it,
            # and until it is fixed there is no one mode to judge a picture in.
            []
          end

          def message(asked, painted)
            "This game draws with `screen :bitmap`, and its stack asks for an order that " \
              "screen does not give. A bitmap screen has one picture. Everything paints " \
              "into it where you declare it, so the picture comes out in the order the " \
              "declarations run. The stack asks for #{list_of(asked)}, back to front. " \
              "The screen will show #{list_of(painted)}. To fix this, use `screen :tiled`. " \
              "There the console draws each background and each sprite every frame, and the " \
              "stack decides what is in front. Or declare them in the order you want them " \
              "painted."
          end

          def list_of(things)
            things.map { |thing| ":#{name_of(thing)}" }.join(", ")
          end

          def name_of(thing)
            thing.respond_to?(:picture_name) ? thing.picture_name : thing.name
          end
        end
      end
    end
  end
end
