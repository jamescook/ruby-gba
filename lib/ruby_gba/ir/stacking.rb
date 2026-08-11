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

      # --- the whole picture, read off a program ---

      # Everything about how a program's picture is stacked: the +stack+ it declared,
      # its +scenery+ and +objects+ in the order they are drawn, and the +depths+ each
      # one sits at. One call, so a backend, a build check and a report all get the same
      # answer without any of them knowing how it was reached.
      Picture = Data.define(:stack, :scenery, :objects, :depths) do
        # The names in one layer, back to front — what that layer turned out to hold.
        def in_layer(name)
          (scenery + objects).select { |node| node.layer == name }.map(&:name)
        end
      end

      def picture(program)
        stack = program.walk.find { |node| node.kind == :layers }&.names || []
        scenery = order(program.walk.select { |node| node.kind == :background }, stack, &:layer)
        objects = objects_in_draw_order(program)
        Picture.new(stack: stack, scenery: scenery, objects: objects,
                    depths: depths(scenery: scenery, objects: objects, stack: stack))
      end

      # Every declared object, in the order a frame draws them (later = in front). The
      # frame's own draw list leads; an object that list never mentions — one in a
      # program with no frame to draw it — keeps its place in the tree, after the drawn
      # ones.
      def objects_in_draw_order(program)
        declared = program.walk.select { |node| node.kind == :object }
        drawn = program.walk.find { |node| node.kind == :present_objects }
        return declared unless drawn

        by_name = declared.to_h { |node| [node.name, node] }
        ordered = drawn.names.filter_map { |name| by_name[name] }
        ordered + (declared - ordered)
      end

      # --- how deep each thing sits ---
      #
      # A picture is built up in LEVELS, counted from the back. Everything on one level
      # is painted before anything on the next, and the things sharing a level are told
      # apart by rules a machine already has: a moving object is drawn over the scenery
      # it shares a level with, and two objects on one level keep their draw order.
      #
      # A level is the scarce thing — a machine with dedicated stacking hardware has
      # only a few — so the point of this is to spend as FEW as the picture needs, not
      # one per name. Any number of named layers can share a level, as long as what
      # comes out is the order that was declared. Only scenery opens a new level,
      # because scenery is the one thing that cannot be told apart from other scenery
      # any other way.

      # Where everything sits: +of+ maps a name to its level (0 is the backmost), and
      # +count+ is how many levels the picture needs.
      Depths = Data.define(:of, :count) do
        def [](name) = of.fetch(name)
      end

      # Work out the levels for a picture made of +scenery+ (background nodes) and
      # +objects+ (object nodes), each list already in its own drawing order, given the
      # declared +stack+.
      #
      # With no stack declared this is the arrangement every picture has always had:
      # the scenery back to front, and the objects over all of it. That is not a special
      # case in the code — it is what the rule below produces when nothing names a
      # layer, which is why a picture that names none comes out byte for byte the same.
      def depths(scenery:, objects:, stack: [])
        level = 0
        started = false
        of = {}

        merge(scenery, objects, stack).each do |item, kind|
          level += 1 if started && kind == :scenery
          started = true
          of[item.name] = level
        end

        Depths.new(of: of, count: level + 1)
      end

      # Everything in one sequence, back to front, tagged with what it is. Scenery and
      # objects in the same layer come out scenery-first, because an object is drawn
      # over the scenery it shares a level with.
      #
      # Something that named no layer takes the place it has always had: scenery at the
      # back, objects in front of it. That keeps a picture that names no layers exactly
      # as it was, and it is what #scenery_over_objects? watches, because the two rules
      # only disagree once the stack asks for scenery in FRONT of an object.
      def merge(scenery, objects, stack)
        tagged = scenery.each_with_index.map { |node, nth| [node, :scenery, depth_key(node, stack, -1), nth] } +
                 objects.each_with_index.map { |node, nth| [node, :object, depth_key(node, stack, Float::INFINITY), nth] }

        tagged.sort_by { |_node, kind, key, nth| [key, kind == :scenery ? 0 : 1, nth] }
              .map { |node, kind, _key, _nth| [node, kind] }
      end

      # Where in the stack a thing sits, or +absent+ when it named no layer.
      def depth_key(node, stack, absent)
        at = stack.index(node.layer)
        at || absent
      end

      # Does the stack put any scenery IN FRONT OF an object? That is the one arrangement
      # a picture cannot fall into by accident, and it is where "it named no layer, so
      # leave it where it was" stops having an answer: once the levels are no longer
      # simply scenery-then-objects, a thing with no layer has no place among them.
      def scenery_over_objects?(depths, scenery:, objects:)
        return false if scenery.empty? || objects.empty?

        frontmost = scenery.map { |node| depths[node.name] }.max
        objects.any? { |node| depths[node.name] < frontmost }
      end
    end
  end
end
