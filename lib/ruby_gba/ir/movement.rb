# frozen_string_literal: true

module RubyGBA
  module IR
    # WHICH OF A PICTURE'S THINGS MOVE, AND WHICH NEVER CHANGE ONCE THEY ARE DRAWN.
    #
    # A question about the PROGRAM, which is why it is here and not in a backend: whether a
    # thing ever changes is a fact the program already contains, and every backend that draws
    # the same program has to reach the same answer about it. What each does with the answer
    # is its own business — one that redraws everything from scratch each frame has no use
    # for it, one whose target remembers what it was last told can do less work.
    #
    # NOTHING IN A PROGRAM SAYS "THIS ONE DOES NOT MOVE", and nothing should: asking the
    # author to repeat what they have already written is asking them to get it wrong. It is
    # read off what the program DOES instead — a thing is still when nothing that can run
    # more than once writes any of the numbers it is drawn from.
    #
    # THE ONE THING THAT MAY STILL CHANGE IS WHETHER IT IS SHOWN, and that is the case worth
    # having, because a title screen is exactly this: lettering put up once and then left
    # alone for as long as anybody looks at it. A thing declared inside a scene is on screen
    # exactly while that scene is, so its own numbers never move and one variable — whichever
    # the program dispatches its scenes on — decides whether it is drawn at all. So the answer
    # comes in two parts: the things that are still, and the one variable that can change what
    # becomes of them. Watch that variable and everything here is settled while it holds.
    #
    # WHERE THE CAUTION IS POINTED. Getting this wrong in one direction leaves a picture
    # painted from stale numbers, which is a bug nobody can see the cause of; getting it wrong
    # in the other leaves a thing drawn again that need not have been, which is what every
    # program did before any of this existed. So every question here is answered "it moves"
    # unless the program plainly says otherwise: an unrecognised way of working a number out,
    # a scene nothing dispatches to, instructions of the author's own anywhere in the program.
    #
    # ONE STATE VARIABLE, and a program that picks its scenes with two gets nothing from this.
    # Watching several would be several compares on every frame and a second answer to keep
    # in step; a program that wants it can be met when one turns up.
    module Movement
      module_function

      # +still+ are the things that never change, in the order the tree declares them, and
      # +watching+ is the variable that decides whether they are drawn — nil when nothing can
      # change even that, which is a program without scenes.
      Answer = Data.define(:still, :watching) do
        # The same answer with some of the still things handed back, for a consumer that has
        # reasons of its own to redraw one anyway. The variable to watch goes with the last of
        # them, so "nothing is still, and there is nothing to watch for it" stays one fact
        # said in one place rather than two that can drift apart.
        def except(names)
          kept = still - names
          Answer.new(still: kept, watching: (watching if kept.any?))
        end
      end

      EVERYTHING_MOVES = Ractor.make_shareable(Answer.new(still: [], watching: nil))

      # The three ways of saying a number that can be read through. Anything else — an
      # element of a list, a timer's count, a table read — is refused rather than understood,
      # because a list can change with no variable written and this would not see it.
      ARITHMETIC = %i[int var_ref binop].freeze

      # The places a node names a variable it only READS. Every other name a node carries is
      # treated as one it may write, which sweeps in plenty of names that are not variables
      # at all (a picture, a font, a layer). That is deliberate: a name swept in by mistake
      # costs a thing its stillness, and a name missed costs a picture.
      ONLY_READ = Ractor.make_shareable(
        { var_ref: %i[name], case: %i[var], copy: %i[src], save_store: %i[var] }
      )

      def still_objects(program)
        frame = program.children.find { |node| node.kind == :loop }
        return EVERYTHING_MOVES if frame.nil? || program.walk.any? { |node| node.kind == :raw }

        moved = moved_names(program, frame)
        gates = scene_dispatch_tests(program)
        states = gates.values.map(&:first).uniq
        return EVERYTHING_MOVES if states.length > 1

        still = program.walk.select { |node| node.kind == :object && still?(node, moved, gates) }
        Answer.new(still: still.map(&:name), watching: (states.first if still.any?))
      end

      # THE THINGS SHOWN ONLY WHILE ONE SCENE IS, by scene: for each, the variable and value
      # that put that scene up, and the names of what it shows. A thing whose visibility does
      # not carry its scene's test in the shape the builder puts there is left out, and so is
      # one outside every scene — both are drawn on every frame, as everything used to be.
      #
      # Unlike the still things this is about SHOWING and not about moving, so a program with
      # its own instructions in it, or two variables picking scenes, loses nothing here.
      SceneThings = Data.define(:scene, :state, :value, :names)

      def objects_shown_by_scene(program)
        gates = scene_dispatch_tests(program)
        shown = program.walk.select { |node| node.kind == :object && node.scene && visibility_without_scene_test(node, gates) }
        shown.group_by(&:scene).map do |scene, nodes|
          state, value = gates.fetch(scene)
          SceneThings.new(scene: scene, state: state, value: value, names: nodes.map(&:name))
        end
      end

      # Every variable name written by anything that can run more than once.
      #
      # What is spared is the plain statements a program runs before its frame loop: those go
      # once, at power-on, so what they set is settled before the first frame is drawn — which
      # is what makes a sprite's declared position count as still rather than as a number
      # somebody wrote. A statement with a BODY is never spared, wherever it sits, because a
      # body is something the machine goes back into: a routine, a timer's handler, a block
      # run once a row. One of those written above the frame loop looks like setup and is not.
      # Picked out BY PLACE and never by value: two nodes count as equal when they hold the
      # same thing, so a statement after the loop that happens to read the same as one before
      # it would be spared along with it.
      def moved_names(program, frame)
        at = program.children.index(frame)
        running = program.children.select.with_index { |node, nth| nth >= at || !node.leaf? }
        running.flat_map { |node| node.walk.flat_map { |inner| written_by(inner) } }.to_set
      end

      def written_by(node)
        spared = ONLY_READ.fetch(node.kind, [])
        node.class.tags.filter_map do |name, tag|
          node.public_send(name) if tag == :name && !spared.include?(name)
        end
      end

      # Which variable and value each scene is dispatched for, read from where the program
      # picks one scene per frame. A scene nothing dispatches to has no answer here, and
      # anything belonging to it is left moving.
      def scene_dispatch_tests(program)
        program.walk.each_with_object({}) do |node, gates|
          next unless node.kind == :case

          node.clauses.each { |value, target| gates[target] ||= [node.var, value] }
        end
      end

      # Is everything this object is drawn from settled? Its place, its pose, its turn, its
      # size and its colours must all read nothing that moves; whether it is SHOWN may also
      # read its scene's own variable, and nothing else.
      def still?(node, moved, gates)
        shown = visibility_without_scene_test(node, gates)
        return false if shown.nil?

        [node.pose, node.x, node.y, node.angle, node.scale, node.recolor, shown]
          .compact.all? { |operand| fixed?(operand, moved) }
      end

      # The part of "is it shown" that belongs to the object rather than to its scene. A
      # thing outside every scene is shown by its own visibility alone; one inside a scene
      # carries that AND the test the builder put there (Builder#gated_by_scene), so the test
      # comes off and what is left has to be settled. Nothing else may stand in that place.
      def visibility_without_scene_test(node, gates)
        return node.active if node.scene.nil?

        state, value = gates[node.scene]
        return nil if state.nil?

        shown = node.active
        return nil unless shown.is_a?(Node) && shown.kind == :binop && shown.op == :*
        return nil unless scene_test?(shown.rhs, state, value)

        shown.lhs
      end

      def scene_test?(node, state, value)
        node.is_a?(Node) && node.kind == :binop && node.op == :== &&
          node.lhs.kind == :var_ref && node.lhs.name == state &&
          node.rhs.kind == :int && node.rhs.value == value
      end

      # A number that cannot change while the game runs: made only of ways of saying one
      # this can read through, and naming no variable anything writes.
      def fixed?(operand, moved)
        return true unless operand.is_a?(Node)

        operand.walk.all? do |node|
          ARITHMETIC.include?(node.kind) && !(node.kind == :var_ref && moved.include?(node.name))
        end
      end
    end
  end
end
