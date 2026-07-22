# frozen_string_literal: true

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

    # --- Input ---

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

    # --- Sound ---

    # Enable the GBA sound hardware. Call once at the top of your build block.
    # Without this, all beep calls are silent.
    def enable_sound
      raise ArgumentError, "enable_sound already called — only call it once" if @sound_enabled

      @sound_enabled = true
      record(Build.enable_sound)
    end

    # Define a named sound preset for use with beep.
    #
    # @param name [Symbol] preset name
    # @param frequency [Integer] tone frequency in Hz (64-2048 useful range)
    # @param duty [Symbol] wave shape (:eighth, :quarter, :half, :three_quarter)
    # @param decay [Symbol] fade speed (:fast, :medium, :slow, :none)
    # @param volume [Integer] initial volume (0-15)
    #
    # @example
    #   define_sound :paddle_hit, frequency: 880, duty: :quarter, decay: :fast
    #   define_sound :wall_bounce, frequency: 440
    def define_sound(name, frequency:, duty: :half, decay: :fast, volume: 15)
      record(Build.define_sound(name, frequency: frequency, duty: duty, decay: decay, volume: volume))
    end

    # Trigger a beep on sound channel 2 (square wave, no sweep).
    #
    # @param tone [Symbol, Integer] a preset name or frequency in Hz
    # @param duty [Symbol] wave shape (default: :half)
    # @param decay [Symbol] fade speed (default: :fast)
    # @param volume [Integer] initial volume 0-15 (default: 15)
    #
    # @example Preset
    #   beep :high
    #   beep :paddle_hit     # custom preset from define_sound
    #
    # @example Frequency
    #   beep 880
    #   beep 440, duty: :quarter, decay: :slow
    def beep(tone, duty: nil, decay: nil, volume: nil)
      raise ArgumentError, "call enable_sound before beep" unless @sound_enabled

      record(Build.beep(tone, duty: duty, decay: decay, volume: volume))
    end

    # --- Music ---

    # Define a named song using the note/rest DSL.
    # Songs are collected at build time and played by play_song.
    #
    # @param name [Symbol] song name
    #
    # @example
    #   song :gameplay do
    #     tempo 140
    #     note :C4, :eighth
    #     note :E4, :eighth
    #     note :G4, :quarter
    #     rest :quarter
    #   end
    def song(name, &block)
      raise ArgumentError, "song :#{name} already defined" if @songs.key?(name)

      ctx = Music::SongContext.new
      ctx.instance_eval(&block)
      @songs[name] = ctx

      # In the IR a song carries its already-resolved score (frame/frequency
      # pairs) and length, so every backend replays the same tune.
      record(Build.song(name, events: ctx.events, total_frames: ctx.total_frames,
                              duty: ctx.duty, volume: ctx.volume))
    end

    # Advance a previously defined song by one frame. Call once per frame inside
    # the game loop. Uses channel 1 (square wave with sweep) so it doesn't
    # conflict with channel 2 beep/SFX sounds.
    #
    # @param name [Symbol] song name (defined with `song`)
    #
    # @example
    #   play_song :gameplay
    def play_song(name)
      raise ArgumentError, "call enable_sound before play_song" unless @sound_enabled
      unless @songs.key?(name)
        raise ArgumentError, "unknown song :#{name}. Define it with `song :#{name} do ... end`"
      end

      record(Build.play_song(name))
    end

    # Silence the music channel (channel 1).
    # Call this when transitioning to a scene that shouldn't have music.
    def stop_music
      record(Build.stop_music)
    end

    # --- Text ---

    # Draw a text string at (x, y) using the built-in 5x7 bitmap font.
    # Each character is 6px wide (5px glyph + 1px gap), 7px tall.
    # All text is uppercased. Unsupported characters are skipped.
    #
    # @param text [String] text to render
    # @param x [Integer] left edge
    # @param y [Integer] top edge
    # @param c [Symbol, String, Integer] text color
    def draw_text(text, x, y, c)
      record(Build.draw_text(text, x, y, c))
    end

    # Draw a single-digit number (0-9) at (x, y).
    # For multi-digit, call multiple times with offset.
    #
    # @param digit [Integer] 0-9
    # @param x [Integer] left edge
    # @param y [Integer] top edge
    # @param c [Symbol, String, Integer] color
    def draw_digit(digit, x, y, c)
      draw_text(digit.to_s, x, y, c)
    end

    # --- Images ---

    # The unused 16th bit of a BGR555 color, set to mark a pixel transparent — a
    # real color is 0x0000..0x7FFF, so this can never collide with one.
    TRANSPARENT_PIXEL = 0x8000

    # Define a bitmap, two ways.
    #
    # Array form — raw pixel data, the shape the importer produces. +data+ is
    # width*height colors (names, hex strings, or raw BGR555 integers), row-major:
    #
    #   image :friend, width: 16, height: 16, data: bmp.data
    #
    # From-a-file form — hand it an image on your machine and a size, and it's
    # imported (via RubyGBA::Image) and embedded in one step:
    #
    #   image :friend, from: "friend.png", width: 16, height: 16
    #
    # Add transparent: true for a cut-out (an image with its background removed):
    # the removed areas become see-through, so the game field shows through them
    # instead of a rectangle.
    #
    #   image :friend, from: "cutout.png", width: 16, height: 16, transparent: true
    #
    # ASCII-art form — hand-drawn, with a char=>color map and a block of art. The
    # dimensions come from the art's shape, and one char may map to :transparent
    # (those pixels aren't drawn, so the background shows through):
    #
    #   image :ship, "." => :transparent, "#" => :cyan, "*" => :red do
    #     <<~ART
    #       ..#..
    #       .#*#.
    #       #####
    #     ART
    #   end
    #
    # Either way the pixels are packed to 15-bit color and embedded in the ROM; a
    # later `blit` draws it by name.
    # +opts+ is a single trailing hash — the char=>color map (ASCII form, with a
    # block), width:/height:/data: (array form), or from:/width:/height: (file
    # form). It's positional, not keywords, so the char map's string keys (like
    # "#") pass through cleanly.
    def image(name, opts = {}, &block)
      if block
        define_ascii_image(name, opts, &block)
      elsif opts[:from]
        bmp = Image.load(opts[:from], width: opts[:width], height: opts[:height],
                                      transparent: opts.fetch(:transparent, false))
        define_pixel_image(name, width: bmp.width, height: bmp.height, data: bmp.data,
                                 transparent: bmp.transparent)
      else
        define_pixel_image(name, width: opts[:width], height: opts[:height], data: opts[:data],
                                 transparent: opts[:transparent])
      end
    end

    # Draw a bitmap (defined with `image`) at a position, which may be a variable
    # (a moving object) or a constant. Keep it on-screen — off-screen parts aren't
    # clipped at run time yet.
    #
    # @example
    #   blit :friend, :ball_x, :ball_y
    def blit(name, x, y)
      record(Build.blit(name, Value.node_for(x), Value.node_for(y)))
      ensure_var(x) if x.is_a?(Symbol)
      ensure_var(y) if y.is_a?(Symbol)
    end

    # Pack 5-bit RGB channels (0-31 each) into a 15-bit GBA color.
    # Raises on out-of-range values to catch mistakes early.
    def rgb(r, g, b)
      Color.rgb(r, g, b)
    end

    # Pack 8-bit RGB channels (0-255 each) into a 15-bit GBA color.
    # Automatically downsamples to 5-bit per channel.
    def rgb8(r, g, b)
      Color.rgb8(r, g, b)
    end

    # Resolve a color from a name, hex string, or raw value.
    def color(value)
      Color.resolve(value)
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

    # Accept a known button name (from the shared IR vocabulary); raise a plain
    # error for anything else.
    def check_button!(button)
      return if IR::Buttons.known?(button)

      raise ArgumentError, "unknown button: #{button}"
    end

    # Array form of #image: validate the dimensions and pack the pixel colors.
    # +transparent+ (an internal marker color, e.g. from an imported cutout) is
    # left untouched while every other pixel is resolved — otherwise resolving it
    # would mask the marker away — and it's recorded on the bitmap so `blit`
    # skips those pixels, letting the background show through.
    def define_pixel_image(name, width:, height:, data:, transparent: nil)
      positive_dims!(name, width, height)
      expected = width * height
      unless data.length == expected
        raise ArgumentError,
              "image :#{name} is #{width}x#{height}, so it needs #{expected} pixels, but got #{data.length}"
      end

      pixels = data.map { |c| c == transparent ? transparent : Color.resolve(c) }.pack("v*")
      record(Build.bitmap(name, width: width, height: height, pixels: pixels, transparent: transparent))
    end

    # ASCII-art form of #image: split the block's art into rows, infer the size
    # from its shape, map each char to a color (or transparency), and pack it.
    def define_ascii_image(name, char_map)
      rows = yield.to_s.each_line.map(&:chomp).reject(&:empty?)
      raise ArgumentError, "image :#{name} has no art" if rows.empty?

      widths = rows.map(&:length).uniq
      unless widths.size == 1
        raise ArgumentError,
              "image :#{name} has ragged rows (#{widths.sort.join(', ')} wide) — every row must be the same length"
      end

      transparent = false
      colors = rows.flat_map do |row|
        row.each_char.map do |ch|
          spec = char_map.fetch(ch) { raise ArgumentError, "image :#{name}: no color mapped for '#{ch}'" }
          if spec == :transparent
            transparent = true
            TRANSPARENT_PIXEL
          else
            Color.resolve(spec)
          end
        end
      end

      record(Build.bitmap(name, width: widths.first, height: rows.size,
                                pixels: colors.pack("v*"),
                                transparent: transparent ? TRANSPARENT_PIXEL : nil))
    end

    def positive_dims!(name, width, height)
      return if width.is_a?(Integer) && width.positive? && height.is_a?(Integer) && height.positive?

      raise ArgumentError, "image :#{name} needs positive width and height (got #{width}x#{height})"
    end

    # held/pressed hand back a Condition and take no block. A block here means a
    # dropped `.then` — the block would attach to held/pressed and be silently
    # ignored — so name the fix instead of losing the code.
    def reject_block!(verb, button)
      raise ArgumentError,
            "#{verb}(:#{button}) has no block form — write #{verb}(:#{button}).then { ... } " \
            "(or the block-taking if_#{verb} :#{button} do ... end)"
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
