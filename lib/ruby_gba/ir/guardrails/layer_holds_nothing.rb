# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A layer the program named and put nothing in.
        #
        # Nothing breaks — a depth nothing sits at simply never comes up — which is
        # what makes this worth saying out loud. The stack is the one line a reader
        # goes to for "what is in front of what", so a name in it that means nothing
        # is a line that reads as an answer and is not one. The two ways in are a
        # name spelled one way in `layers` and another in the `layer` block (the
        # block raises, so this is the half of a typo that survives — the name left
        # over in the stack), and an edit that moved the last thing out of a layer.
        #
        # A layer used only as the LINE an effect sits at is in use, and the picture
        # says so: `fade :black, 100, under: :cut` keeps everything from :cut
        # forward, so :cut can hold nothing and still decide what the fade reaches.
        #
        # Whole-program, because holding nothing is only knowable once every
        # declaration in every scene has run. It is handed the build's software
        # sprites for the same reason {StackNotHonored} is: a software sprite's layer
        # is on the handle and not in the tree, so a layer holding only those would
        # look empty to a check that walked the tree alone.
        class LayerHoldsNothing
          NAME = :layer_holds_nothing
          PLAIN_NAME = "a layer that holds nothing"

          # @param sprites [Array<Sprite>] the build's software sprites. Empty for a
          #   check run over a tree alone.
          def initialize(sprites = [])
            @sprites = sprites
          end

          def detect(program)
            declared = program.walk.find { |node| node.kind == :layers }
            return [] if declared.nil? || declared.names.empty?

            empty = declared.names - in_use(program)
            return [] if empty.empty?

            [Finding.new(check: NAME, severity: :warning, node: declared,
                         message: message(empty, declared.names))]
          end

          private

          # Every layer the program gives a meaning to: one something is in, and one
          # an effect is placed under.
          def in_use(program)
            (program.walk.flat_map do |node|
              [(node.layer if node.respond_to?(:layer)),
               (node.under if node.kind == :fade)]
            end + @sprites.map(&:layer)).compact.uniq
          end

          def message(empty, stack)
            return every_layer(empty) if empty.length == stack.length

            "#{holds_nothing(empty)} A layer with nothing in it changes no picture. " \
              "Usually the name is written differently in the `layer` block, or what was " \
              "in it has moved out. To fix this, put something in #{list_of(empty)} with " \
              "`layer :#{empty.first} do ... end`, or remove #{empty.length > 1 ? 'them' : "it"} " \
              "from the `layers` line."
          end

          def holds_nothing(empty)
            return "The layer :#{empty.first} holds nothing." if empty.length == 1

            "These layers hold nothing: #{list_of(empty)}."
          end

          # Every layer empty is a different mistake: the stack was declared and then
          # nothing was ever put in it. Saying "put something in :sky, :world, :actors
          # and :ui" one layer at a time would miss the point, so say the one thing
          # that is wrong and what a `layer` block is for.
          def every_layer(empty)
            "This game declares layers and puts nothing in any of them: #{list_of(empty)}. " \
              "So the stack changes no picture. A `layer` block is what gives a depth to a " \
              "`background`, to a `sprite`, and to text on a tiled screen. To fix this, put " \
              "those declarations in `layer` blocks. Or remove the `layers` line."
          end

          def list_of(names)
            names.map { |name| ":#{name}" }.join(", ")
          end
        end
      end
    end
  end
end
