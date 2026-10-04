# frozen_string_literal: true

module RubyGBA
  class Builder
    # THE STEPS THE SAVE CODE BUILDS PROGRAM WITH, and the few pieces it is written in.
    #
    # The records, the table of places and the job queue all build their routines the same
    # way: through a {Saves::Port}, which is the whole of what they know about the Builder, and
    # out of a number, a variable, the arithmetic and tests on them, a read of save memory and
    # a branch. Each used to spell its own; one set means a reader learns them once, and the
    # table of places and the job queue can each be an object of its own handed the same port.
    #
    # Whatever includes this keeps the port in +@port+.
    module SaveProgram
      private

      def handle = @port.handle
      def record(node) = @port.record.call(node)
      def repeat(...) = @port.repeat.call(...)
      def at_boot(node) = @port.at_boot.call(node)
      def ensure_var(name) = @port.ensure_var.call(name)
      def declare_func(name, &body) = @port.declare_func.call(name, &body)
      def run_each_pass(name) = @port.run_each_pass.call(name)

      def sd_int(value) = IR::Build.int(value)
      def sd_var(name) = IR::Build.var_ref(name)
      def sd_op(op, lhs, rhs) = IR::Build.binop(op, lhs, rhs)
      def sd_add(lhs, rhs) = sd_op(:+, lhs, rhs)
      def sd_eq(lhs, rhs) = sd_op(:==, lhs, rhs)
      def sd_and(lhs, rhs) = sd_op(:&, lhs, rhs)
      def sd_or(lhs, rhs) = sd_op(:|, lhs, rhs)
      def sd_read(at, width = :word) = IR::Build.save_read(at, width: width)
      # A branch a game's own code could have written, built through the Builder.
      def sd_when(test, &block) = DSL::Condition.new(handle, test).then(&block)
    end
  end
end
