# frozen_string_literal: true

module VBlank
  module IR
    # WHAT A RUN OF A PROGRAM CAN REACH: the statements under the program, the routines it calls
    # however deep, and the variables it keeps. Every lowering asks the same questions of the
    # same tree, so the answers live here and each lowering makes the same routines and keeps the
    # same variables. A routine nothing calls is made by none of them: it never runs, and the
    # interpreter never complains of what is in it.
    module Reach
      # The variables the framework keeps the frame count in, first of every program's (IR::Frames).
      FRAME_VARIABLES = [Frames::COUNT, Frames::SEEN, Frames::STEP].freeze

      # Which kinds of statement name a variable, and where. The interpreter keeps a variable that
      # has never been written as 0, so a lowering keeps every one of these from power-on, at 0, and
      # the program's own `set`s give it its first value.
      VARIABLES_OF = Ractor.make_shareable({
                                             set: ->(n) { [n.var] }, add: ->(n) { [n.var] },
                                             sub: ->(n) { [n.var] }, negate: ->(n) { [n.var] },
                                             abs: ->(n) { [n.var] }, negate_abs: ->(n) { [n.var] },
                                             clamp: ->(n) { [n.var] }, copy: ->(n) { [n.dest, n.src] },
                                             var_ref: ->(n) { [n.name] }, repeat: ->(n) { [n.index].compact },
                                             every: ->(n) { [n.counter] }, after: ->(n) { [n.counter] },
                                             case: ->(n) { [n.var] }, scroll_rows: ->(n) { [n.row] },
                                             shade_outside: ->(n) { [n.row] },
                                             copy_owed_tiles: ->(n) { n.masks },
                                             save_init: ->(n) { n.vars.map(&:name) }, save_store: ->(n) { [n.var] }
                                           })

      module_function

      # The statements under +root+ and everything they hold, stopping at a routine's declaration,
      # at a bend and at what a timer does when it ticks: a routine's body runs where it is called,
      # a bend's as its lines are worked out and a tick's as its timer ticks, not where any of them
      # is written. The bend or the handler itself is still a statement there; what it holds is
      # found by asking for it as a root.
      def statements_under(root)
        found = [root]
        (root.children + root.operand_nodes).each do |node|
          found.concat(case node.kind
                       when :func then []
                       when :scroll_rows, :on_timer then [node]
                       else statements_under(node)
                       end)
        end
        found
      end

      def statements_from(*roots) = roots.flat_map { |root| statements_under(root) }

      # The routines named by the statements in +nodes+.
      def routines_named(nodes)
        nodes.flat_map do |node|
          case node.kind
          when :call then [node.target]
          when :call_one_of then node.targets
          when :case then node.clauses.map(&:last)
          else []
          end
        end
      end

      # Every routine a run can reach from +program+ and +also+ (what a bend runs, what a timer
      # does when it ticks), following each into the routines it calls, in the order the routines
      # were declared.
      def routines(program, also: [])
        funcs = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
        reached = []
        waiting = routines_named(statements_from(program, *also))
        until waiting.empty?
          name = waiting.shift
          next if reached.include?(name) || !funcs.key?(name)

          reached << name
          waiting.concat(routines_named(statements_under(funcs.fetch(name))))
        end
        funcs.keys & reached
      end

      # Every variable +program+ names, the framework's own included, in the order they first
      # appear.
      def variables(program)
        names = FRAME_VARIABLES.dup
        program.walk do |node|
          reader = VARIABLES_OF[node.kind]
          names.concat(reader.call(node)) if reader
          node.operand_nodes.each { |operand| names << operand if operand.is_a?(Symbol) }
        end
        names.uniq
      end
    end
  end
end
