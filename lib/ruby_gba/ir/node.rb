# frozen_string_literal: true

module RubyGBA
  module IR
    # A single node in the intermediate representation (IR) — the op-tree the
    # DSL builds *instead of* emitting target code directly.
    #
    # A Node is plain Ruby data: no machine code, no output buffer, no
    # interpreter. That is the whole point. The tree is built, walked, and
    # checked (for footguns) entirely in memory, and only afterwards does a
    # lowering pass turn it into code for a concrete target. The tree itself
    # assumes nothing about that target — ARM/GBA is today's backend, but the
    # same tree could equally be lowered to, say, JavaScript. Keep
    # target-specific detail in the lowering pass, never in this model.
    #
    # Two shapes of node share this one class:
    #
    #   * Statement nodes — the program itself: a variable op (+set+, +add+), a
    #     draw op (+pixel+, +fill_rect+), or control flow (+if+, +loop+, +func+,
    #     +call+). Control-flow statements hold their nested statements in
    #     #children.
    #
    #   * Value nodes — an expression operand: a literal +int+, a +var_ref+, or a
    #     +binop+ combining two other value nodes. A value lives inside another
    #     node's #attrs (e.g. the value a +set+ assigns), never in #children.
    #
    # Control flow is *structured* — nesting, not jumps — so there are no labels
    # or gotos here. A +call+ names its +func+ target, and a consumer (an
    # interpreter, or a backend that lowers to machine code) resolves that name,
    # which is what lets a call refer to a func defined later. Labels and branch
    # targets are only an artifact of flattening this structure into linear code,
    # so they live in the backend that does the flattening, not in the IR.
    class Node
      # Every kind's category. Having one table means validation passes, the
      # inspector, and the lowering pass can all ask a node its category instead
      # of each carrying its own scattered case statement.
      CATEGORY = {
        program: :root,

        # variable operations — read/modify a named variable
        set: :var, add: :var, sub: :var, copy: :var, negate: :var,
        abs: :var, clamp: :var,

        # drawing / display operations
        display: :draw, pixel: :draw, fill_rect: :draw, clear_screen: :draw,
        draw_rect_at: :draw, draw_text: :draw, dma_fill_rect: :draw, blit: :draw,

        # control flow — these carry nested statements in #children
        if: :control, loop: :control, func: :control, call: :control,
        scene: :control, case: :control, wait_vblank: :control, halt: :control,

        # expression values — operands, live inside another node's #attrs
        int: :value, var_ref: :value, binop: :value, neg: :value,
      }.freeze

      # The distinct categories, in a stable order (useful for coverage checks).
      CATEGORIES = %i[root var draw control value].freeze

      attr_reader :kind, :attrs, :children
      attr_accessor :parent, :source

      # @param kind [Symbol] the op kind (a key of CATEGORY)
      # @param children [Array<Node>] nested statements (control flow only)
      # @param source [String, nil] optional DSL call site, kept for diagnostics
      # @param attrs [Hash] operands as plain Ruby values (or nested value Nodes)
      def initialize(kind, children: [], source: nil, **attrs)
        @kind = kind
        @attrs = attrs
        @children = []
        @parent = nil
        @source = source
        children.each { |c| add_child(c) }
      end

      # The node's category (:root/:var/:draw/:control/:value), or
      # :unknown for a kind we don't recognize — catching a typo'd kind here
      # beats a mysterious failure two passes downstream.
      def category
        CATEGORY.fetch(@kind, :unknown)
      end

      def value?
        category == :value
      end

      def control?
        category == :control
      end

      # A statement is anything that belongs in the program tree (as opposed to
      # an operand value).
      def statement?
        %i[root var draw control].include?(category)
      end

      def leaf?
        @children.empty?
      end

      # Read an operand by name, e.g. node[:var].
      def [](key)
        @attrs[key]
      end

      # Attach a nested statement, wiring its parent back-reference so the tree
      # is navigable in both directions.
      # @return [Node] the child (so calls can chain)
      def add_child(node)
        unless node.is_a?(Node)
          raise ArgumentError, "child must be an IR::Node, got #{node.class}"
        end
        @children << node
        node.parent = self
        node
      end
      alias << add_child

      # Depth-first, pre-order over this node and its statement #children. Does
      # NOT descend into value operands in #attrs — use #walk for the whole tree.
      def each(&block)
        return enum_for(:each) unless block

        yield self
        @children.each { |child| child.each(&block) }
      end

      # Depth-first over the ENTIRE tree: statement children and any value nodes
      # nested in #attrs (directly or inside arrays). This is what a validation
      # pass wants — "show me every node, statement or operand."
      def walk(&block)
        return enum_for(:walk) unless block

        yield self
        @children.each { |child| child.walk(&block) }
        @attrs.each_value { |value| walk_attr(value, &block) }
      end

      # A plain nested Hash of the whole node — for asserting structure in tests
      # and for the inspector to pretty-print. Parent/source are intentionally
      # omitted so the hash captures shape, not identity.
      def to_h
        result = { kind: @kind }
        result[:attrs] = @attrs.transform_values { |v| hashify(v) } unless @attrs.empty?
        result[:children] = @children.map(&:to_h) unless @children.empty?
        result
      end

      # Structural equality: same shape, ignoring parent/source. Lets tests say
      # assert_equal(expected_tree, actual_tree).
      def ==(other)
        other.is_a?(Node) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      def inspect
        parts = [@kind.inspect]
        parts.concat(@attrs.map { |k, v| "#{k}=#{v.inspect}" })
        suffix = @children.empty? ? "" : " {#{@children.size}}"
        "#<IR::Node #{parts.join(' ')}#{suffix}>"
      end

      private

      # Recurse #walk into an operand that may itself be a Node, or an array of
      # them (e.g. a case node's clause list).
      def walk_attr(value, &block)
        case value
        when Node then value.walk(&block)
        when Array then value.each { |element| walk_attr(element, &block) }
        end
      end

      def hashify(value)
        case value
        when Node then value.to_h
        when Array then value.map { |element| hashify(element) }
        else value
        end
      end
    end
  end
end
