# frozen_string_literal: true

module RubyGBA
  module IR
    # WHICH ROW OF A FIXED TABLE OF SPRITES EACH SPRITE IS GIVEN, when the rows are handed out
    # while the program is built and a machine draws only so many.
    #
    # A machine that composes its sprites in hardware reads them from a table of a fixed size,
    # and decides which of two sprites is in front by where their rows sit. A row is settled
    # before any code exists, because the code that writes a sprite names its row. So two
    # sprites can be given the same row only if they are never on screen together — and that is
    # exactly what two scenes picked by the same variable are. A title screen's lettering and
    # the room the game is played in take turns, so they can take turns at the same rows.
    #
    # WHAT SHARES, AND WHAT KEEPS A ROW OF ITS OWN. A sprite shares when its scene is the only
    # thing that puts it up, said in the shape the builder writes (see
    # Movement#objects_shown_by_scene), and its scene is picked by the variable that picks the
    # most of them. Everything else keeps a row of its own for the whole program: what every
    # scene shows, a scene some other variable picks (it can be up beside one of these), and a
    # sprite drawn in an order the game works out, whose rows are copied into the table from a
    # copy of their own, so another scene's sprite in one of them would be written into that
    # copy and never reach the table. Two scenes the variable picks with the same value are up
    # together, so they count as one.
    #
    # THE ORDER STILL HOLDS ON EVERY SCREEN. A sprite of its own row keeps that row on every
    # screen, so the sprites that share are laid out in the stretches between those: in each
    # stretch, every scene's sprites start from the same row and go on in their own order. A
    # sprite of its own row drawn between two stretches stands between two scenes' sprites, and
    # those two scenes cannot share rows across it — which is why the count can be more than
    # the busiest screen's, and the build check says so.
    module SpriteRows
      module_function

      # +rows+ maps each sprite's name to its first row, counted from the front (a sprite drawn
      # as several pieces takes the rows after it too), +count+ is how many rows they take in
      # all, +screens+ is what each screen holds, +keys+ says, for each sprite that takes turns
      # at rows, the variable and value that put it up, and +between+ names the sprites of rows
      # of their own that stand between two stretches of sprites that share.
      Plan = Data.define(:rows, :count, :screens, :keys, :between) do
        # The screen holding the most, by what each sprite weighs.
        def busiest = screens.max_by(&:count)

        # How many more rows the sprites standing between stretches cost, over the busiest
        # screen's.
        def rows_lost_between = count - busiest.count
      end

      # One screen: the scenes that are up together on it (none for a program that shares
      # nothing), the sprites on it, back to front, and the rows those take.
      Screen = Data.define(:scenes, :names, :count)

      # The rows for every sprite +program+ declares, in the order the program draws them. The
      # block weighs a sprite: how many rows it takes.
      def plan(program, &weight)
        objects = Stacking.objects_in_draw_order(program)
        groups = Movement.objects_shown_by_scene(program)
        key_of = shared_keys(groups, drawn_in_order(program))
        stretches = objects.reverse.chunk_while { |a, b| key_of.key?(a.name) == key_of.key?(b.name) }.to_a
        rows, count = lay_out(stretches, key_of, weight)
        Plan.new(rows: rows, count: count, screens: screens(objects, key_of, groups, weight),
                 keys: key_of, between: standing_between(stretches, key_of))
      end

      # The variable and value each sprite that shares is put up by, by name.
      def shared_keys(groups, ordered)
        return {} if groups.empty?

        state = groups.group_by(&:state).max_by { |_state, held| held.sum { |group| group.names.size } }.first
        groups.select { |group| group.state == state }
              .flat_map { |group| (group.names - ordered).map { |name| [name, [state, group.value]] } }.to_h
      end

      # Every sprite the frame draws in an order the game works out.
      def drawn_in_order(program)
        present = program.walk.find { |node| node.kind == :present_objects }
        (present&.orders || []).flat_map(&:objects)
      end

      # Front to back, so the frontmost sprite takes row 0. A sprite of its own row takes the
      # next free one; a stretch of sprites that share starts every scene's at the same row,
      # and is as long as its longest scene's.
      def lay_out(stretches, key_of, weight)
        rows = {}
        front = stretches.reduce(0) do |at, stretch|
          ends = Hash.new(at) # the next free row of each scene's, or of the stretch when it shares nothing
          stretch.each do |node|
            key = key_of[node.name]
            rows[node.name] = ends[key]
            ends[key] += weight.call(node)
          end
          ends.values.max || at
        end
        [rows, front]
      end

      # The sprites of rows of their own with sprites that share both in front of them and
      # behind them.
      def standing_between(stretches, key_of)
        stretches.each_cons(3).flat_map do |front, middle, back|
          key_of.key?(front.first.name) && key_of.key?(back.first.name) ? middle.map(&:name) : []
        end
      end

      # Every screen: for each value of the sharing variable, the sprites of their own rows and
      # that value's. A program that shares nothing has one screen holding everything.
      def screens(objects, key_of, groups, weight)
        keys = key_of.values.uniq
        return [screen([], objects, weight)] if keys.empty?

        scenes_of = groups.group_by { |group| [group.state, group.value] }
        keys.map do |key|
          on = objects.select { |node| !key_of.key?(node.name) || key_of[node.name] == key }
          screen(scenes_of.fetch(key, []).map(&:scene), on, weight)
        end
      end

      def screen(scenes, nodes, weight)
        Screen.new(scenes: scenes, names: nodes.map(&:name), count: nodes.sum { |node| weight.call(node) })
      end
    end
  end
end
