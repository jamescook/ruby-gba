# frozen_string_literal: true

# DSL verbs grouped into concern modules, each mixed into Builder below. They keep
# the flat DSL surface (every verb a top-level method) while letting each area live
# in its own file. New concerns get required here and included in the class body.
require_relative "builder/randomness"
require_relative "builder/sound"
require_relative "builder/music"
require_relative "builder/text"
require_relative "builder/images"
require_relative "builder/input"
require_relative "builder/drawing"
require_relative "builder/variables"
require_relative "builder/control_flow"
require_relative "builder/scenes"
require_relative "builder/collision"
require_relative "builder/tiled"

module RubyGBA
  # DSL context for building a GBA ROM.
  #
  # Each DSL method builds a node in an IR tree — an in-memory description of what
  # the program does — and returns. {RubyGBA.build} lowers the finished tree to a
  # ROM once the block ends. Building the whole tree before lowering any of it is
  # what lets a {#call} refer to a {#func} defined later in the block.
  #
  # @example Minimal ROM
  #   rom = RubyGBA.build("MYGAME", code: "BMGE", maker: "01") do
  #     entry { loop_forever }
  #   end
  #
  # @example Draw pixels
  #   rom = RubyGBA.build("PIXELS", code: "BPXL", maker: "01") do
  #     screen :bitmap
  #     pixel 120, 80, :red
  #     pixel 121, 80, color("#00FF00")
  #     fill_rect 50, 50, 30, 20, rgb(31, 31, 0)
  #     halt
  #   end
  class Builder
    include Constants

    include Randomness # seed, randomize, roll, rand, chance
    include Sound      # enable_sound, define_sound, beep
    include Music      # song, play_song, stop_music
    include Text       # draw_text, draw_number
    include Images     # image, blit, rgb, rgb8, color
    include Input      # if_held, if_pressed, held, pressed
    include Drawing    # screen, pixel, fill_rect, clear_screen, dma_fill_rect, draw_rect_at
    include Variables  # set/var, add, sub, negate/flip, copy, abs, negate_abs, clamp, var_address, variables
    include ControlFlow # game_loop, wait_vblank, repeat, every, after, halt, debug_halt, if_eq..if_le
    include Scenes     # func, call, scene, case_var, dump_func
    include Collision  # box (overlaps? lives on the shape — Box/Sprite via Bounds)
    include Tiled      # tiles, background (tiled-graphics surface; hardware lowering to follow)

    # Shorthand for the IR node constructors, so DSL methods can build tree
    # nodes as terse Build.set(...) calls.
    Build = IR::Build

    def initialize
      @variables = {}          # name → { address:, initial: } — introspection metadata
      @next_var_addr = IWRAM_START
      @functions = {}          # name → deferred body block (evaluated at emit time)
      @dump_requests = []      # function names to disassemble from the lowered ROM
      @songs = {}              # name → Music::SongContext (for build-time validation)
      @sound_enabled = false
      @debug_halted = false
      @repeat_seq = 0          # counts repeat loops, to name each one's hidden index var
      @timer_seq = 0           # counts every/after timers, to name each one's hidden counter var
      @rng_seq = 0             # counts anonymous random draws, to name each one's hidden var
      @approach_seq = 0        # counts approach calls, to name each one's hidden delta var
      @number_seq = 0          # counts draw_number calls, to name each one's hidden digit vars
      @sprite_seq = 0          # counts sprites, to name each one's hidden position/backing vars
      @images = {}             # image name → [width, height], so a sprite can size itself from its art
      @tilesets = {}           # tileset name → { chars:, tile_w:, tile_h: } (a character→tile-image map)
      @sprites = []            # live sprites, repainted after every wait_vblank
      @prng_used = false       # whether the program draws random numbers (seeds the stream once)
      @boot_inits = []         # statements hoisted to program start (hidden state that must start known)
      @pending_conditions = [] # Conditions built but not yet used; leftovers are orphans

      # The program the DSL builds: an IR tree of nodes that {RubyGBA.build}
      # lowers to a ROM. Each statement attaches to the container on top of the
      # stack — the program root, or an open control-flow block (a loop, an if, a
      # func body) while its block runs.
      @program = Build.program
      @container_stack = [@program]
    end

    # The IR tree built so far (the whole program). Lets tests assert the DSL
    # constructs the right tree without lowering it to a ROM.
    attr_reader :program

    # Function names queued by dump_func, disassembled from the lowered ROM.
    attr_reader :dump_requests

    # --- Lists ---

    # Declare a named list — a bounded, ordered collection whose length changes as
    # the game runs (a snake's body, a queue of shots). Returns a {List} handle you
    # push onto, drop from, index into, and iterate.
    #
    #   body = list :body, capacity: 256
    #   body.push head_cell
    #   body.shift unless growing
    #
    # `capacity` is the most it can ever hold; it's rounded up to a power of two so
    # the hardware can wrap an index cheaply, and every backend enforces that same
    # ceiling, so a program overflows at the same point everywhere.
    #
    # @param name [Symbol] the list's name
    # @param capacity [Integer] the most items it can hold (rounded up to 2^n)
    # @return [List] a handle to the list
    def list(name, capacity:)
      record(Build.list_new(name, capacity))
      List.new(self, name)
    end

    # Define an entry point of raw ARM instructions — the escape hatch for
    # patterns the DSL can't express. The block runs in an {EntryContext} that
    # collects the emitted bytes into a raw IR node, which the backend appends to
    # the code verbatim.
    def entry(&block)
      ctx = EntryContext.new
      ctx.instance_eval(&block)
      record(Build.raw(ctx.bytes))
    end

    # --- Finalize (RubyGBA.build calls this once, after the DSL block) ---

    # Build the IR node for every deferred function body, then check that every
    # call and case target names a function that exists. Called automatically by
    # RubyGBA.build after the DSL block.
    def emit_pending_functions
      @functions.each do |name, block|
        push_container(Build.func(name)) do
          instance_eval(&block)
        end
      end

      verify_targets_defined!
      initialize_rng_stream
      emit_boot_inits
    end

    # --- Handle hooks ---
    # The Value / Condition / Branch / List classes call these back into the
    # builder to record their statements at the current build point.

    # The hook behind the expression DSL's `(cond).then { ... }`: record an `if`
    # node from an already-built condition node and gather the block's statements
    # into it, returning the node so an `.else` can attach to it. A {Condition}
    # calls this; user code writes `.then`, not this.
    def record_conditional(cond_node, &block)
      if_node = Build.if_(cond_node)
      push_container(if_node) do
        instance_eval(&block)
      end
      if_node
    end

    # The hook a {List} handle uses to append one of its statement operations
    # (push / drop / element-set) at the current build point — the collection
    # counterpart to how a {Value}'s mutators record through the builder's verbs.
    def record_statement(node)
      record(node)
    end

    # A {Condition} enters this "pending" set when it's built (Condition#initialize)
    # and leaves it when it's used (see #consume_condition). It's bookkeeping for
    # one guardrail only, never part of the program.
    def track_condition(condition)
      @pending_conditions << condition
    end

    # A {Condition} was used — branched on with `.then`, or folded into another via
    # `&` / `|` — so peel it back out of the pending set.
    def consume_condition(condition)
      @pending_conditions.delete(condition)
    end

    # The Conditions still pending at build's end: built but never used. Each did
    # nothing, which almost always means it was handed to a native `if` (a Condition
    # is truthy to Ruby, so the `if` body ran unconditionally and the comparison was
    # silently ignored). The orphaned-Condition guardrail reports these.
    def pending_conditions
      @pending_conditions
    end

    # The hook behind `.then { }.else { }`: gather the else block's statements
    # into an `else` node and attach it to the if node the `.then` produced.
    def record_else(if_node, &block)
      else_node = Build.else_
      @container_stack.push(else_node)
      begin
        instance_eval(&block)
      ensure
        @container_stack.pop
      end
      if_node[:else] = else_node
    end

    private

    # --- Boot-time initialization ---

    # Register a statement to run once at program start, before anything else. It's
    # for hidden state that must begin from a known value because console RAM isn't
    # zero at power-on — the random seed, a timer's frame counter. #emit_boot_inits
    # hoists these to the very front at finalize, so they can be recorded from deep
    # inside a loop or scene yet still run once, up front.
    def at_boot(node)
      @boot_inits << node
    end

    # Hoist every registered boot statement to the front of the program, keeping
    # the order they were registered in, so all hidden state is set before the
    # game starts.
    def emit_boot_inits
      @boot_inits.reverse_each do |node|
        @program.children.unshift(node)
        node.parent = @program
      end
    end

    # Look up a variable's IWRAM address, raising if not declared.
    def var_address!(name)
      entry = @variables[name]
      raise ArgumentError, "unknown variable :#{name}. Use `set :#{name}, value` first." unless entry
      entry[:address]
    end

    # Allocate a variable on first mention, tracking its name and address for
    # introspection (var_address / variables). Only a Symbol names a variable, so
    # any other operand — a literal, an expression — is ignored: callers can pass a
    # value operand straight through without guarding, and a non-name never
    # allocates a phantom entry. (Operand types are already validated upstream at
    # the Value.node_for coercion boundary, so ensure_var needn't gate them.)
    def ensure_var(name)
      return unless name.is_a?(Symbol)
      return if @variables.key?(name)

      addr = @next_var_addr
      @next_var_addr += 4
      @variables[name] = { address: addr }
    end

    # --- IR tree construction ---

    # Attach a freshly built IR node to the open container and return it.
    def record(node)
      @container_stack.last.add_child(node)
      node
    end

    # Build a container node, attach it, and keep it open while the block runs so
    # nested statements land inside it — then close it. The block-taking control
    # methods (loops, conditionals, func bodies) use this.
    def push_container(node)
      record(node)
      @container_stack.push(node)
      yield
    ensure
      @container_stack.pop
    end

    # Low-level entry context for raw instruction emission.
    # Collects the raw ARM emitted inside an `entry` block into a byte string,
    # which becomes a raw IR node the backend appends verbatim.
    class EntryContext
      attr_reader :bytes

      def initialize
        @bytes = +"".b
      end

      def loop_forever
        @bytes << ASM.loop_forever
      end

      def nop
        @bytes << ASM.nop
      end
    end
  end
end
