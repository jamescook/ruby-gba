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
              put_operand(:"#{name}", value)
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

      # Every color this node can draw in, for the places that need all of them (a table
      # of colors has to hold each). One, for everything but a kind that can pick between
      # two as it runs.
      def drawn_colors = colored? && color ? [color] : []

      # A test with a branch to take when it fails.
      def branching? = self.class.tags.key?(:else)

      # The routines this node can hand control to, by name — none, for nearly every kind. A
      # kind that calls says which (see Nodes::Call and its siblings), so code following the
      # calls through a program asks this, and a new way of reaching a routine is followed
      # everywhere as soon as its kind answers it.
      def callees = []

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
      #
      # It goes only where a node can be, which each operand settles as it is written (see
      # #put_operand). So a pass reading the program never looks inside the data a game
      # ships — a level map, a wall texture, a sine table — where there is nothing to find
      # and a great many numbers to find it among.
      def walk(&block)
        return enum_for(:walk) unless block

        yield self
        @children.each { |child| child.walk(&block) }
        node_fields.each { |name| walk_attr(public_send(name), &block) }
      end

      # Give this statement and everything under it a call site they do not have — the line
      # of the DECLARATION a framework-built statement serves, so that a sprite's per-frame
      # repaint is traced to the `sprite` line rather than to no line at all. A node that
      # already carries one keeps it. Returns self.
      def stamp(source)
        each { |node| node.source ||= source }
        self
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

      # The one door into an operand: hold it still, store it, wire a nested node's parent
      # back, and settle whether a walk has to come this way again.
      def put_operand(name, value)
        freeze_lists_in(value)
        instance_variable_set(:"@#{name}", value)
        value.parent = self if value.is_a?(Node)

        leads = leads_to_a_node?(value)
        return value if leads == node_fields.include?(name)

        # In the order the kind DECLARES its operands, not the order they were written in,
        # so a pass that collects as it walks — the colours a program draws in, the routines
        # it can reach — gets them in the order the kind reads in.
        wanted = leads ? node_fields + [name] : node_fields - [name]
        @node_fields = self.class.tags.each_key.select { |declared| wanted.include?(declared) }
        value
      end

      # The operands of THIS node that lead to a node. Every other one holds a name, a
      # number, a colour, a flag or a list of plain data, and a walk has no reason to look
      # inside one.
      def node_fields = @node_fields ||= []

      # A list an operand holds belongs to the node from here on. That is what makes one
      # answer enough below: a list nothing can add to cannot come to hold a node that a
      # walk would then never reach, and an attempt to add one fails at the line making it.
      # Anything that is not a list cannot become one, so there is nothing else to hold.
      def freeze_lists_in(value)
        return unless value.is_a?(Array)

        value.each { |element| freeze_lists_in(element) }
        value.freeze
      end

      # Whether a walk has to come back to this operand — the same question a walk itself
      # would ask, put to the same object. Nothing is taken on trust from what the field is
      # DECLARED to hold, so a list that really does hold nodes, like a case statement's
      # clauses, answers yes.
      def leads_to_a_node?(value)
        case value
        when Node then true
        when Array then value.any? { |element| leads_to_a_node?(element) }
        else false
        end
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
