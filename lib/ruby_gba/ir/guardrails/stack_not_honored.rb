# frozen_string_literal: true

require_relative "../modes"
require_relative "../stacking"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A BACKGROUND a bitmap screen cannot move in the stack.
        #
        # A bitmap screen has one picture, and a `background` there stamps its tiles
        # straight into it where it is declared. After that it is not a background at
        # all, only pixels somebody already painted, and no ordering applied later can
        # reach back and move them. So the order backgrounds come out in is the order
        # the declarations ran, whatever the stack says.
        #
        # SPRITES ARE NOT LIKE THAT, and used to be caught here too. A software sprite
        # is repainted every frame, so its place in the stack is a live question the
        # frame boundary answers — it draws them back to front and erases them front to
        # back (see Builder::ControlFlow#emit_frame_boundary). A stack that reorders
        # sprites is honored, so this says nothing about them.
        #
        # Most stacks ask for the order the declarations already give — scenery
        # declared first, the things that move after it — and those are silent,
        # because the picture is right and saying anything would be a false alarm on
        # a working game. This speaks only when the two orders differ, and then it
        # shows both: what the stack asks for, and what the screen will show. Nothing
        # else ever mentions it. The game runs, the picture is simply not the one the
        # stack describes, and the stack is the one line a reader trusts for this.
        class StackNotHonored
          NAME = :stack_not_honored

          # @param sprites [Array<Sprite>] the build's software sprites, in the order
          #   they were declared — a sprite's layer lives on its handle rather than in
          #   the tree. Empty for a check run over a tree alone.
          def initialize(sprites = [])
            @sprites = sprites
          end

          def detect(program)
            declared = program.walk.find { |node| node.kind == :layers }
            return [] if declared.nil? || declared.names.empty?

            # Fewer than two things in the stack come back unmoved, so the comparison
            # below answers "nothing to say" on its own and needs no case of its own.
            painted = painted_in_order(program, declared.names)
            asked = Stacking.order(painted, declared.names, &:layer)
            return [] if asked.each_index.all? { |at| asked[at].equal?(painted[at]) }

            [Finding.new(check: NAME, severity: :warning, node: declared,
                         message: message(asked, painted))]
          end

          private

          # What a bitmap screen really paints, in the order it really paints it — and the
          # two halves are not alike, which is the whole of what this check knows.
          #
          # A BACKGROUND stamps itself into the one picture where it is declared, so the
          # backgrounds come out in declaration order and nothing later can move them.
          # SPRITES are repainted every frame, and the frame boundary already puts them
          # in stack order, so they come out where the stack asked.
          #
          # Painting the first list and then the second is therefore the true picture,
          # and the only way it can differ from what the stack asked for is a background
          # sitting somewhere the stack did not put it — either behind another background
          # it was meant to be in front of, or behind a sprite it was meant to cover.
          def painted_in_order(program, stack)
            modes = Modes.resolve(program)
            scenery = program.walk.select do |node|
              node.kind == :background && Modes::BITMAP_MODES.include?(modes.mode_at(node))
            end
            (scenery + Stacking.order(@sprites, stack, &:layer)).select(&:layer)
          rescue Modes::Conflict
            # One drawing routine reached from two screen modes. That error names it,
            # and until it is fixed there is no one mode to judge a picture in.
            []
          end

          def message(asked, painted)
            "This game draws with `screen :bitmap`, and its stack asks for a background " \
              "order that screen does not give. A bitmap screen has one picture, and a " \
              "background paints into it where you declare it — so the backgrounds come " \
              "out in the order the declarations run. The stack asks for #{list_of(asked)}, " \
              "back to front. The screen will show #{list_of(painted)}. To fix this, use " \
              "`screen :tiled`, where the console draws each background every frame and the " \
              "stack decides what is in front. Or declare them in the order you want them " \
              "painted. Sprites are not affected: they are redrawn every frame, so their " \
              "layers work on this screen."
          end

          def list_of(things)
            things.map { |thing| ":#{name_of(thing)}" }.join(", ")
          end

          # A background node carries its own name; a software sprite is named by the art
          # it draws, which is the word the author typed.
          def name_of(thing)
            thing.respond_to?(:picture_name) ? thing.picture_name : thing.name
          end
        end
      end
    end
  end
end
