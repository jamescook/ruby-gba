# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      # THE BLOCKS A PICTURE IS SHOWN IN when a program pixelates: what every backend has
      # to agree on, kept where both read it so they cannot come to different answers.
      #
      # HOW BIG a block can be is the display's: it keeps the size in a few bits, so there
      # is a biggest one, and a size asked for past either end stops at that end.
      #
      # WHERE the blocks stop is one place for a whole program. A statement can leave a
      # layer, and everything in front of it, as drawn. A display keeps "in blocks" as a
      # switch on each thing in the picture rather than as a line it can move, so a
      # program gets one such line, settled before it runs. One backend could draw two;
      # the other could not, so neither does.
      module Blocks
        LARGEST = Console::Hardware::MOSAIC_LARGEST

        module_function

        # +asked+ held to the sizes there are: 1 is the picture as drawn.
        def size(asked) = asked.clamp(1, LARGEST)

        # Every place +program+ puts its blocks: nil for the whole picture, or the name of
        # a layer left as drawn. None for a program that never pixelates, and more than
        # one for a program no backend runs (see #several_places_message).
        def places(program)
          program.walk.select { |node| node.kind == :pixelate }.map(&:under).uniq
        end

        def several_places_message(places)
          said = places.map { |place| place ? "under :#{place}" : "over the whole picture" }.join(" and ")
          "This program pixelates #{said}. A program pixelates from one place in the stack, " \
            "because which things are drawn in blocks is settled once, before it runs. To fix " \
            "this, give every pixelate the same place."
        end
      end
    end
  end
end
