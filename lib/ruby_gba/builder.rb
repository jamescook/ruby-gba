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
      @image_bounds = {}       # image name → [x, y, w, h] box around its visible (non-transparent) pixels, for collision
      @tilesets = {}           # tileset name → { chars:, by_number:, tile_w:, tile_h:, solid_images: } — a tile-image map addressable by character or by number (a CSV cell)
      @screen_mode = nil       # the current display mode (set by `screen`), so `sprite` picks its backend
      @sprites = []            # live software sprites, repainted after every wait_vblank
      @hw_sprites = []         # live hardware sprites, drawn (into the sprite table) after every wait_vblank
      @hud_objects = []        # tiled-mode text/number glyph sprites, drawn on top after every wait_vblank
      @glyph_images = {}       # [font, char, color] → a cached glyph image name (one 8x8 sprite tile per glyph)
      @animations = []         # flipbook sprites, whose pose is advanced on a beat after every wait_vblank
      @prng_used = false       # whether the program draws random numbers (seeds the stream once)
      @boot_inits = []         # statements hoisted to program start (hidden state that must start known)
      @pending_conditions = [] # Conditions built but not yet used; leftovers are orphans
      @present_nodes = []      # every frame's present-objects node, filled with the full object list at finalize
      @scene_gates = {}        # scene func name → [state_var, value] it's dispatched on (from case_var), for gating its presentation
      @current_scene_gate = nil # while a scene func's body is being built: the [state_var, value] its declarations belong to
      @building_scene = nil    # the scene func name currently being built (lets its presentation be declared inside it)

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
      @scene_gates = scan_scene_gates # which state value each scene is shown for (from case_var)

      # The program's default display mode — whatever the top-level `screen` left set.
      # Each scene starts from this, so one scene's `screen` (a tiled game) can't leak
      # into the next (a bitmap title): a scene is bitmap or tiled by what IT declares,
      # or the default, never by which scene happened to be built before it. That's what
      # lets `sprite`/`draw_text`/`draw_number` pick software vs hardware per scene.
      default_screen_mode = @screen_mode

      @functions.each do |name, block|
        # A scene's declarations belong to it: while its body is built, remember the
        # scene (so its HUD/sprites may be declared here) and the state gate that scopes
        # what it presents to when the scene is active.
        @building_scene = name if @scene_gates.key?(name)
        @current_scene_gate = @scene_gates[name]
        @screen_mode = default_screen_mode
        push_container(Build.func(name)) do
          run_block(&block)
        end
      ensure
        @building_scene = nil
        @current_scene_gate = nil
      end

      finalize_present_lists
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
        run_block(&block)
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
        run_block(&block)
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

    # Which scenes are shown for which state, read from the case_var dispatch(es):
    # a scene func named as a case target is presented only while the dispatched
    # variable holds that clause's value. Maps a scene func name → [state_var, value],
    # so a sprite/HUD declared inside that scene can be gated to when the scene is live.
    def scan_scene_gates
      gates = {}
      @program.walk do |node|
        next unless node.kind == :case

        node[:clauses].each { |value, target| gates[target] ||= [node[:var], value] }
      end
      gates
    end

    # Gate an object's visibility to its scene: a scene-owned object is shown only when
    # both its own shown-flag is set AND its scene is the active one. Rides the object's
    # existing per-frame `active` value, so presentation stays automatic — nothing new to
    # call, and no per-draw flag in game code. Outside a scene, visibility is unchanged.
    def scene_gate(active_node)
      return active_node unless @current_scene_gate

      state_var, value = @current_scene_gate
      Build.binop(:*, active_node, Build.binop(:==, Build.var_ref(state_var), Build.int(value)))
    end

    # Fill every frame's present-objects node with the complete object list once all
    # scenes are built — a scene declares its sprites/HUD inside its own body (built after
    # the game loop), so the list isn't known when wait_vblank records the node. A frame
    # that ends up with no objects drops the node, so an object-free program is unchanged.
    def finalize_present_lists
      names = @hw_sprites.map(&:object_name) + @hud_objects
      @present_nodes.each do |node|
        if names.empty?
          node.parent&.children&.delete(node)
        else
          node[:names] = names
        end
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

    # --- Importing art from image files ---

    # This gem's own source directory. Frames of the call stack under here are
    # framework internals; the first frame outside it is the user's script — which
    # is where a relative image path should be resolved from (see #resolve_asset_path).
    SOURCE_ROOT = __dir__

    # Turn an image path the user wrote into a real file path. An absolute path is
    # taken as-is. A relative one is resolved *next to the script that named it* —
    # the natural expectation ("hero.png is beside my game") — falling back to the
    # working directory, and finally a plain-language error that names where it
    # looked. (Resolving against the current directory alone is a classic footgun:
    # it works when you run from the project root and mysteriously fails otherwise.)
    def resolve_asset_path(path)
      return path if File.absolute_path?(path)

      dir = caller_script_dir
      if dir
        beside_script = File.expand_path(path, dir)
        return beside_script if File.exist?(beside_script)
      end
      return path if File.exist?(path) # a working-directory-relative path that happens to resolve

      looked = [dir && File.expand_path(path, dir), File.expand_path(path)].compact.uniq
      raise ArgumentError,
            "can't find the image #{path.inspect} — looked at #{looked.map(&:inspect).join(' and ')}. " \
            "Put it next to your script, or pass a full path."
    end

    # The directory of the nearest caller that isn't framework code — i.e. the user's
    # script — so an asset path can be resolved relative to it. nil if the whole
    # stack is internal (nothing sensible to resolve against).
    def caller_script_dir
      frame = caller_locations.find do |loc|
        loc.absolute_path && !loc.absolute_path.start_with?(SOURCE_ROOT)
      end
      frame && File.dirname(frame.absolute_path)
    end

    # A sheet cell's pixel size: one number means a square cell, [w, h] a rectangle.
    def sheet_tile_size(name, tile)
      case tile
      when Integer then [tile, tile]
      when Array then tile
      when nil
        raise ArgumentError, "importing #{name} from an image needs tile: — the size of each cell in pixels"
      else
        raise ArgumentError, "tile: must be a number (square) or [width, height], got #{tile.inspect}"
      end
    end

    # Where a cell sits in a sheet grid: [column, row], or a single number counting
    # cells left-to-right then top-to-bottom. +label+ names it in any error.
    def sheet_cell_at(label, where, cols)
      case where
      when Array then where
      when Integer then [where % cols, where / cols]
      else raise ArgumentError, "#{label} must be a cell number or [column, row], got #{where.inspect}"
      end
    end

    # --- IR tree construction ---

    # Attach a freshly built IR node to the open container and return it. Stamp it
    # with the DSL call site that built it (unless it already carries one), so a
    # later guardrail finding can point the author straight at the line.
    def record(node)
      node.source ||= caller_source_location
      @container_stack.last.add_child(node)
      node
    end

    # The user's call site that led here — "hero.rb:42", the nearest caller that
    # isn't framework code — for diagnostics. nil if the whole stack is internal.
    def caller_source_location
      frame = caller_locations.find do |loc|
        loc.absolute_path && !loc.absolute_path.start_with?(SOURCE_ROOT)
      end
      frame && "#{File.basename(frame.absolute_path)}:#{frame.lineno}"
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

    # Run a DSL block (a game loop body, a `.then`, a func body…) at the current build
    # point. It runs in the block's OWN context, not instance_eval'd onto the builder,
    # so its `self` stays wherever the block was written: this builder at the top level
    # (where these blocks live inside RubyGBA.build's instance_eval, so `self` already
    # is the builder), or a plain Ruby object when a game is split across files — there
    # the block still sees that object's @ivars, while its bare verbs resolve against the
    # build it was handed (see examples/shmup). +args+ pass through to a block that takes them (a loop
    # index). Sub-DSLs with their own vocabulary — `entry`, `case_var`, `font`, `song` —
    # keep instance_eval instead, since their blocks speak a different verb set.
    def run_block(*args, &block)
      block.call(*args)
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
