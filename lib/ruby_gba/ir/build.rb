# frozen_string_literal: true

module RubyGBA
  module IR
    # Readable constructors for IR nodes. Each helper names a known kind and
    # fixes its operand names, so callers build trees tersely and typo-safely
    # without learning Node's attr conventions. The DSL layer (and the tests)
    # build through these.
    #
    #   include RubyGBA::IR::Build   # or call as Build.set(...)
    #
    #   program(
    #     display(:bitmap),
    #     set(:x, 100),
    #     loop_(
    #       wait_vblank,
    #       if_(binop(:>, var_ref(:x), int(200)), set(:x, 0)),
    #       add(:x, 1),
    #     ),
    #   )
    #
    # Note the trailing underscores: +if_+, +loop_+, +case_+ — +if+/+loop+/+case+
    # are Ruby keywords, so the helpers can't reuse those bare names.
    module Build
      module_function

      # --- program root ---

      def program(*statements)
        Node.new(:program, children: statements)
      end

      # --- variable operations ---
      # An operand may be a bare Integer/Symbol (coerced to a value node by
      # #wrap) or an already-built value node.

      def set(var, value)
        Node.new(:set, var: var, value: wrap(value))
      end

      def add(var, operand)
        Node.new(:add, var: var, operand: wrap(operand))
      end

      def sub(var, operand)
        Node.new(:sub, var: var, operand: wrap(operand))
      end

      def copy(dest, src)
        Node.new(:copy, dest: dest, src: src)
      end

      def negate(var)
        Node.new(:negate, var: var)
      end

      def clamp(var, min, max)
        Node.new(:clamp, var: var, min: min, max: max)
      end

      # --- drawing / display operations ---

      def display(mode)
        Node.new(:display, mode: mode)
      end

      def pixel(x, y, color)
        Node.new(:pixel, x: wrap(x), y: wrap(y), color: color)
      end

      def fill_rect(x, y, w, h, color)
        Node.new(:fill_rect, x: x, y: y, w: w, h: h, color: color)
      end

      def clear_screen(color)
        Node.new(:clear_screen, color: color)
      end

      # --- control flow ---  (bodies are nested statements)

      def if_(cond, *body)
        Node.new(:if, children: body, cond: cond)
      end

      def loop_(*body)
        Node.new(:loop, children: body)
      end

      def func(name, *body)
        Node.new(:func, children: body, name: name)
      end

      def call(name)
        Node.new(:call, target: name)
      end

      def wait_vblank
        Node.new(:wait_vblank)
      end

      def halt
        Node.new(:halt)
      end

      # --- expression values (the AST an assignment or condition is built from) ---

      def int(number)
        Node.new(:int, value: number)
      end

      def var_ref(name)
        Node.new(:var_ref, name: name)
      end

      def binop(op, lhs, rhs)
        Node.new(:binop, op: op, lhs: wrap(lhs), rhs: wrap(rhs))
      end

      # --- input reads (value operands, e.g. inside an `if_` condition) ---

      # 1 while +button+ is down, else 0.
      def held(button)
        Node.new(:held, button: button)
      end

      # 1 only on the frame +button+ first goes down (a fresh press), else 0.
      def pressed(button)
        Node.new(:pressed, button: button)
      end

      # Coerce a bare operand into a value node so every operand is uniform:
      # an Integer becomes an +int+ literal, a Symbol becomes a +var_ref+, and a
      # Node passes through untouched.
      def wrap(operand)
        case operand
        when Node then operand
        when Integer then int(operand)
        when Symbol then var_ref(operand)
        else operand
        end
      end
    end
  end
end
