# frozen_string_literal: true

module VBlank
  class Builder
    # SPRITES DRAWN IN AN ORDER THE GAME WORKS OUT.
    #
    # Everywhere else, which sprite is in front of which is settled when the cartridge is
    # built: the one declared later is in front, unless a layer says otherwise. A top-down
    # game cannot live with that. It draws whichever character stands LOWER on the screen
    # in front — walk round below something and you are drawn over it, walk round above it
    # and it is drawn over you — and the answer changes every time two things pass each
    # other.
    #
    #   draw_in_order hero, guard, guards        # whoever stands lower is in front
    #
    # The number each thing is put in order by is the bottom of its box unless the block
    # says otherwise, and the block is how a game says something else: a puff of smoke that
    # starts a step nearer the front and drops back once it is grown, a thing in the air
    # that is drawn over whatever it flies across.
    #
    #   draw_in_order(hero, puffs) { |thing| thing.bottom + thing.lift }
    #
    # HOW IT WORKS, which is the same on every backend because it is written in the program
    # itself. Before each frame is drawn a routine works out every thing's number and puts
    # the things in order in a list the program keeps — an insertion sort, starting from the
    # order they were in last frame, so a frame where nobody passed anybody is one compare a
    # thing. The frame's objects are then drawn with that run in the list's order. Things
    # whose numbers are equal keep the order they were already in, so two characters
    # standing level do not flicker in front of each other.
    module DrawOrder
      FRONTS = %i[highest lowest].freeze

      # One order the game declared: its number, counting from 1; the sprites and pools in
      # it; which end of the number is in front; and how a thing's number is worked out.
      Order = Data.define(:number, :things, :front, :key) do
        def part(name) = Messages::MadeNames.make(:draw_order, number: number, part: name)
        def routine = part(:sort)
        def keys_list = part(:keys)
        def order_list = part(:order)
      end

      # Draw +things+ — sprites, and the things of a pool — in an order worked out every
      # frame: the one whose number is +front+ (:highest or :lowest) is in front. The number
      # is the block's answer for each thing, handed the sprite, or one of the pool's things
      # the way `each` hands it; with no block it is the bottom of the thing's box, so
      # whoever stands lower is in front.
      #
      # The order is among the things named: each takes the place of the backmost of them,
      # and anything else keeps its own place in front of or behind the whole run. So the
      # things of one order are in one layer, and a sprite is in one order at most.
      #
      # @param things [Array<HardwareSprite, Pool>] what is put in order
      # @param front [Symbol] :highest (the default) or :lowest — which number is in front
      # @return [nil]
      def draw_in_order(*things, front: :highest, &key)
        things = things.flatten
        refuse_unknown_front!(front)
        things.each { |thing| refuse_unorderable_thing!(thing) }
        refuse_order_of_one!(things)
        things.each { |thing| refuse_thing_in_two_orders!(thing) }
        refuse_order_split_by!(things, :layer, "layer")
        refuse_order_split_by!(things, :scene, "scene")

        key ||= ->(thing) { thing.bottom }
        order = Order.new(number: draw_orders.length + 1, things: things, front: front, key: key)
        things.each { |thing| order_pool_things(thing, key) if thing.is_a?(DSL::Pool) }
        draw_orders << order
        nil
      end

      private

      def draw_orders = @draw_orders ||= []

      # The objects of one thing in an order, back to front: a sprite's one, or one for each
      # thing a pool can hold at once.
      def order_objects_of(thing)
        thing.is_a?(DSL::Pool) ? thing.stacked_objects : [thing.object_node]
      end

      # A pool's things are ordered one by one, so each needs its number worked out where the
      # pool copies them into the order it draws them in (see Pool#order_by).
      def order_pool_things(pool, key)
        at_boot(Build.list_new(pool.stacked_list(:order_key), pool.capacity, full_of: 0))
        pool.order_by(key)
      end


      # The number each object of +order+ is ordered by, by the object's name: a sprite's
      # worked out from its handle, a pool object's read from what the pool copied for its
      # place.
      def order_keys(order)
        order.things.flat_map do |thing|
          if thing.is_a?(DSL::Pool)
            thing.stacked_objects.each_with_index.map do |node, place|
              [node.name, thing.stacked_at(:order_key, thing.rank_at_place(place))]
            end
          else
            [[thing.object_name, DSL::Value.node_for(order.key.call(thing))]]
          end
        end.to_h
      end

      # The objects of +order+ in the order the draw list holds them, which is what the order
      # list counts into — and not, in general, the order the game named them in.
      def run_objects(order) = (@draw_order_runs ||= {}).fetch(order.number) { object_names_in(order) }

      # PUT EACH ORDER'S OBJECTS SIDE BY SIDE IN THE FRAME'S DRAW LIST, where the backmost of
      # them was, and tell every frame which run is ordered and where its order is kept. The
      # run has to be unbroken: what is put in order is a run of the draw list, and anything
      # standing between two of its objects would be passed by them as they swap.
      def arrange_draw_orders(names)
        draw_orders.reduce(names) do |list, order|
          objects = object_names_in(order)
          ordered = list.select { |name| objects.include?(name) }
          (list - ordered).insert(list.index(ordered.first), *ordered)
        end
      end

      def object_names_in(order) = order.things.flat_map { |thing| order_objects_of(thing).map(&:name) }

      # What each frame's present-objects node is told about the orders, once the draw list
      # is settled: each run's objects as they stand in the list, and the list its order is
      # kept in.
      def draw_order_runs(names)
        draw_orders.map do |order|
          objects = object_names_in(order)
          run = names.select { |name| objects.include?(name) }
          (@draw_order_runs ||= {})[order.number] = run
          Build::DrawOrder.new(objects: run, order: order.order_list)
        end
      end

      # BUILD EACH ORDER'S ROUTINE AND RUN IT BEFORE EVERY FRAME IS DRAWN — after the pools
      # have copied their things into place, since a pool's numbers are copied with them, and
      # just before the objects are drawn, so the order is the one the positions now say.
      def finalize_draw_orders
        return if draw_orders.empty?

        draw_orders.each do |order|
          refuse_order_that_changes_layer!(order)
          declare_order_lists(order)
          @functions[order.routine] = proc {}
          push_container(Build.func(order.routine)) { order_sort_nodes(order).each { |node| record(node) } }
        end
        @present_nodes.each do |present|
          container = present.parent or next
          at = container.children.index(present)
          draw_orders.reverse_each do |order|
            call = Build.call(order.routine)
            container.children.insert(at, call)
            call.parent = container
          end
        end
      end

      # The order starts as declared — each object's place pushed in turn, a different number
      # each — and every number at nought.
      def declare_order_lists(order)
        count = object_names_in(order).length
        index = order.part(:fill)
        ensure_var(index)
        at_boot(Build.list_new(order.order_list, count, width: :byte))
        at_boot(Build.repeat(Build.int(count), index, Build.list_push(order.order_list, Build.var_ref(index))))
        at_boot(Build.list_new(order.keys_list, count, full_of: 0))
      end

      # WORK OUT EVERY NUMBER, THEN SORT. The list holds the objects back to front, so the
      # one in front is last: for :highest the numbers rise along it. An insertion sort
      # starting from last frame's order does a compare a thing on a frame where nobody
      # passed anybody, and moves a thing only past the ones it passed. A thing moves back
      # only past a number strictly beyond its own, so two level things keep their order.
      def order_sort_nodes(order)
        keys = order.keys_list
        list = order.order_list
        pass = order.part(:pass)
        step = order.part(:step)
        at = order.part(:at)
        item = order.part(:item)
        key = order.part(:key)
        [pass, step, at, item, key].each { |var| ensure_var(var) }
        count = object_names_in(order).length
        ref = ->(name) { Build.var_ref(name) }
        before = -> { Build.list_get(keys, Build.list_get(list, Build.binop(:-, ref.(at), Build.binop(:>, ref.(at), 0)))) }
        stays = order.front == :highest ? :<= : :>=
        leave = Build.binop(:|, Build.binop(:==, ref.(at), 0), Build.binop(stays, before.call, ref.(key)))

        by_name = order_keys(order)
        numbers = run_objects(order).each_with_index.map do |name, i|
          Build.list_set(keys, Build.int(i), by_name.fetch(name))
        end
        sort = Build.repeat(Build.int(count - 1), pass,
                            Build.set(at, Build.binop(:+, ref.(pass), 1)),
                            Build.set(item, Build.list_get(list, ref.(at))),
                            Build.set(key, Build.list_get(keys, ref.(item))),
                            Build.repeat(ref.(at), step,
                                         Build.list_set(list, ref.(at), Build.list_get(list, Build.binop(:-, ref.(at), 1))),
                                         Build.sub(at, Build.int(1)),
                                         stop_when: leave),
                            Build.list_set(list, ref.(at), ref.(item)))
        numbers + [sort]
      end

      def refuse_unknown_front!(front)
        return if FRONTS.include?(front)

        raise ArgumentError,
              "draw_in_order was given front: #{front.inspect}. It must be :highest or :lowest. " \
              "It says which number is in front: :highest puts the thing with the biggest number in front."
      end

      def refuse_unorderable_thing!(thing)
        if thing.is_a?(DSL::Sprite)
          raise ArgumentError,
                "draw_in_order needs screen :tiled. On a bitmap screen a sprite is painted into the " \
                "picture, so there is no order left to change. Declare the screen as `screen :tiled`."
        end
        if thing.is_a?(DSL::Pool)
          return if thing.spriteful?

          raise ArgumentError,
                "pool :#{thing.name} draws nothing itself, so draw_in_order has nothing of it to put in " \
                "order. Give the pool `image:`, `facing:` or `frames:`."
        end
        return if thing.is_a?(DSL::HardwareSprite)

        raise ArgumentError,
              "draw_in_order puts things in order, and each one must be a sprite or a pool. " \
              "#{thing.inspect} is not one. Give it the handle that `sprite` or `pool` gave back."
      end

      def refuse_order_of_one!(things)
        return if things.sum { |thing| order_objects_of(thing).length } >= 2

        raise ArgumentError,
              "draw_in_order needs two things or more to put in order, and it was given one. " \
              "Name every sprite that can pass in front of another."
      end

      def order_thing_name(thing)
        return "pool :#{thing.name}" if thing.is_a?(DSL::Pool)

        "sprite :#{thing.object_node.declared || thing.object_name}"
      end

      def refuse_thing_in_two_orders!(thing)
        return unless draw_orders.any? { |order| order.things.any? { |other| other.equal?(thing) } }

        raise ArgumentError,
              "#{order_thing_name(thing)} is in two draw_in_order calls. A thing can be in one order only, " \
              "because one number decides where it is drawn. Put everything that passes it in one draw_in_order."
      end

      # Things in one order must agree about +field+ — the layer, or the scene — since the
      # order is a run of the draw list and a run is in one place in it.
      def refuse_order_split_by!(things, field, word)
        seen = things.to_h { |thing| [thing, order_objects_of(thing).first.public_send(field)] }
        return if seen.values.uniq.length <= 1

        said = seen.map { |thing, value| "#{order_thing_name(thing)} is in #{value ? "#{word} :#{value}" : "no #{word}"}" }
        raise ArgumentError,
              "draw_in_order puts in order the things of one #{word}. #{said.join(', and ')}. " \
              "Put them in one #{word}, or give each #{word} a draw_in_order of its own."
      end

      # A sprite told `put_in_layer` changes how deep it is drawn as the game runs, and an
      # order is a run of one depth.
      def refuse_order_that_changes_layer!(order)
        order.things.each do |thing|
          next if order_objects_of(thing).none?(&:layer_pick)

          raise ArgumentError,
                "#{order_thing_name(thing)} is in a draw_in_order and is told put_in_layer. An order puts " \
                "things in order inside one layer, so a thing in it cannot change layer. Take it out of one of the two."
        end
      end
    end
  end
end
