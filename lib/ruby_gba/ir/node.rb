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
        abs: :var, negate_abs: :var, clamp: :var,
        # persistence: a named variable whose value survives power-off, kept in the
        # cartridge's battery-backed save memory. save_init loads them at boot (or
        # writes their defaults on a fresh cartridge); save_store mirrors one back to
        # save memory when it changes. Categorized as variable ops — that's what they are.
        save_init: :var, save_store: :var,

        # drawing / screen operations
        screen: :draw, pixel: :draw, fill_rect: :draw, clear_screen: :draw,
        draw_rect_at: :draw, draw_text: :draw, dma_fill_rect: :draw, blit: :draw,
        draw_digit: :draw, # one run-time decimal digit, chosen and drawn at run time
        blit_pose: :draw,  # one of a set of same-size images, chosen at run time (a facing/frame)
        background: :draw, # a whole grid of tiles, drawn from a tileset and a map
        scroll_background: :draw, # move the visible window over a background (scrolling)
        camera: :draw, # offset the whole displayed picture (a pan, or a shake)
        fade: :draw,   # blend the whole displayed picture toward a color (a fade, a flash)
        # a moving picture the display composites over the scene each frame: `object`
        # declares one, `present_objects` draws the declared objects for a frame.
        object: :draw, present_objects: :draw,
        # save the pixels under a moving object, then paint them back — so it leaves
        # no trail. They copy a screen patch to/from a backing_buffer (below).
        save_region: :draw, restore_region: :draw,

        # audio operations. define_sound and song are definitions (like func):
        # named registries the audio triggers refer to. beep is a one-off effect,
        # play_song advances a defined song, stop_music silences it.
        enable_sound: :sound, define_sound: :sound, beep: :sound, noise: :sound,
        wave: :sound, stop_wave: :sound,
        song: :sound, play_song: :sound, stop_music: :sound,
        # sampled (PCM) audio: play_sample/stop_sample trigger a recorded sound; the
        # `sample` definition that names its data is a :data kind (below).
        play_sample: :sound, stop_sample: :sound,

        # control flow — these carry nested statements in #children
        # (a scene is just a named func, so it needs no kind of its own; `case`
        # is multi-way dispatch that each backend expands to a chain of ifs). An
        # `if`'s optional else-branch is an `else` node held in its :else attr.
        if: :control, loop: :control, func: :control, call: :control,
        case: :control, else: :control, wait_vblank: :control, halt: :control,
        repeat: :control,

        # timed triggers — a body that runs on a schedule (every N frames) or once
        # after a delay (after N frames). Each carries a hidden frame counter a
        # backend ticks; kept as their own kinds so the tree preserves the intent
        # (rather than baking in the counter+compare they lower to).
        every: :control, after: :control,

        # hardware timers — a counter that runs at a chosen rate (overflowing that
        # many times a second), used for timed work and (later) to clock sampled
        # audio. Starting and stopping one are statements; reading how many times it
        # has overflowed since it started is a value (timer_ticks, below). `on_timer`
        # carries a handler body (its #children) run each time the timer overflows —
        # the timer raises an interrupt and the body runs off it.
        timer_start: :control, timer_stop: :control, on_timer: :control,

        # a raw escape hatch: pre-assembled target bytes appended verbatim. The
        # one node that isn't portable — only a native backend can place it, and
        # the interpreter refuses it (tagged hardware-only in IR::Portability).
        raw: :control,

        # named storage: a definition that reserves space and emits nothing on its
        # own; a consumer refers to it by name. `data` is a format-agnostic blob of
        # bytes in the ROM; `bitmap` is such a blob that also carries width/height,
        # so a draw op knows its shape; `backing_buffer` is a width×height patch of
        # writable RAM a moving object saves the pixels under itself into.
        data: :data, bitmap: :data, backing_buffer: :data,
        sample: :data, # named 8-bit PCM sound data, embedded and played by play_sample
        table: :data,  # a build-time array of numbers, embedded and read by table_get

        # list operations — a bounded, ordered collection whose size is decided at
        # run time: create one (list_new), grow it (list_push), shrink it from
        # either end (list_drop), or overwrite a slot (list_set). Reading it back —
        # an element or its length — is a value (list_get/list_len, below).
        list_new: :list, list_push: :list, list_drop: :list, list_set: :list,

        # expression values — operands, live inside another node's #attrs
        int: :value, var_ref: :value, binop: :value, neg: :value,
        data_byte: :value, list_get: :value, list_len: :value,
        table_get: :value, # read table[index] from a ROM table at a runtime index
        timer_ticks: :value, # how many times a timer has overflowed since it started

        # input reads — an operand whose value comes from the gamepad
        held: :value, pressed: :value,

        # a hardware-only value read: the scanline being drawn now (VCOUNT). Only a
        # real console has it, so the interpreter refuses it (tagged hardware-only in
        # IR::Portability); it's how a debug probe measures a frame's drawing time.
        read_scanline: :value,

        # a probability test as an operand — true a given percent of the time
        chance: :value,

        # do two posed sprites' solid pixels actually overlap? — the shape-accurate
        # half of a collision test, read from each sprite's own picture
        pixels_overlap: :value,
      }.freeze

      # The distinct categories, in a stable order (useful for coverage checks).
      CATEGORIES = %i[root var draw sound control data list value].freeze

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
        %i[root var draw sound control data list].include?(category)
      end

      def leaf?
        @children.empty?
      end

      # Read an operand by name, e.g. node[:var].
      def [](key)
        @attrs[key]
      end

      # Set an operand after construction — used to attach a branch built later,
      # e.g. an `if` node's :else once `.else { ... }` runs. If the value is a
      # child Node, wire its parent back so the tree stays navigable.
      def []=(key, value)
        @attrs[key] = value
        value.parent = self if value.is_a?(Node)
        value
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
