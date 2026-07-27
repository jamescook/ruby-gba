# frozen_string_literal: true

module RubyGBA
  module IR
    # Raised when the IR itself is malformed — a ruby-gba bug, never a mistake the
    # game developer made. Distinct from Guardrails::ValidationError, which reports
    # a *developer's* footgun in friendly language. See {Verifier}.
    class InvariantError < StandardError; end

    # The IR verifier: a well-formedness pass that mechanically enforces the
    # value model — "every operand is a value node" — instead of trusting each
    # verb to remember it.
    #
    # The DSL has two worlds. Authoring a ROM runs the build block once on the
    # host; the ROM then runs later on the console. A *value* — a number the
    # program works with — may be either an author-time literal (folded to a
    # constant) or a run-time variable/expression, and the value model unifies
    # them: everything flows through Build.wrap into a value node, so a verb
    # accepts either interchangeably. But nothing *proved* a verb actually wrapped
    # its operands — a verb that dropped a raw Integer into a value slot would fail
    # silently, the whole class of bug where a run-time value handed to an
    # author-time-only slot renders garbage with no error.
    #
    # This pass proves it. {SLOTS} declares, per node kind, whether each field is
    # a *value slot* (must hold a value node — any timing) or a *structural slot*
    # (an author-time literal of a stated type: a name, a size, packed bytes, a
    # color). The verifier walks the tree and checks every field against its slot;
    # a mismatch means a verb built the node wrong, so it raises {InvariantError}
    # for us to fix — it is not a Guardrails::Finding, is never shown to a game
    # developer, and offers no fix.
    #
    # The author-time escape hatch is already in the model, not a special case: a
    # constant is a value node of kind +int+, folded once while authoring and
    # loaded with a single move at run time — so "everything is a value" never
    # means "everything recomputes." A constant simply is a value whose kind is
    # +int+, and it satisfies the invariant like any other.
    module Verifier
      module_function

      # What a structural slot may hold, as predicates over the raw operand. A
      # value slot is handled separately (it must be a value *node*); these are the
      # author-time literals. `nil` is allowed for any structural slot, so optional
      # fields (a bitmap's transparency, a beep's overrides, an if's else) need no
      # special marking.
      TYPES = {
        name:    ->(v) { v.is_a?(Symbol) },                    # a variable / asset / func name
        option:  ->(v) { v.is_a?(Symbol) },                    # an enum choice (:front, :quarter, :left)
        int:     ->(v) { v.is_a?(Integer) },                   # a size, count, fixed coord, literal
        text:    ->(v) { v.is_a?(String) },                    # a string / packed bytes
        color:   ->(v) { v.is_a?(Symbol) || v.is_a?(String) || v.is_a?(Integer) },
        mode:    ->(v) { v.is_a?(Symbol) || v.is_a?(Integer) }, # a screen-mode name or raw register value
        tone:    ->(v) { v.is_a?(Symbol) || v.is_a?(Integer) }, # a defined-sound name or raw frequency
        list:    ->(v) { v.is_a?(Array) },                     # a resolved score / a case dispatch table
        branch:  ->(v) { v.is_a?(Node) && v.kind == :else },   # an if's else-branch node
        flag:    ->(v) { v == true || v == false },            # an on/off switch (e.g. double buffering)
      }.freeze

      # Every kind's fields, each tagged with what it must hold — the single source
      # of truth for the author-time vs run-time boundary. `:value` marks a value
      # slot (a wrapped operand, any timing); every other tag is a {TYPES}
      # structural literal. Fields absent from a node are fine (the constructors
      # require them); this table only says what a field must be *when present*,
      # plus that a `:value` field must be present and be a value node.
      #
      # Kept complete by the coverage test, which asserts every Node::CATEGORY kind
      # has a row here — so a new verb cannot slip the net.
      SLOTS = {
        program: {},

        # variable operations
        set:        { var: :name, value: :value },
        add:        { var: :name, operand: :value },
        sub:        { var: :name, operand: :value },
        copy:       { dest: :name, src: :name },
        negate:     { var: :name },
        abs:        { var: :name },
        negate_abs: { var: :name },
        clamp:      { var: :name, min: :int, max: :int }, # bounds are author-time constants

        # drawing / screen
        screen:        { mode: :mode, buffered: :flag }, # buffered: opt into double buffering
        pixel:         { x: :value, y: :value, color: :color },
        fill_rect:     { x: :int, y: :int, w: :int, h: :int, color: :color }, # fixed position
        clear_screen:  { color: :color },
        draw_text:     { text: :text, x: :int, y: :int, color: :color, font: :name },   # fixed origin
        draw_digit:    { value: :value, x: :int, y: :int, color: :color, font: :name }, # run-time digit
        draw_rect_at:  { x: :value, y: :value, w: :int, h: :int, color: :color }, # runtime position
        dma_fill_rect: { x: :int, y: :int, w: :int, h: :int, color: :color },
        blit:          { name: :name, x: :value, y: :value },
        blit_pose:     { poses: :list, index: :value, x: :value, y: :value }, # one image of a same-size set
        # a tiled background: the distinct tile images, the grid of indices into them
        # (nil = empty cell), and the tile size — all author-time (the picture is fixed).
        background:    { name: :name, tiles: :list, map: :list, tile_w: :int, tile_h: :int },
        # a composited moving object: its picture, and the run-time position/visibility
        # (variables the game steers). present_objects names which to draw this frame.
        object:          { name: :name, image: :name, x: :value, y: :value, active: :value },
        present_objects: { names: :list },
        # save/restore the pixels under a moving object; the patch size comes from
        # the named backing buffer, so these carry only where (x/y, run-time).
        save_region:    { buffer: :name, x: :value, y: :value },
        restore_region: { buffer: :name, x: :value, y: :value },

        # audio
        enable_sound: {},
        define_sound: { name: :name, frequency: :int, duty: :option, decay: :option, volume: :int },
        beep:         { tone: :tone, duty: :option, decay: :option, volume: :int },
        song:         { name: :name, events: :list, total_frames: :int, duty: :option, volume: :int },
        play_song:    { name: :name },
        stop_music:   {},

        # control flow (bodies nest as #children; an if's else is a :branch attr).
        if:         { cond: :value, else: :branch },
        else:       {},
        loop:       {},
        repeat:     { count: :value, index: :name },
        # timed triggers: the body nests as #children; the counter is a hidden var
        # name, the period/delay an author-time whole number of frames.
        every:      { counter: :name, period: :int },
        after:      { counter: :name, frames: :int },
        func:       { name: :name },
        call:       { target: :name },
        case:       { var: :name, clauses: :list },
        wait_vblank: {},
        halt:       {},
        raw:        { bytes: :text },

        # embedded data
        data:      { name: :name, bytes: :text },
        data_byte: { name: :name, index: :int }, # a fixed index into the blob
        bitmap:    { name: :name, width: :int, height: :int, pixels: :text, transparent: :int },
        backing_buffer: { name: :name, width: :int, height: :int }, # a RAM patch a sprite saves under itself

        # lists
        list_new:  { name: :name, capacity: :int },
        list_push: { name: :name, value: :value },
        list_drop: { name: :name, from: :option },
        list_set:  { name: :name, index: :value, value: :value },
        list_get:  { name: :name, index: :value },
        list_len:  { name: :name },

        # expression values
        int:     { value: :int },
        var_ref: { name: :name },
        binop:   { op: :option, lhs: :value, rhs: :value },
        neg:     { operand: :value },
        held:    { button: :option },
        pressed: { button: :option },
        chance:  { draw: :value, percent: :int }, # draw is the 0..99 value; percent an author-time bound
        read_scanline: {}, # the current scanline (VCOUNT) — a hardware-only value read, no operands
      }.freeze

      # Verify a whole program tree. Returns the node on success; raises
      # {InvariantError} on the first problem.
      #
      # Two passes, and the order is the point. The first proves the verifier
      # *recognizes* every node — its kind has a SLOTS row — so a new primitive the
      # schema hasn't been taught about is a hard, unambiguous error before any
      # other check can mask it. Only then does the second pass judge whether each
      # recognized node is well-formed. A node the verifier can't identify never
      # slips through as "fine"; it fails loudly, pointing at the missing row.
      def verify!(node)
        node.walk { |n| check_known(n) }
        node.walk { |n| check_node(n) }
        node
      end

      # -- pass 1: every kind must be in the schema (the drift backstop) --

      def check_known(node)
        return if SLOTS.key?(node.kind)

        raise InvariantError,
              "unknown IR kind #{node.kind.inspect} — no Verifier::SLOTS row. If you added a new IR " \
              "primitive, declare its fields in Verifier::SLOTS (and Node::CATEGORY); the verifier refuses " \
              "any node it hasn't been taught, so drift can't slip through silently."
      end

      # -- pass 2: every recognized node must be well-formed --

      def check_node(node)
        schema = SLOTS.fetch(node.kind) # present — pass 1 proved it
        node.attrs.each { |field, value| check_field(node, schema, field, value) }
        check_value_slots_present(node, schema)
        check_children_are_statements(node)
        node
      end

      # An operand present on the node must match its declared slot.
      def check_field(node, schema, field, value)
        type = schema.fetch(field) do
          raise InvariantError,
                "#{node.kind}.#{field} is not a declared field — add it to Verifier::SLOTS[:#{node.kind}] " \
                "(a verb set an operand the schema doesn't know about)"
        end

        return if valid?(type, value)

        raise InvariantError, mismatch_message(node, field, type, value)
      end

      # A value slot must actually be there — a verb that forgot to set it is as
      # broken as one that set it wrong.
      def check_value_slots_present(node, schema)
        schema.each do |field, type|
          next unless type == :value
          next if node.attrs.key?(field)

          raise InvariantError,
                "#{node.kind}.#{field} is missing — a value operand wasn't set (route it through Build.wrap)"
        end
      end

      # Statements nest as children; value nodes live in #attrs. A value node found
      # among the children means a verb wired an operand as a statement.
      def check_children_are_statements(node)
        node.children.each do |child|
          next if child.statement?

          raise InvariantError,
                "#{node.kind} holds a #{child.kind} (category #{child.category}) as a child — " \
                "only statements nest as children; a value operand belongs in #attrs"
        end
      end

      # -- predicates --

      # A value slot must hold a value node (any kind whose category is :value — an
      # int literal, a var_ref, a binop, ...); a structural slot must hold its
      # author-time literal, and may be nil when the field is optional.
      def valid?(type, value)
        return value.is_a?(Node) && value.value? if type == :value
        return true if value.nil?

        TYPES.fetch(type).call(value)
      end

      def mismatch_message(node, field, type, value)
        if type == :value
          "#{node.kind}.#{field} must be a value node, but holds #{value.inspect} — the verb built this " \
            "node without routing #{field} through Value.node_for / Build.wrap"
        elsif value.is_a?(Node)
          "#{node.kind}.#{field} must be an author-time #{type} (#{value.inspect} is a value node) — a run-time " \
            "value leaked into a structural slot"
        else
          "#{node.kind}.#{field} must be an author-time #{type}, but holds #{value.inspect}"
        end
      end
    end
  end
end
