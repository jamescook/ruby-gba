# frozen_string_literal: true

module RubyGBA
  class Builder
    # The input verbs: gate a block on a button — if_held / if_pressed — or turn a
    # button into a {Condition} — held / pressed — to branch with `.then` and
    # compose with `&` / `|`. Button names are validated against the shared IR
    # vocabulary. A concern of {Builder}, mixed in so these stay flat DSL verbs.
    module Input
      # Run the block only while a button is held down.
      #
      # @param button [Symbol] :up, :down, :left, :right, :a, :b, :start, :select, :l, :r
      def if_held(button, &block)
        check_button!(button)
        push_container(Build.if_(Build.held(button))) do
          instance_eval(&block)
        end
      end

      # Run the block when a button is first pressed (edge-detected): down this
      # frame, up the previous one.
      #
      # @param button [Symbol] button name
      def if_pressed(button, &block)
        check_button!(button)
        push_container(Build.if_(Build.pressed(button))) do
          instance_eval(&block)
        end
      end

      # A {Condition} that holds while a button is down — branch on it with
      # `held(:up).then { ... }`.
      #
      # @param button [Symbol] button name
      def held(button)
        reject_block!(:held, button) if block_given?
        check_button!(button)
        Condition.new(self, Build.held(button))
      end

      # A {Condition} true on the frame a button is first pressed (edge-detected).
      #
      # @param button [Symbol] button name
      def pressed(button)
        reject_block!(:pressed, button) if block_given?
        check_button!(button)
        Condition.new(self, Build.pressed(button))
      end

      private

      # Accept a known button name (from the shared IR vocabulary); raise a plain
      # error for anything else.
      def check_button!(button)
        return if IR::Buttons.known?(button)

        raise ArgumentError, "unknown button: #{button}"
      end

      # held/pressed hand back a Condition and take no block. A block here means a
      # dropped `.then` — the block would attach to held/pressed and be silently
      # ignored — so name the fix instead of losing the code.
      def reject_block!(verb, button)
        raise ArgumentError,
              "#{verb}(:#{button}) has no block form — write #{verb}(:#{button}).then { ... } " \
              "(or the block-taking if_#{verb} :#{button} do ... end)"
      end
    end
  end
end
