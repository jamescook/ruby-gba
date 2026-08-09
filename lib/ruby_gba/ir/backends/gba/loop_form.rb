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
          REACHES_OTHER_CODE = %i[call case repeat on_timer raw].freeze

          # ...and the two lowerings that use the high registers for their own working: a
          # blitted image clips each row against the screen edges in them, and the mixer sums
          # its voices there.
          USES_HIGH_REGISTERS = %i[blit blit_pose play_sample stop_sample sample].freeze

          # A value kind that reaches the console's own routines, which own the registers while
          # they run.
          CALLS_A_ROUTINE = %i[div_fix pixels_overlap].freeze

          # Whether this repeat can keep its counter in a register.
          def registers?(node)
            node.kind == :repeat && blocker_in(node).nil?
          end

          # WHAT STOPPED IT, in the words an author would use, for the one report that says so.
          # The first thing found rather than all of them: an author fixes one at a time, and
          # the next build says what is next.
          def reason(node)
            blocker = blocker_in(node)
            return "it holds something that needs the registers" unless blocker

            phrase_for(blocker, node[:index])
          end

          # The first thing anywhere inside this loop that needs the registers, or nil.
          #
          # ONE traversal answers both questions, so "it cannot" and "here is why" can never
          # disagree — and it is a full walk of the body rather than a walk of the statements
          # under it, because a statement holds parts of itself off to the side. The branch an
          # `if` runs when its test fails is the one that bites: it is kept beside the node
          # rather than under it, so a walk of statements alone strolls past a loop or a call
          # sitting in an else. That is not a wrong price, it is a wrong answer.
          def blocker_in(node)
            index = node[:index]
            body_of(node).find { |inner| takes_the_registers?(inner) || writes?(inner, index) }
          end

          # Everything inside this loop, the loop itself excepted.
          def body_of(node)
            node.walk.reject { |inner| inner.equal?(node) }
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
            when :call then "the body calls :#{node[:target]}"
            when :case then "the body picks a scene"
            when :repeat then "a loop inside it"
            when :on_timer then "a timer's handler inside it"
            when :raw then "instructions of your own inside it"
            when :div_fix then "a divide of numbers holding a fraction"
            when :pixels_overlap then "a per-pixel collision test"
            when *USES_HIGH_REGISTERS then "the body draws an image"
            else
              writes?(node, index) ? "the body writes :#{index}, the loop's own count" : "a divide the game works out"
            end
          end

          # A divide or a wrap whose divisor the game works out reaches the console's divide
          # routine. One by a number written into the program does not — the lowering turns it
          # into a multiply or a shift (see Expressions#emit_constant_binop).
          def runtime_divide?(node)
            return false unless node.kind == :binop && %i[/ %].include?(node[:op])

            !(node[:rhs].is_a?(Node) && node[:rhs].kind == :int)
          end

          # Whether this statement assigns to +name+.
          def writes?(node, name)
            %i[set add sub negate abs negate_abs clamp].include?(node.kind) && node[:var] == name ||
              (node.kind == :copy && node[:dest] == name)
          end
        end
      end
    end
  end
end
