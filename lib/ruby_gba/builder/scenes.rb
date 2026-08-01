# frozen_string_literal: true

module RubyGBA
  class Builder
    # The subroutine and scene verbs: define named routines (func) and call them,
    # organize a game into scenes with a state machine (scene, case_var), and
    # request a disassembly dump (dump_func). A concern of {Builder}, mixed in so
    # these stay flat DSL verbs.
    #
    # Deferred func bodies are emitted, and their call/case targets verified, by the
    # builder's finalize step (emit_pending_functions) — that orchestration crosses
    # concerns, so it stays in the core; these are the verbs that feed it.
    module Scenes
      # Define a named subroutine. The block is stored and evaluated after the main
      # block (so func/call order in the DSL doesn't matter).
      #
      # @param name [Symbol] function name
      def func(name, &block)
        raise ArgumentError, "The function :#{name} is already defined. Use a different name for each function." if @functions.key?(name)

        @functions[name] = block
      end

      # Call a named subroutine. The target is resolved by name when the tree is
      # lowered, so it may be defined before or after this call.
      #
      # @param name [Symbol] function name
      def call(name)
        record(Build.call(name))
      end

      # Request a disassembly dump of a function after the ROM is built.
      # Place this anywhere in the build block — output is printed after
      # all functions are emitted. Works for both func and scene names.
      #
      # @param name [Symbol] function or scene name
      #
      # @example
      #   func :update_cpu do
      #     copy :_cpu_center, :cpu_y
      #     add :_cpu_center, PADDLE_H / 2
      #   end
      #   dump_func :update_cpu
      def dump_func(name)
        @dump_requests << name
      end

      # Define a scene (named subroutine for a game state).
      # Internally prefixed with `_scene_` to avoid clashing with func names.
      #
      # @param name [Symbol] scene name
      def scene(name, &block)
        func(:"_scene_#{name}", &block)
      end

      # Dispatch to a scene based on a variable's value.
      # Evaluates the block in a CaseContext to collect when_val clauses,
      # then records one case node dispatching on the variable — its targets are
      # the scene subroutines (each scene is a func named _scene_<name>).
      #
      # @param var_name [Symbol] variable holding the state value
      #
      # @example
      #   case_var :state do
      #     when_val 0, :title
      #     when_val 1, :playing
      #   end
      def case_var(var_name, &block)
        ctx = CaseContext.new
        ctx.instance_eval(&block)

        ensure_var(var_name)
        clauses = ctx.cases.map { |value, raw_name| [value, :"_scene_#{raw_name}"] }
        record(Build.case_(var_name, clauses))
      end

      # Collector for case_var clauses.
      class CaseContext
        attr_reader :cases

        def initialize
          @cases = []
        end

        # Map a value to a scene/function name.
        def when_val(value, scene_name)
          @cases << [value, scene_name]
        end
      end

      private

      # Every call and case target must name a defined function. Check that here, so
      # a missing target surfaces as a clear error at build time. Walking the whole
      # tree (not just statement children) reaches targets nested in else-branches.
      def verify_targets_defined!
        @program.walk do |node|
          case node.kind
          when :call
            check_target_defined!(node[:target])
          when :case
            node[:clauses].each { |_value, target| check_target_defined!(target) }
          end
        end
      end

      def check_target_defined!(name)
        return if @functions.key?(name)

        raise ArgumentError, "The function :#{name} is called but never defined. Define it with func :#{name} do ... end, or check the name."
      end
    end
  end
end
