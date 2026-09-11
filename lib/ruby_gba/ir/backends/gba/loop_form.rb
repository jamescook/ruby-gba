# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHICH SHAPE A `repeat` IS LOWERED TO, decided from the loop's body alone.
        #
        # A loop has to keep two numbers: how many passes it has made, and how many it is going
        # to make. Kept in MEMORY, every pass loads both, compares them, loads the counter
        # again, adds one and stores it back — sixteen instructions, twelve of them reaching
        # two numbers in the console's quick memory. Kept in REGISTERS it is a compare, a
        # branch, an add and a branch: four.
        #
        # Memory is the safe answer and that is why it is the default. The body of a loop may
        # call a routine, and a routine is free to use any register it likes; it may hold a
        # loop of its own; it may reach the console's divide routine, which uses several. Any
        # of those would quietly overwrite a counter left in a register, and a miscounted loop
        # is the kind of bug that shows up as a game behaving oddly rather than as a crash.
        #
        # So the fast shape is used only where nothing in the body can touch the two registers
        # it needs. That is decidable by looking, which is the point: the author writes
        # `repeat` and the build works out which shape it can have.
        #
        # THIS ANSWER IS ASKED FOR IN TWO PLACES — here, where the loop is emitted, and in the
        # cost estimate, which has to charge for the shape that will really run. It lives in
        # one place so those two cannot drift apart, which is a thing that has happened to
        # every other pair of that kind in this project.
        module LoopForm
          module_function

          # The registers the fast shape keeps its counter and limit in. Nothing else in the
          # lowering writes either of them EXCEPT the blit clipper and the sound mixer, and
          # both of those are named below as blockers — see the test that proves the rest of
          # the statement kinds leave them alone.
          COUNTER = 10
          LIMIT = 11

          # A statement kind that can reach code this loop does not control, and so can land
          # anywhere in the registers. `raw` is in the list because it is the escape hatch:
          # instructions the author wrote themselves, which may use any register they like.
          REACHES_OTHER_CODE = %i[call call_one_of case repeat on_timer raw].freeze

          # ...and the lowerings that use the high registers for their own working: a
          # blitted image clips each row against the screen edges in them, the mixer sums
          # its voices there, and a run-time digit holds its cell's x/y/color across the
          # shared glyph routine's whole walk in them (see Drawing#emit_digit_routines).
          USES_HIGH_REGISTERS = %i[blit blit_pose play_sample stop_sample sample
                                   draw_column_at draw_digit].freeze

          # A value kind that reaches the console's own routines, which own the registers while
          # they run. A stretched column is here as well as above: it works in the high
          # registers AND divides to find its step, and either one alone would take them. A
          # run-time digit is the same shape: the glyph loop lives in a shared routine one
          # call away, not laid out inline (see Drawing#emit_digit_routines).
          CALLS_A_ROUTINE = %i[div_fix pixels_overlap draw_column_at draw_digit].freeze

          # HOW MANY STATEMENTS ARE WORTH BRACKETING before giving up the registers is cheaper.
          # A bracket is four instructions — the count written out to its variable, then the
          # pair saved and restored around the statement — against the twelve a pass through
          # memory spends over one in registers. So two brackets still pay, and three do not.
          SPILL_LIMIT = 2

          # A blocker that cannot be bracketed. `raw` is instructions the author wrote, and
          # nothing here can say whether they leave the stack as they found it. A body that
          # writes the loop's own count would have to write the register too, and nothing in
          # the surface does that — so it is refused rather than handled.
          def unbracketable?(node, index)
            node.kind == :raw || writes?(node, index)
          end

          # Whether this repeat can keep its counter in a register with nothing saved.
          def registers?(node)
            node.kind == :repeat && !stops_early?(node) && blocking_children(node).empty?
          end

          # A loop that can stop early works out whether to, before every pass, in the two
          # registers the fast shape keeps its counter and limit in. So it takes the safe shape
          # — dearer per pass, and still far cheaper than the passes it does not make: a ray
          # that meets a wall a third of the way through a march skips the rest of it.
          def stops_early?(node)
            leave = node.stop_when
            !leave.nil? && !(leave.kind == :int && leave.value.zero?)
          end

          # Whether it can keep the counter in registers by saving the pair around the few
          # statements that would otherwise land in them.
          def spills?(node)
            return false unless node.kind == :repeat
            return false if stops_early?(node)

            blocking = blocking_children(node)
            blocking.any? && blocking.size <= SPILL_LIMIT &&
              blocking.none? { |child| unbracketable_within?(child, node.index) }
          end

          # The loop's own statements that hold something needing the registers — the ones a
          # spilling loop brackets.
          #
          # ITS COUNT IS NOT AMONG THEM, and that is why this asks the children rather than
          # walking everything under the node: the count is worked out before either register
          # is loaded (see Statements#emit_repeat_held), so whatever it takes, it takes while
          # there is nothing yet to lose.
          def blocking_children(node)
            node.children.select { |child| blocker_within(child, node.index) }
          end

          # The first thing inside one statement that needs the registers, or nil. A full walk
          # of it rather than a walk of the statements under it, because a statement holds
          # parts of itself off to the side — the branch an `if` runs when its test fails is
          # kept beside the node rather than under it, so a walk of statements alone strolls
          # past a call sitting in an else.
          def blocker_within(statement, index)
            statement.walk.find { |inner| takes_the_registers?(inner) || writes?(inner, index) }
          end

          def unbracketable_within?(statement, index)
            statement.walk.any? { |inner| unbracketable?(inner, index) }
          end

          # WHAT STOPPED IT, in the words an author would use, for the one report that says so.
          # The first thing found rather than all of them: an author fixes one at a time, and
          # the next build says what is next.
          def reason(node)
            blocker = blocker_in(node)
            return "it holds something that needs the registers" unless blocker

            phrase_for(blocker, node.index)
          end

          # The first thing in this loop's body that needs the registers, or nil. Read off the
          # same statements the shape is decided from, so "it cannot" and "here is why" can
          # never disagree.
          def blocker_in(node)
            index = node.index
            blocking_children(node).filter_map { |child| blocker_within(child, index) }.first
          end

          # Whether this one node needs the two registers for itself, either because it can
          # reach code that lands anywhere, or because its own lowering works in them.
          def takes_the_registers?(node)
            REACHES_OTHER_CODE.include?(node.kind) ||
              USES_HIGH_REGISTERS.include?(node.kind) ||
              CALLS_A_ROUTINE.include?(node.kind) ||
              runtime_divide?(node)
          end

          # The words for one blocker. The body writing the loop's own index would have to
          # write the register too, and nothing in the surface does that — so it is refused
          # rather than handled, and it says so.
          def phrase_for(node, index)
            case node.kind
            when :call then "the body calls :#{node.target}"
            when :call_one_of then "the body calls a routine picked by number"
            when :case then "the body picks a scene"
            when :repeat then "a loop inside it"
            when :on_timer then "a timer's handler inside it"
            when :raw then "instructions of your own inside it"
            when :div_fix then "a divide of numbers holding a fraction"
            when :pixels_overlap then "a per-pixel collision test"
            when :draw_column_at then "the body stretches a column of a picture"
            when :draw_digit then "the body draws a live number"
            when *USES_HIGH_REGISTERS then "the body draws an image"
            else
              writes?(node, index) ? "the body writes :#{index}, the loop's own count" : "a divide the game works out"
            end
          end

          # A divide or a wrap whose divisor the game works out reaches the console's divide
          # routine. One by a number written into the program does not — the lowering turns it
          # into a multiply or a shift (see Expressions#emit_constant_binop).
          def runtime_divide?(node)
            return false unless node.kind == :binop && %i[/ %].include?(node.op)

            !(node.rhs.is_a?(Node) && node.rhs.kind == :int)
          end

          # Whether this statement assigns to +name+.
          def writes?(node, name)
            %i[set add sub negate abs negate_abs clamp].include?(node.kind) && node.var == name ||
              (node.kind == :copy && node.dest == name)
          end
        end
      end
    end
  end
end
