# frozen_string_literal: true

module RubyGBA
  module IR
    # PUTTING THINGS IN THE ORDER THE STACK ASKS FOR.
    #
    # A program can name the depths its picture is built from (see the +layers+ node)
    # and say which one a thing belongs to. Turning that into a drawing order is one
    # rule, and it lives here rather than in each consumer, because two consumers that
    # each worked it out would eventually disagree — and a disagreement about which
    # thing is in front is exactly the kind that shows up as a wrong picture on one
    # machine and a right one on another.
    #
    # THE RULE, and the second half is what makes it safe to adopt a bit at a time:
    #
    #   * Things that named a layer are put in the stack's order, back to front. Two
    #     things in the same layer keep the order they were declared in.
    #   * Things that named NO layer do not move. They keep the exact places they had,
    #     and the layered things are rearranged among the places THEY had. So wrapping
    #     one part of a game in a layer cannot pick up and move a part that says
    #     nothing about layers.
    module Stacking
      module_function

      # +items+ arranged the way +stack+ (the declared layers, backmost first) asks
      # for. The block is handed each item and answers which layer it named, or nil.
      # An unchanged copy comes back when nothing names a layer the stack knows.
      def order(items, stack)
        return items if stack.nil? || stack.empty?

        places = (0...items.length).select { |at| stack.include?(yield(items[at])) }
        return items if places.length < 2

        sorted = places.map { |at| items[at] }
                       .sort_by.with_index { |item, nth| [stack.index(yield(item)), nth] }

        arranged = items.dup
        places.each_with_index { |at, nth| arranged[at] = sorted[nth] }
        arranged
      end
    end
  end
end
