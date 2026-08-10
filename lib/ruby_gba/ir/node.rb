# frozen_string_literal: true

module RubyGBA
  module IR
    # WHAT EVERY NODE OF THE INTERMEDIATE REPRESENTATION CAN DO — the op-tree the DSL builds
    # *instead of* emitting target code directly.
    #
    # A node is plain Ruby data: no machine code, no output buffer, no interpreter. That is
    # the whole point. The tree is built, walked, and checked (for footguns) entirely in
    # memory, and only afterwards does a lowering pass turn it into code for a concrete
    # target. The tree itself assumes nothing about that target — ARM/GBA is today's backend,
    # but the same tree could equally be lowered to, say, JavaScript. Keep target-specific
    # detail in the lowering pass, never in this model.
    #
    # Two shapes of node share this behaviour:
    #
    #   * Statement nodes — the program itself: a variable op (+set+, +add+), a draw op
    #     (+pixel+, +fill_rect+), or control flow (+if+, +loop+, +func+, +call+). Control-flow
    #     statements hold their nested statements in #children.
    #
    #   * Value nodes — an expression operand: a literal +int+, a +var_ref+, or a +binop+
    #     combining two other value nodes. A value lives in another node's operands (e.g. the
    #     value a +set+ assigns), never in #children.
    #
    # Control flow is *structured* — nesting, not jumps — so there are no labels or gotos
    # here. A +call+ names its +func+ target, and a consumer (an interpreter, or a backend
    # that lowers to machine code) resolves that name, which is what lets a call refer to a
    # func defined later. Labels and branch targets are only an artifact of flattening this
    # structure into linear code, so they live in the backend that does the flattening.
    #
    # THIS IS A MIXIN, AND IT NAMES NO KIND. Each kind is its own class (see {Nodes}), which
    # declares what it is and what operands it carries; this holds only what they all share.
    # Nothing here knows a pixel from a func, so a new kind is a new class and nothing else.
    module Node
      # The distinct categories, in a stable order (useful for coverage checks).
      CATEGORIES = %i[root var draw sound control data list value].freeze

      def self.included(base)
        base.extend(Declarations)
      end

      # What a kind declares about itself. Three lines at the top of each class: its name on
      # the wire, the section it belongs to, and its operands.
      module Declarations
        # This kind's name — the symbol the tree, the reports and the tests speak in.
        def kind(name = nil)
          name ? @kind = name : @kind
        end

        # Which section of a frame's work this kind belongs to (see CATEGORIES).
        def category(name = nil)
          name ? @category = name : @category
        end

        # The operands this kind carries, each with what it must hold. The names become real
        # readers and writers; the tags are what {Verifier} checks. One declaration, so a
        # field cannot be readable but unchecked, or checked but unreadable.
        #
        # A tag of +:value+ marks a value slot — a wrapped operand, which may be a number
        # settled while authoring or one the game works out as it runs. Every other tag names
        # an author-time literal of a stated type.
        def operands(**tags)
          @tags = tags
          tags.each_key do |name|
            attr_reader name

            # Writing an operand that is itself a node wires its parent back, so the tree is
            # navigable in both directions however it was assembled — a branch attached after
            # the node it hangs from, a sprite given an angle once something turns it. The
            # assignment maintains that, rather than whoever remembers to.
            define_method(:"#{name}=") do |value|
              instance_variable_set(:"@#{name}", value)
              value.parent = self if value.is_a?(Node)
              value
            end
          end
        end

        def tags
          @tags || {}
        end
      end

      attr_reader :children
      attr_accessor :parent, :source

      # @param children [Array<Node>] nested statements (control flow only)
      # @param source [String, nil] optional DSL call site, kept for diagnostics
      # @param operands [Hash] this kind's operands, as plain Ruby values (or nested nodes)
      def initialize(children: [], source: nil, **operands)
        @children = []
        @parent = nil
        @source = source
        operands.each { |name, value| set_operand(name, value) }
        children.each { |child| add_child(child) }
      end

      def kind = self.class.kind
      def category = self.class.category || :unknown
      def value? = category == :value
      def control? = category == :control

      # A statement is anything that belongs in the program tree (as opposed to an operand).
      def statement?
        %i[root var draw sound control data list].include?(category)
      end

      def leaf? = @children.empty?

      # The operands this node actually carries, and what each holds. Only the ones that were
      # given: a kind may declare a field that a particular node leaves alone (an `if` with
      # no `else`), and that is not the same as carrying it empty.
      def attrs
        self.class.tags.keys
            .select { |name| instance_variable_defined?(:"@#{name}") }
            .to_h { |name| [name, public_send(name)] }
      end

      # -- what a node is, for code that walks every kind --
      #
      # A tree walk cannot read a size off a node that has no size, so it asks first. These
      # say what the node is in the words of the thing being asked about, rather than asking
      # after a field by name — the caller wants to know whether there is a rectangle here,
      # not whether a :w exists.

      # A rectangle: something with a width and a height of its own.
      def sized? = self.class.tags.key?(:w) && self.class.tags.key?(:h)

      # Something drawn in a color.
      def colored? = self.class.tags.key?(:color)

      # A test with a branch to take when it fails.
      def branching? = self.class.tags.key?(:else)

      # Attach a nested statement, wiring its parent back-reference so the tree
      # is navigable in both directions.
      # @return [Node] the child (so calls can chain)
      def add_child(node)
        unless node.is_a?(Node)
          raise ArgumentError, "child must be an IR node, got #{node.class}"
        end

        @children << node
        node.parent = self
        node
      end
      alias << add_child

      # Depth-first, pre-order over this node and its statement #children. Does
      # NOT descend into value operands — use #walk for the whole tree.
      def each(&block)
        return enum_for(:each) unless block

        yield self
        @children.each { |child| child.each(&block) }
      end

      # Depth-first over the ENTIRE tree: statement children and any value nodes
      # nested in the operands (directly or inside arrays). This is what a validation
      # pass wants — "show me every node, statement or operand."
      def walk(&block)
        return enum_for(:walk) unless block

        yield self
        @children.each { |child| child.walk(&block) }
        attrs.each_value { |value| walk_attr(value, &block) }
      end

      # A separate tree of the same shape: this node, its operands and everything under it,
      # all new objects. Parents are rewired to the copy as it is built, so the two trees
      # share nothing and changing one cannot show up in the other.
      #
      # For anything that has to CHANGE a program to learn about it — measuring a frame rate
      # means adding a counter to count frames with — so the program it was handed is still
      # the program afterwards.
      def copy
        self.class.new(source: source,
                       children: @children.map(&:copy),
                       **attrs.transform_values { |value| copy_operand(value) })
      end

      # A plain nested Hash of the whole node — for asserting structure in tests
      # and for the inspector to pretty-print. Parent/source are intentionally
      # omitted so the hash captures shape, not identity.
      def to_h
        carried = attrs
        result = { kind: kind }
        result[:attrs] = carried.transform_values { |v| hashify(v) } unless carried.empty?
        result[:children] = @children.map(&:to_h) unless @children.empty?
        result
      end

      # Structural equality: same shape, ignoring parent/source. Lets tests say
      # assert_equal(expected_tree, actual_tree).
      def ==(other)
        other.is_a?(Node) && to_h == other.to_h
      end
      alias eql? ==

      def hash = to_h.hash

      def inspect
        parts = [kind.inspect]
        parts.concat(attrs.map { |k, v| "#{k}=#{v.inspect}" })
        suffix = @children.empty? ? "" : " {#{@children.size}}"
        "#<IR::#{self.class.name.split('::').last} #{parts.join(' ')}#{suffix}>"
      end

      private

      # Put an operand there while constructing, by name. A name the kind does not have is
      # refused with what it DOES have — the answer is nearly always in that list, and the
      # bare NoMethodError a writer would raise says nothing about the alternatives.
      def set_operand(name, value)
        unless self.class.tags.key?(name)
          known = self.class.tags.keys
          raise InvariantError,
                "#{kind} has no #{name.inspect} field to set. It has: " \
                "#{known.empty? ? '(nothing)' : known.map(&:inspect).join(', ')}. " \
                "Declare it with `operands` if this kind should have it."
        end

        public_send(:"#{name}=", value)
      end

      # An operand for #copy: a nested node is copied, a list is copied element by element
      # (a case node's clauses are pairs, so this recurses), and anything else is a plain
      # value that cannot be changed through the tree.
      def copy_operand(value)
        case value
        when Node then value.copy
        when Array then value.map { |element| copy_operand(element) }
        else value
        end
      end

      # Recurse #walk into an operand that may itself be a node, or an array of
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
