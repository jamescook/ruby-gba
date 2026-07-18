# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      # The Ruby backend: runs an IR::Node program directly in Ruby. This is the
      # logic core — it executes control flow, variable ops, and arithmetic
      # against an in-memory variable store, with NO hardware (drawing and input
      # are added by a later layer on top of this). Being able to just *run* a
      # program and read the result is what makes testing game logic cheap and
      # headless, and it pins the IR's meaning before a lowering backend (the GBA
      # ROM backend) has to reproduce it.
      #
      # It runs hand-built IR::Build trees today; it needs neither the DSL to
      # emit IR nor an emulator.
      class Ruby
        class ProgramError < StandardError; end

        # A generous default so an accidental infinite loop can't hang a test
        # forever. Pass a small max_steps to deliberately run N steps of an
        # otherwise-endless game loop and then inspect the state.
        DEFAULT_MAX_STEPS = 1_000_000

        attr_reader :vars

        def initialize
          @vars = Hash.new(0) # variable store; an unwritten variable reads as 0
          @funcs = {}         # name -> :func node
        end

        # Execute a program (or any statement node) until it ends naturally, hits
        # a `halt`, or exhausts the step budget — whichever comes first. Returns
        # self so callers can chain and then inspect variables.
        def run(node, max_steps: DEFAULT_MAX_STEPS)
          @max_steps = max_steps
          @steps = 0
          @stopped_at_budget = false
          collect_functions(node)
          catch(:halt) { exec(node) }
          self
        end

        # Read a variable's current value (0 if it was never written).
        def [](name)
          @vars[name]
        end

        # True if run() stopped because it hit the step budget rather than a
        # `halt` or the natural end — i.e. it was still looping when we cut it off.
        def stopped_at_budget?
          @stopped_at_budget
        end

        private

        # Register every func defined anywhere in the tree up front, so a `call`
        # can reach a func defined later in the program (a forward reference) —
        # the same resolve-names-first move the GBA lowering makes with labels.
        def collect_functions(node)
          node.walk { |n| @funcs[n[:name]] = n if n.kind == :func }
        end

        def tick!
          @steps += 1
          return if @steps <= @max_steps

          @stopped_at_budget = true
          throw :halt
        end

        def exec(node)
          tick!
          case node.kind
          when :program
            node.children.each { |child| exec(child) }
          when :func, :label, :label_ref
            # func bodies run only via `call`; a label is an inert marker here
            # (the structured IR has no goto that would jump to one).
            nil
          when :set
            @vars[node[:var]] = eval_value(node[:value])
          when :add
            @vars[node[:var]] = Int32.add(@vars[node[:var]], eval_value(node[:operand]))
          when :sub
            @vars[node[:var]] = Int32.sub(@vars[node[:var]], eval_value(node[:operand]))
          when :copy
            @vars[node[:dest]] = @vars[node[:src]]
          when :negate
            @vars[node[:var]] = Int32.neg(@vars[node[:var]])
          when :clamp
            @vars[node[:var]] = clamp_value(@vars[node[:var]], node[:min], node[:max])
          when :if
            node.children.each { |child| exec(child) } unless eval_value(node[:cond]).zero?
          when :loop
            loop { node.children.each { |child| exec(child) } }
          when :call
            exec_call(node[:target])
          when :halt
            throw :halt
          when :wait_vblank
            nil # a pure timing marker; it means something only once there's hardware
          else
            raise ProgramError,
                  "the Ruby backend core cannot execute #{node.kind.inspect} " \
                  "(#{node.category}) — drawing and input belong to the hardware layer"
          end
        end

        def exec_call(name)
          func = @funcs[name] || raise(ProgramError, "call to undefined func #{name.inspect}")
          func.children.each { |child| exec(child) }
        end

        # Evaluate an operand to a signed 32-bit integer. Operands are normally
        # value nodes; a bare Integer or Symbol is accepted too for convenience.
        def eval_value(operand)
          case operand
          when Integer then Int32.wrap(operand)
          when Symbol then @vars[operand]
          when Node then eval_node(operand)
          else raise ProgramError, "cannot evaluate operand #{operand.inspect}"
          end
        end

        def eval_node(node)
          case node.kind
          when :int then Int32.wrap(node[:value])
          when :var_ref then @vars[node[:name]]
          when :neg then Int32.neg(eval_value(node[:operand]))
          when :binop then eval_binop(node[:op], eval_value(node[:lhs]), eval_value(node[:rhs]))
          else raise ProgramError, "not a value node: #{node.kind.inspect}"
          end
        end

        # Arithmetic routes through Int32 (signed 32-bit wraparound); comparisons
        # use signed ordering and yield 1/0, so a condition is simply "non-zero".
        def eval_binop(op, lhs, rhs)
          case op
          when :+ then Int32.add(lhs, rhs)
          when :- then Int32.sub(lhs, rhs)
          when :* then Int32.mul(lhs, rhs)
          when :> then bool(Int32.cmp(lhs, rhs) > 0)
          when :< then bool(Int32.cmp(lhs, rhs) < 0)
          when :>= then bool(Int32.cmp(lhs, rhs) >= 0)
          when :<= then bool(Int32.cmp(lhs, rhs) <= 0)
          when :== then bool(Int32.cmp(lhs, rhs).zero?)
          when :!= then bool(!Int32.cmp(lhs, rhs).zero?)
          else raise ProgramError, "unknown binary operator #{op.inspect}"
          end
        end

        def clamp_value(value, min, max)
          return min if value < min
          return max if value > max

          value
        end

        def bool(flag)
          flag ? 1 : 0
        end
      end
    end
  end
end
