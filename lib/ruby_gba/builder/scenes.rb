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
      # `fast:` says where the routine should be kept. The console has a small amount of
      # very quick memory and a much larger, slower cartridge, and code runs about two
      # and a half times faster from the quick one. The framework works out on its own
      # which routines are worth keeping there — the ones a frame spends the most time in
      # — so you can leave this alone. Say `fast: true` to insist on one it did not pick,
      # or `fast: false` to keep one out. `rom.profile` says what it chose and how much
      # room is left. (See RubyGBA.build's `fast_code:` to turn the choosing off
      # altogether.)
      #
      # @param name [Symbol] function name
      # @param fast [Boolean, nil] keep it in the quick memory (nil = let the framework decide)
      def func(name, fast: nil, &block)
        declare_func(name, fast: fast, wrote: "func :#{name}", &block)
      end

      # Call a named subroutine. The target is resolved by name when the tree is
      # lowered, so it may be defined before or after this call.
      #
      # ONE OF SEVERAL, picked by a number the game works out: give it the routines, in
      # order, and the number that says which, counting from 0.
      #
      #   HANDLERS = %i[op_end op_wait op_walk op_say]
      #   scripts.each { |s| call HANDLERS, number: s.opcode }
      #
      # A script's instructions, a character's current state, the move an enemy picked:
      # anything where a number already says what happens next. It goes straight to the
      # routine that number names, so a list of a hundred and more costs what a list of two
      # does — where testing the number against each one in turn costs a test per routine. A
      # number below 0 or past the end of the list calls nothing.
      #
      # @param name [Symbol, Array<Symbol>] function name, or a list of them to pick from
      # @param number [Integer, Symbol, Value, nil] which of the list to call
      def call(name, number: nil)
        return call_one_of(name, number) if name.is_a?(Array)

        unless number.nil?
          raise ArgumentError,
                "`call :#{name}` was given `number:`, but it calls one routine. `number:` picks one " \
                "routine from a list. To pick one, give a list: `call [:#{name}, :other], number: ...`."
        end
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
        refuse_scene_in_layer!
        declare_func(:"_scene_#{name}", &block)
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

      # Call whichever of +names+ the +number+ picks. A number written into the program
      # picks while building, so it is a plain call; one the game works out picks as it runs.
      def call_one_of(names, number)
        routines_to_pick_from!(names, number)
        fixed = Value.fixed_number(number)
        if fixed
          number_in_list!(names, fixed)
          return record(Build.call(names.fetch(fixed)))
        end

        record(Build.call_one_of(names, which: Value.node_for(number)))
        ensure_var(number)
      end

      def routines_to_pick_from!(names, number)
        raise ArgumentError, "`call` was given an empty list of routines. Name at least one routine." if names.empty?

        if number.nil?
          raise ArgumentError,
                "`call` was given a list of #{names.length} routines and no number to pick one. To fix " \
                "this, add `number:`, like `call [:#{names.first}, ...], number: which`."
        end
        stray = names.index { |name| !name.is_a?(Symbol) }
        if stray
          raise ArgumentError,
                "`call` was given #{names[stray].inspect} in its list of routines. Each item in the list " \
                "must be the name of a routine, like `:#{names.grep(Symbol).first || 'op_walk'}`."
        end
        return unless Fraction.bits_of(number)

        raise ArgumentError,
              "`call` picks a routine by a whole number, and the number given to `number:` holds a " \
              "fraction. To fix this, use `.to_i` to drop the fraction."
      end

      def number_in_list!(names, fixed)
        return if fixed.between?(0, names.length - 1)

        raise ArgumentError,
              "`call` was given `number: #{fixed}`, but the list has #{names.length} routines, numbered " \
              "0 to #{names.length - 1}. To fix this, give a number from 0 to #{names.length - 1}."
      end

      # Register a routine's body. Every routine goes through here — an author's `func`,
      # an author's `once_a_frame`, and the ones the framework declares for itself (an
      # effect's per-frame body, a hidden helper).
      #
      # A body is built LATER, at finalize, when the `layer` block it was written inside
      # has long since closed. So anything in it that wants a depth would quietly get
      # none, and this is where the layer in force is remembered so that can be refused
      # when it actually happens (see Layers#refuse_deferred_layer!). Remembering rather
      # than refusing here is what lets `pulse coin` be written on the line after the
      # coin, inside the layer block: a pack's per-frame body is behavior and declares
      # nothing with a depth, so it never trips the rule. +wrote+ is what the author
      # typed, for that message; the framework's own routines leave it alone and are
      # never the subject of one.
      def declare_func(name, fast: nil, wrote: nil, &block)
        raise ArgumentError, "The function :#{name} is already defined. Use a different name for each function." if @functions.key?(name)

        @functions[name] = block
        @func_fast[name] = fast unless fast.nil?
        @routine_layer[name] = [@current_layer, wrote] if @current_layer && wrote
      end

      # Every routine a call can reach must be a defined function. Check that here, so
      # a missing target surfaces as a clear error at build time. Walking the whole
      # tree (not just statement children) reaches targets nested in else-branches.
      def verify_targets_defined!
        @program.walk { |node| node.callees.each { |target| check_target_defined!(target) } }
      end

      def check_target_defined!(name)
        return if @functions.key?(name)

        raise ArgumentError,
              "The function :#{name} is called but never defined. To fix this, define it with " \
              "`func :#{name} do ... end`. Or correct the name in the call."
      end
    end
  end
end
