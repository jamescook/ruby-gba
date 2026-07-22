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
  #     display :bitmap
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
    include Text       # draw_text, draw_digit
    include Images     # image, blit, rgb, rgb8, color
    include Input      # if_held, if_pressed, held, pressed

    # Friendly display mode presets — the names {#display} accepts.
    DISPLAY_MODES = {
      bitmap:       MODE_3 | BG2_ENABLE,       # 240x160, 15-bit direct color
      bitmap_indexed: MODE_4 | BG2_ENABLE,     # 240x160, 8-bit indexed, double buffered
      bitmap_small: MODE_5 | BG2_ENABLE,       # 160x128, 15-bit, double buffered
      tiled:        MODE_0 | BG0_ENABLE,       # 4 regular BG layers (most games)
      affine:       MODE_2 | BG2_ENABLE,       # 2 rotatable BG layers
    }.freeze

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

    # --- RAM Variables ---

    # Set a variable's value. If the variable hasn't been declared yet,
    # it's automatically allocated in IWRAM. Returns a {Value} handle for the
    # variable, so it can be compared and mutated with the expression DSL.
    #
    # @param name [Symbol] variable name
    # @param value [Integer] value to store
    # @return [Value] a handle to the variable
    def set(name, value)
      record(Build.set(name, Value.node_for(value)))
      ensure_var(name)
      Value.new(self, Build.var_ref(name), name: name)
    end

    # Explicit variable declaration — same as `set` but reads better
    # when you want to declare variables at the top of a build block.
    alias var set

    # Add to a variable: var += operand.
    # Operand can be an immediate (Integer) or another variable (Symbol).
    #
    # @param name [Symbol] variable name
    # @param operand [Integer, Symbol] value to add
    def add(name, operand)
      record(Build.add(name, Value.node_for(operand)))
      ensure_var(name)
      ensure_var(operand) if operand.is_a?(Symbol)
    end
    alias add_var add

    # Subtract from a variable: var -= operand.
    # Operand can be an immediate (Integer) or another variable (Symbol).
    #
    # @param name [Symbol] variable name
    # @param operand [Integer, Symbol] value to subtract
    def sub(name, operand)
      record(Build.sub(name, Value.node_for(operand)))
      ensure_var(name)
      ensure_var(operand) if operand.is_a?(Symbol)
    end
    alias sub_var sub

    # Flip a variable's sign: var = -var.
    # Useful for reversing direction vectors.
    def negate(name)
      record(Build.negate(name))
      ensure_var(name)
    end
    alias flip negate

    # Copy one variable's value into another: dest = src.
    #
    # @param dest [Symbol] destination variable
    # @param src [Symbol] source variable
    def copy(dest, src)
      record(Build.copy(dest, src))
      ensure_var(dest)
      ensure_var(src)
    end

    # Absolute value: var = |var|
    # If var < 0, negate it. Otherwise leave it.
    def abs(name)
      record(Build.abs(name))
      ensure_var(name)
    end

    # Make a variable negative: var = -|var|
    # If var > 0, negate it. Otherwise leave it.
    def negate_abs(name)
      record(Build.negate_abs(name))
      ensure_var(name)
    end

    # Clamp a variable to [min, max] range.
    #
    # @param name [Symbol] variable name
    # @param min_val [Integer] minimum value
    # @param max_val [Integer] maximum value
    def clamp(name, min_val, max_val)
      record(Build.clamp(name, min_val, max_val))
      ensure_var(name)
    end

    # Get the IWRAM address allocated for a variable.
    # Useful for debugging and testing.
    #
    # @param name [Symbol] variable name
    # @return [Integer] IWRAM address
    def var_address(name)
      var_address!(name)
    end

    # All declared variables with their IWRAM addresses.
    # @return [Hash{Symbol => Hash}]
    def variables
      @variables.dup
    end

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

    # Set the display mode.
    #
    # @param mode [Symbol, Integer] a friendly name or raw REG_DISPCNT value
    #
    # @example Friendly
    #   display :bitmap          # MODE_3 | BG2_ENABLE
    #   display :tiled           # MODE_0 | BG0_ENABLE
    #
    # @example Raw (full control)
    #   display MODE_3 | BG2_ENABLE | OBJ_ENABLE
    def display(mode)
      case mode
      when Symbol
        unless DISPLAY_MODES.key?(mode)
          raise ArgumentError, "unknown display mode: #{mode}. Known: #{DISPLAY_MODES.keys.join(', ')}"
        end
      when Integer
        # a raw REG_DISPCNT value — passed through untouched
      else
        raise ArgumentError, "expected Symbol or Integer, got #{mode.class}"
      end

      record(Build.display(mode))
    end

    # Draw a single pixel in bitmap mode (MODE_3).
    # Writes a 15-bit color to VRAM at the (x, y) offset.
    #
    # @param x [Integer] horizontal position (0-239)
    # @param y [Integer] vertical position (0-159)
    # @param c [Symbol, String, Integer] color (see {Color.resolve})
    def pixel(x, y, c)
      validate_coords!(x, y)
      record(Build.pixel(x, y, c))
    end

    # Fill a rectangle in bitmap mode (MODE_3).
    #
    # @param x [Integer] left edge (0-239)
    # @param y [Integer] top edge (0-159)
    # @param w [Integer] width in pixels
    # @param h [Integer] height in pixels
    # @param c [Symbol, String, Integer] fill color
    def fill_rect(x, y, w, h, c)
      record(Build.fill_rect(x, y, w, h, c))
    end

    # Stop execution (branch to self). Use after drawing static scenes.
    def halt
      record(Build.halt)
    end

    # Debug breakpoint: stop building here, so everything after this call is
    # ignored. Use it to bisect rendering issues — everything before debug_halt
    # runs, everything after never makes it into the ROM. Prints a warning so you
    # remember to remove it.
    #
    # @example Bisecting a black screen
    #   display :bitmap
    #   clear_screen :red      # does this show up?
    #   debug_halt              # ← ROM stops here
    #   draw_text "HELLO"      # ← never recorded
    #   game_loop { ... }      # ← never recorded
    def debug_halt
      warn "[ruby-gba] debug_halt — ROM truncated here. Remove debug_halt when done."
      record(Build.halt) # the lowered ROM stops (branches to self) at this point
      @debug_halted = true
      throw :debug_halt
    end

    # True if debug_halt was called (used by RubyGBA.build to skip finalization steps).
    def debug_halted?
      @debug_halted
    end

    # --- Game Loop ---

    # Wait for the vertical blank — the safe moment to change what's on screen.
    def wait_vblank
      record(Build.wait_vblank)
    end

    # Wrap a block of code in an infinite loop. The block's statements become the
    # loop body in the IR tree; the backend adds the jump back to the top.
    #
    # @example
    #   game_loop do
    #     wait_vblank
    #     # ... game logic ...
    #   end
    def game_loop(&block)
      push_container(Build.loop_) do
        instance_eval(&block)
      end
    end

    # Run a block a set number of times, counting at run time. The block is given
    # a Value for the current index (0 up to count-1), so it can drive positions,
    # array access, and the like:
    #
    #   repeat(8) { |i| dma_fill_rect 119, i * 20 + 2, 2, 12, :gray }
    #
    # This is the run-time counterpart to Ruby's `8.times { |i| ... }`. Reach for
    # `times` when the count is known as you write the program (it's baked in);
    # reach for `repeat` when the count is decided while the game runs (a Value,
    # a variable — e.g. how many segments the snake has right now).
    #
    # @param count [Value, Integer, Symbol] how many times to run the block
    def repeat(count, &block)
      raise ArgumentError, "repeat needs a block: repeat(n) { |i| ... }" unless block

      @repeat_seq += 1
      index = :"__repeat_#{@repeat_seq}"
      ensure_var(index)
      ensure_var(count) if count.is_a?(Symbol)
      i = Value.new(self, Build.var_ref(index), name: index)
      push_container(Build.repeat(Value.node_for(count), index)) do
        instance_exec(i, &block)
      end
    end

    # The console refreshes the screen ~59.73 times a second; like every game, we
    # count that as a round 60 frames per second. It's what lets a timer be given
    # in seconds — the unit a person actually thinks in — and turned into frames.
    FRAMES_PER_SECOND = 60

    # Run the block on a repeating beat — a blinking prompt, a spawn wave, a
    # repeating sound. Like {#repeat}, the counter behind it is hidden and managed
    # for you, so there's nothing to declare or reset. Call it once inside your game
    # loop, where each pass through the loop is one frame.
    #
    # The interval is +n+ frames, or +n+ seconds when you'd rather think in time —
    # the framework converts seconds to frames for you:
    #
    #   every(30) { blink.set 1 }              # every 30 frames
    #   every(0.5, :seconds) { blink.set 1 }   # the same, said in seconds
    #
    # @param n [Integer, Numeric] the interval (frames must be whole; seconds may be fractional)
    # @param unit [Symbol] :frames (default) or :seconds
    def every(n, unit = :frames, &block)
      counter = timer_counter!(:every, n, unit, block)
      frames = to_frames(n, unit)
      record(Build.add(counter, 1))
      reached = Build.binop(:>=, Build.var_ref(counter), Build.int(frames))
      push_container(Build.if_(reached)) do
        record(Build.set(counter, Build.int(0))) # start the next interval over
        instance_eval(&block)
      end
    end

    # Run the block once, +n+ frames (or seconds) from now, then never again — a
    # one-shot delay: an attract-mode timeout, a "GO!" that clears itself, a
    # scripted beat. The hidden counter stops once it reaches the target, so the
    # block fires exactly once. Call it inside your game loop, where each pass is
    # one frame.
    #
    #   after(600) { state.set 1 }             # 600 frames in
    #   after(10, :seconds) { state.set 1 }    # the same, said in seconds
    #
    # @param n [Integer, Numeric] the delay (frames must be whole; seconds may be fractional)
    # @param unit [Symbol] :frames (default) or :seconds
    def after(n, unit = :frames, &block)
      counter = timer_counter!(:after, n, unit, block)
      frames = to_frames(n, unit)
      # Count up only until the counter reaches the target — so it never overflows
      # or fires twice — and run the block on the one frame it lands exactly on it.
      not_yet = Build.binop(:<, Build.var_ref(counter), Build.int(frames))
      push_container(Build.if_(not_yet)) do
        record(Build.add(counter, 1))
        reached = Build.binop(:==, Build.var_ref(counter), Build.int(frames))
        push_container(Build.if_(reached)) do
          instance_eval(&block)
        end
      end
    end

    # --- Subroutines ---

    # Define a named subroutine. The block is stored and evaluated after the main
    # block (so func/call order in the DSL doesn't matter).
    #
    # @param name [Symbol] function name
    def func(name, &block)
      raise ArgumentError, "function :#{name} already defined" if @functions.key?(name)

      @functions[name] = block
    end

    # Call a named subroutine. The target is resolved by name when the tree is
    # lowered, so it may be defined before or after this call.
    #
    # @param name [Symbol] function name
    def call(name)
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

    # --- State Machine / Scenes ---

    # Define a scene (named subroutine for a game state).
    # Internally prefixed with `_scene_` to avoid clashing with func names.
    #
    # @param name [Symbol] scene name
    def scene(name, &block)
      func(:"_scene_#{name}", &block)
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

    # --- Conditionals ---
    # Compare a variable against an immediate or another variable.
    # The block runs only when the condition is true.

    # Maps DSL condition → the IR comparison operator, for building the `if`
    # node's condition (a binop over the variable and the operand).
    COND_TO_OP = {
      eq: :==, ne: :!=, gt: :>, lt: :<, ge: :>=, le: :<=,
    }.freeze

    %i[eq ne gt lt ge le].each do |cond|
      # Define if_eq, if_ne, if_gt, if_lt, if_ge, if_le
      define_method(:"if_#{cond}") do |var_name, operand, &block|
        emit_conditional(cond, var_name, operand, &block)
      end

      # Define if_gte (alias for if_ge), if_lte (alias for if_le)
      case cond
      when :ge then define_method(:if_gte) { |v, o, &b| emit_conditional(:ge, v, o, &b) }
      when :le then define_method(:if_lte) { |v, o, &b| emit_conditional(:le, v, o, &b) }
      end
    end

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

    # --- DMA ---

    # Clear the entire screen to a solid color.
    # Much faster than pixel-by-pixel: one DMA transfer fills all of VRAM.
    #
    # @param c [Symbol, String, Integer] fill color
    def clear_screen(c)
      record(Build.clear_screen(c))
    end

    # Fill a rectangle at a fixed position and size.
    #
    # @param x [Integer] left edge
    # @param y [Integer] top edge
    # @param w [Integer] width in pixels (must be even for the fast fill)
    # @param h [Integer] height in pixels
    # @param c [Symbol, String, Integer] fill color
    def dma_fill_rect(x, y, w, h, c)
      record(Build.dma_fill_rect(x, y, w, h, c))
    end

    # --- Runtime Drawing ---

    # Draw a filled rectangle at a position determined at run time.
    # Positions can be variables (Symbol) or constants (Integer); the size is a
    # build-time constant and the width must be even (for the fast fill).
    #
    # @param x_pos [Symbol, Integer] x position (variable or constant)
    # @param y_pos [Symbol, Integer] y position (variable or constant)
    # @param w [Integer] width in pixels (must be even, build-time constant)
    # @param h [Integer] height in pixels (build-time constant)
    # @param c [Symbol, String, Integer] fill color
    def draw_rect_at(x_pos, y_pos, w, h, c)
      record(Build.draw_rect_at(Value.node_for(x_pos), Value.node_for(y_pos), w, h, c))
      ensure_var(x_pos) if x_pos.is_a?(Symbol)
      ensure_var(y_pos) if y_pos.is_a?(Symbol)
    end

    private

    # Record an `if` node comparing a variable against an operand, and gather the
    # block's statements into it.
    #
    # @param cond [Symbol] condition (:eq, :ne, :gt, :lt, :ge, :le)
    # @param var_name [Symbol] variable to compare
    # @param operand [Integer, Symbol] immediate value or variable name to compare against
    def emit_conditional(cond, var_name, operand, &block)
      condition = Build.binop(COND_TO_OP.fetch(cond), Build.var_ref(var_name), Value.node_for(operand))
      ensure_var(var_name)
      ensure_var(operand) if operand.is_a?(Symbol)

      push_container(Build.if_(condition)) do
        instance_eval(&block)
      end
    end

    # --- Timers (every / after) ---

    # Validate a timer's interval, unit, and block, then allocate the hidden frame
    # counter it counts on. The counter is cleared at boot (console RAM isn't
    # reliably zero at power-on) so the first interval measures from frame zero.
    def timer_counter!(verb, n, unit, block)
      raise ArgumentError, "#{verb} needs a block: #{verb}(n) { ... }" unless block
      unless %i[frames seconds].include?(unit)
        raise ArgumentError, "#{verb}'s unit is :frames or :seconds, got #{unit.inspect}"
      end
      # Frames are whole; seconds may be fractional (half a second is fine), but
      # either way the interval must come out to at least one frame.
      valid = unit == :frames ? n.is_a?(Integer) : n.is_a?(Numeric)
      unless valid && n.positive? && to_frames(n, unit).positive?
        raise ArgumentError, "#{verb} needs a positive number of #{unit}, got #{n.inspect}"
      end

      @timer_seq += 1
      counter = :"__timer_#{@timer_seq}"
      ensure_var(counter)
      at_boot(Build.set(counter, Build.int(0)))
      counter
    end

    # A timer interval in whole frames. Frames pass through; seconds convert at the
    # console's frame rate and round to the nearest whole frame.
    def to_frames(n, unit)
      unit == :seconds ? (n * FRAMES_PER_SECOND).round : n
    end

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
    # introspection (var_address / variables).
    def ensure_var(name)
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

    # Every call and case target must name a defined function. Check that here, so
    # a missing target surfaces as a clear error at build time. Walking the whole
    # tree (not just statement children) reaches targets nested in else-branches.
    def verify_targets_defined!
      @program.walk do |node|
        case node.kind
        when :call
          check_target_defined!(node[:target])
        when :case
          node[:clauses].each { |_value, target| check_target_defined!(target) }
        end
      end
    end

    def check_target_defined!(name)
      return if @functions.key?(name)

      raise ArgumentError, "function :#{name} called but never defined"
    end

    def validate_coords!(x, y)
      raise ArgumentError, "x=#{x} out of range (0-#{SCREEN_WIDTH - 1})" unless (0...SCREEN_WIDTH).cover?(x)
      raise ArgumentError, "y=#{y} out of range (0-#{SCREEN_HEIGHT - 1})" unless (0...SCREEN_HEIGHT).cover?(y)
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
