# frozen_string_literal: true

module RubyGBA
  # DSL context for building a GBA ROM.
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

    # Friendly display mode presets.
    # Maps readable names to the hardware register values.
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

    def initialize(rom)
      @rom = rom
      @variables = {}          # name → { address:, initial: }
      @next_var_addr = IWRAM_START
      @functions = {}          # name → entry offset (byte offset in ROM)
      @dump_requests = []      # function names to disassemble after emit
      @songs = {}              # name → Music::SongContext
      @debug_halted = false

      # The IR tree the DSL is building, in parallel with the ARM bytes it still
      # emits. While the migration is in progress the bytes stay authoritative and
      # this tree is only inspected by tests; once every method builds IR, the
      # backend lowers this tree and the byte emission goes away. New statements
      # attach to the container on top of the stack (the program root, or an open
      # control-flow block once those are migrated).
      @program = Build.program
      @container_stack = [@program]
      @suppress_record = false
    end

    # The IR tree built so far (the whole program). Lets tests assert the DSL
    # constructs the right tree without lowering it to a ROM.
    attr_reader :program

    # Function names queued by dump_func, disassembled from the lowered ROM.
    attr_reader :dump_requests

    # --- RAM Variables ---

    # Set a variable's value. If the variable hasn't been declared yet,
    # it's automatically allocated in IWRAM.
    #
    # @param name [Symbol] variable name
    # @param value [Integer] value to store
    def set(name, value)
      record(Build.set(name, value))
      ensure_var(name)
      addr = @variables[name][:address]
      emit_store_immediate(addr, value)
    end

    # Explicit variable declaration — same as `set` but reads better
    # when you want to declare variables at the top of a build block.
    alias var set

    # Load a variable's value into a register.
    # Uses r12 as the address register (scratch register in ARM calling convention).
    #
    # @param reg [Integer] destination register (0-11 recommended)
    # @param name [Symbol] variable name
    def load_var(reg, name)
      ensure_var(name)
      addr = @variables[name][:address]
      @rom.emit(ASM.load_immediate(12, addr))
      @rom.emit(ASM.ldr(reg, 12))
    end

    # Store a register's value into a variable.
    # Uses r12 as the address register.
    #
    # @param name [Symbol] variable name
    # @param reg [Integer] source register
    def store_var(name, reg)
      ensure_var(name)
      addr = @variables[name][:address]
      @rom.emit(ASM.load_immediate(12, addr))
      @rom.emit(ASM.str(reg, 12))
    end

    # Add to a variable: var += operand.
    # Operand can be an immediate (Integer) or another variable (Symbol).
    #
    # @param name [Symbol] variable name
    # @param operand [Integer, Symbol] value to add
    def add(name, operand)
      record(Build.add(name, operand))
      ensure_var(name)
      load_var_into(10, name)

      if operand.is_a?(Symbol)
        ensure_var(operand)
        load_var_into(11, operand)
        @rom.emit(ASM.add_reg(10, 10, 11))
      else
        encoding = ASM.encode_rotated_immediate(operand)
        if encoding
          @rom.emit(ASM.add_imm(10, 10, operand))
        else
          @rom.emit(ASM.load_immediate(11, operand))
          @rom.emit(ASM.add_reg(10, 10, 11))
        end
      end

      store_var_from(10, name)
    end
    alias add_var add

    # Subtract from a variable: var -= operand.
    # Operand can be an immediate (Integer) or another variable (Symbol).
    #
    # @param name [Symbol] variable name
    # @param operand [Integer, Symbol] value to subtract
    def sub(name, operand)
      record(Build.sub(name, operand))
      ensure_var(name)
      load_var_into(10, name)

      if operand.is_a?(Symbol)
        ensure_var(operand)
        load_var_into(11, operand)
        @rom.emit(ASM.sub_reg(10, 10, 11))
      else
        encoding = ASM.encode_rotated_immediate(operand)
        if encoding
          @rom.emit(ASM.sub_imm(10, 10, operand))
        else
          @rom.emit(ASM.load_immediate(11, operand))
          @rom.emit(ASM.sub_reg(10, 10, 11))
        end
      end

      store_var_from(10, name)
    end
    alias sub_var sub

    # Flip a variable's sign: var = -var.
    # Useful for reversing direction vectors.
    def negate(name)
      record(Build.negate(name))
      ensure_var(name)
      load_var_into(10, name)
      @rom.emit(ASM.rsb_imm(10, 10, 0))
      store_var_from(10, name)
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
      load_var_into(10, src)
      store_var_from(10, dest)
    end

    # Absolute value: var = |var|
    # If var < 0, negate it. Otherwise leave it.
    def abs(name)
      record(Build.abs(name))
      ensure_var(name)
      load_var_into(10, name)
      @rom.emit(ASM.cmp_imm(10, 0))
      # If >= 0 (not negative), skip the negate
      branch_pos = @rom.code_offset
      @rom.emit(ASM.branch_cond(:ge, 0))  # placeholder
      @rom.emit(ASM.rsb_imm(10, 10, 0))
      store_var_from(10, name)
      after = @rom.code_offset
      @rom.patch(branch_pos, ASM.branch_cond(:ge, (after - branch_pos) / 4))
    end

    # Make a variable negative: var = -|var|
    # If var > 0, negate it. Otherwise leave it.
    def negate_abs(name)
      record(Build.negate_abs(name))
      ensure_var(name)
      load_var_into(10, name)
      @rom.emit(ASM.cmp_imm(10, 0))
      # If <= 0 (already negative or zero), skip the negate
      branch_pos = @rom.code_offset
      @rom.emit(ASM.branch_cond(:le, 0))  # placeholder
      @rom.emit(ASM.rsb_imm(10, 10, 0))
      store_var_from(10, name)
      after = @rom.code_offset
      @rom.patch(branch_pos, ASM.branch_cond(:le, (after - branch_pos) / 4))
    end

    # Clamp a variable to [min, max] range.
    #
    # @param name [Symbol] variable name
    # @param min_val [Integer] minimum value
    # @param max_val [Integer] maximum value
    def clamp(name, min_val, max_val)
      record(Build.clamp(name, min_val, max_val))
      # The IR clamp is one node; the legacy bytes still expand it into a pair of
      # compares, so don't let those inner set/if calls record their own nodes.
      without_recording do
        if_lt name, min_val do
          set name, min_val
        end
        if_gt name, max_val do
          set name, max_val
        end
      end
    end

    # Get the IWRAM address allocated for a variable.
    # Useful for debugging and testing.
    #
    # @param name [Symbol] variable name
    # @return [Integer] IWRAM address
    def var_address(name)
      var_address!(name)
    end

    # All declared variables with their addresses and initial values.
    # @return [Hash{Symbol => Hash}]
    def variables
      @variables.dup
    end

    # Define the entry point code block (low-level).
    # Instructions inside the block are emitted starting at offset 0x20.
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
      record(Build.display(mode))
      value = case mode
              when Symbol
                DISPLAY_MODES.fetch(mode) do
                  raise ArgumentError, "unknown display mode: #{mode}. Known: #{DISPLAY_MODES.keys.join(', ')}"
                end
              when Integer
                mode
              else
                raise ArgumentError, "expected Symbol or Integer, got #{mode.class}"
              end

      emit_write_reg16(REG_DISPCNT, value)
    end

    # Draw a single pixel in bitmap mode (MODE_3).
    # Writes a 15-bit color to VRAM at the (x, y) offset.
    #
    # @param x [Integer] horizontal position (0-239)
    # @param y [Integer] vertical position (0-159)
    # @param c [Symbol, String, Integer] color (see {Color.resolve})
    def pixel(x, y, c)
      record(Build.pixel(x, y, c))
      validate_coords!(x, y)
      color_val = Color.resolve(c)
      vram_offset = (y * SCREEN_WIDTH + x) * 2
      emit_write_reg16(VRAM_START + vram_offset, color_val)
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
      color_val = Color.resolve(c)

      # Load color into r0 once, then reuse for each pixel
      @rom.emit(ASM.load_immediate(0, color_val))

      h.times do |dy|
        row_y = y + dy
        next if row_y < 0 || row_y >= SCREEN_HEIGHT

        w.times do |dx|
          col_x = x + dx
          next if col_x < 0 || col_x >= SCREEN_WIDTH

          vram_addr = VRAM_START + (row_y * SCREEN_WIDTH + col_x) * 2
          @rom.emit(ASM.load_immediate(1, vram_addr))
          @rom.emit(ASM.store_halfword(0, 1))
        end
      end
    end

    # Stop execution (branch to self). Use after drawing static scenes.
    def halt
      record(Build.halt)
      @rom.emit(ASM.loop_forever)
    end

    # Debug breakpoint: emit a halt and stop processing all further DSL calls.
    # Use this to bisect rendering issues — everything before debug_halt runs,
    # everything after is ignored. Prints a warning so you remember to remove it.
    #
    # @example Bisecting a black screen
    #   display :bitmap
    #   clear_screen :red      # does this show up?
    #   debug_halt              # ← ROM stops here
    #   draw_text "HELLO"      # ← never emitted
    #   game_loop { ... }      # ← never emitted
    def debug_halt
      warn "[ruby-gba] debug_halt — ROM truncated here. Remove debug_halt when done."
      record(Build.halt) # the lowered ROM stops (branches to self) at this point
      @rom.emit(ASM.loop_forever)
      @debug_halted = true
      throw :debug_halt
    end

    # True if debug_halt was called (used by RubyGBA.build to skip finalization steps).
    def debug_halted?
      @debug_halted || false
    end

    # --- Game Loop ---

    # Emit a VBlank wait (busy-poll REG_VCOUNT).
    # Two-phase: wait for current VBlank to end, then wait for next VBlank to start.
    # Uses r0 (address) and r1 (scanline value).
    def wait_vblank
      record(Build.wait_vblank)
      # Load REG_VCOUNT address into r0
      @rom.emit(ASM.load_immediate(0, REG_VCOUNT))

      # Phase 1: Wait while scanline >= 160 (we might still be in last VBlank)
      #   LDRH r1, [r0]          ← offset 0, target of the loop-back branch
      #   CMP r1, #160           ← offset 1
      #   BGE -2 (back to LDRH)  ← offset 2, word_offset -2 = 2 instructions back
      @rom.emit(ASM.load_halfword(1, 0))
      @rom.emit(ASM.cmp_imm(1, 160))
      @rom.emit(ASM.branch_cond(:ge, -2))  # word_offset -2 = back to LDRH

      # Phase 2: Wait while scanline < 160 (wait for VBlank to start)
      #   LDRH r1, [r0]          ← offset 0
      #   CMP r1, #160           ← offset 1
      #   BLT -2 (back to LDRH)  ← offset 2
      @rom.emit(ASM.load_halfword(1, 0))
      @rom.emit(ASM.cmp_imm(1, 160))
      @rom.emit(ASM.branch_cond(:lt, -2))  # word_offset -2 = back to LDRH
    end

    # Wrap a block of code in an infinite loop.
    # The block is evaluated once to emit its instructions, then a branch
    # back to the start is appended.
    #
    # @example
    #   game_loop do
    #     wait_vblank
    #     # ... game logic ...
    #   end
    def game_loop(&block)
      loop_start = @rom.code_offset

      # Emit the block's instructions inside a loop node so nested statements
      # attach to it in the IR tree.
      push_container(Build.loop_) do
        instance_eval(&block)
      end

      # Branch back to loop start
      # Distance in words: (loop_start - current_pc) / 4
      # branch() takes word offset from current position
      branch_target = @rom.code_offset  # where the branch instruction will be
      word_offset = (loop_start - branch_target) / 4
      @rom.emit(ASM.branch(word_offset))
    end

    # --- Subroutines ---

    # Define a named subroutine. The block is stored and emitted after all
    # other code (so func/call order doesn't matter in the DSL).
    #
    # @param name [Symbol] function name
    def func(name, &block)
      existing = @functions[name]
      if existing&.fetch(:block)
        raise ArgumentError, "function :#{name} already defined"
      end

      if existing
        # Forward reference from a prior call — fill in the block
        existing[:block] = block
      else
        @functions[name] = { block: block, entry: nil, calls: [] }
      end
    end

    # Call a named subroutine via BL (branch with link).
    # If the function hasn't been emitted yet, records a placeholder to patch later.
    #
    # @param name [Symbol] function name
    def call(name)
      record(Build.call(name))
      @functions[name] ||= { block: nil, entry: nil, calls: [] }

      call_pos = @rom.code_offset
      entry = @functions[name][:entry]

      if entry
        # Function already emitted — emit BL directly
        word_offset = (entry - call_pos) / 4
        @rom.emit(ASM.branch_link(word_offset))
      else
        # Function not yet emitted — placeholder BL, patch later
        @functions[name][:calls] << call_pos
        @rom.emit(ASM.nop)  # placeholder (will be patched)
      end
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

    # Emit all pending function bodies and patch forward references.
    # Called automatically by RubyGBA.build after the DSL block.
    def emit_pending_functions
      @functions.each do |name, info|
        next unless info[:block]  # skip if only called but never defined

        # Record entry point
        info[:entry] = @rom.code_offset

        # Emit: PUSH {lr}
        @rom.emit(ASM.push(14))

        # Emit function body. The block is only evaluated here (funcs are deferred
        # so call/func order in the DSL doesn't matter), so this is also where the
        # func's IR node and its body get built.
        push_container(Build.func(name)) do
          instance_eval(&info[:block])
        end

        # Emit: POP {pc} to return
        @rom.emit(ASM.pop(15))

        # Record end offset for dump_func
        info[:end] = @rom.code_offset

        # Patch all pending call sites
        info[:calls].each do |call_pos|
          word_offset = (info[:entry] - call_pos) / 4
          @rom.patch(call_pos, ASM.branch_link(word_offset))
        end
        info[:calls].clear
      end

      # Check for any calls to undefined functions
      @functions.each do |name, info|
        unless info[:calls].empty?
          raise ArgumentError, "function :#{name} called but never defined"
        end
      end
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
    # then emits a chain of comparisons + calls.
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

      # In the IR this is one case node dispatching on the variable; the targets
      # are the scene subroutines (each scene is a func named _scene_<name>).
      clauses = ctx.cases.map { |value, raw_name| [value, :"_scene_#{raw_name}"] }
      record(Build.case_(var_name, clauses))

      # The bytes still expand into a reload-compare-call chain (reloading the
      # variable before each compare because a called scene may clobber r10). Keep
      # those inner call()s from recording their own nodes into the tree.
      without_recording do
        ctx.cases.each do |value, raw_name|
          scene_name = :"_scene_#{raw_name}"

          load_var_into(10, var_name)

          encoding = ASM.encode_rotated_immediate(value)
          if encoding
            @rom.emit(ASM.cmp_imm(10, value))
          else
            @rom.emit(ASM.load_immediate(11, value))
            @rom.emit(ASM.cmp_reg(10, 11))
          end

          # Skip the call if not equal
          branch_pos = @rom.code_offset
          @rom.emit(ASM.branch_cond(:ne, 0))  # placeholder

          call(scene_name)

          # Patch the skip branch
          block_end = @rom.code_offset
          skip_words = (block_end - branch_pos) / 4
          @rom.patch(branch_pos, ASM.branch_cond(:ne, skip_words))
        end
      end
    end

    # --- Input ---

    # Button name → KEY_* mask mapping for the DSL.
    BUTTON_MASKS = {
      a: KEY_A, b: KEY_B, select: KEY_SELECT, start: KEY_START,
      right: KEY_RIGHT, left: KEY_LEFT, up: KEY_UP, down: KEY_DOWN,
      r: KEY_R, l: KEY_L,
    }.freeze

    # Execute block only while a button is held down.
    # REG_KEYINPUT is active-low: bit=0 means pressed.
    # Reads input, tests the button bit, skips the block if NOT pressed.
    #
    # Uses r8 (input value) and r9 (scratch). Preserves r0-r7 for game code.
    #
    # @param button [Symbol] :up, :down, :left, :right, :a, :b, :start, :select, :l, :r
    def if_held(button, &block)
      mask = BUTTON_MASKS.fetch(button) { raise ArgumentError, "unknown button: #{button}" }

      push_container(Build.if_(Build.held(button))) do
        # Read REG_KEYINPUT into r8
        @rom.emit(ASM.load_immediate(9, REG_KEYINPUT))
        @rom.emit(ASM.load_halfword(8, 9))

        # Test the button bit: TST r8, #mask (AND but discard result, just set flags)
        # Active-low: bit=0 means pressed. So if (input & mask) != 0, button is NOT pressed.
        # We want to skip the block when NOT pressed, so: branch over block if (input & mask) != 0
        # TST sets Z flag if result is 0 (meaning button IS pressed).
        # BNE = branch if Z=0 = branch if NOT pressed = skip block.
        @rom.emit(ASM.tst_imm(8, mask))

        # Placeholder branch — we'll patch the offset after emitting the block
        branch_pos = @rom.code_offset
        @rom.emit(ASM.branch_cond(:ne, 0))  # placeholder

        # Emit the block
        instance_eval(&block)

        # Patch the branch to skip over the block
        block_end = @rom.code_offset
        skip_words = (block_end - branch_pos) / 4
        @rom.patch(branch_pos, ASM.branch_cond(:ne, skip_words))
      end
    end

    # Execute block when a button is first pressed (edge-detected).
    # Compares current frame's input against previous frame's to detect new presses.
    # Requires a game_loop context (uses :_prev_keys variable).
    #
    # Uses r8 (current input), r9 (scratch).
    #
    # @param button [Symbol] button name
    def if_pressed(button, &block)
      mask = BUTTON_MASKS.fetch(button) { raise ArgumentError, "unknown button: #{button}" }

      push_container(Build.if_(Build.pressed(button))) do
        # Ensure we have a variable to track previous frame's key state
        ensure_var(:_prev_keys)

        # Read current keys into r8 (active-low, so invert for "pressed = 1")
        @rom.emit(ASM.load_immediate(9, REG_KEYINPUT))
        @rom.emit(ASM.load_halfword(8, 9))
        @rom.emit(ASM.mvn_reg(8, 8))           # r8 = ~input (now bit=1 means pressed)
        # Mask to 10 button bits: 0x3FF can't be a rotated imm8, so shift away upper bits
        @rom.emit(ASM.lsl_imm(8, 8, 22))       # shift left to clear upper 22 bits
        @rom.emit(ASM.lsr_imm(8, 8, 22))       # shift right to restore, upper bits now 0

        # Load previous keys into r9
        load_var_into(9, :_prev_keys)

        # New presses = current & ~previous (pressed now but not last frame)
        @rom.emit(ASM.mvn_reg(11, 9))          # r11 = ~prev
        @rom.emit(ASM.and_reg(11, 8, 11))      # r11 = current & ~prev = newly pressed

        # Save current as previous for next frame
        store_var_from(8, :_prev_keys)

        # Test if our button is newly pressed
        @rom.emit(ASM.tst_imm(11, mask))

        # Skip block if not newly pressed (Z=1 means bit was 0)
        branch_pos = @rom.code_offset
        @rom.emit(ASM.branch_cond(:eq, 0))  # placeholder

        instance_eval(&block)

        block_end = @rom.code_offset
        skip_words = (block_end - branch_pos) / 4
        @rom.patch(branch_pos, ASM.branch_cond(:eq, skip_words))
      end
    end

    # --- Conditionals ---
    # Compare a variable against an immediate or another variable.
    # The block runs only when the condition is true.
    # Inverse condition is used to skip over the block.

    # Maps DSL condition → inverse ARM condition (used to SKIP the block).
    INVERSE_COND = {
      eq: :ne, ne: :eq,
      gt: :le, le: :gt,
      ge: :lt, lt: :ge,
    }.freeze

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

    # --- DMA ---

    # Clear the entire screen to a solid color using DMA3 fill.
    # Much faster than pixel-by-pixel: one DMA transfer fills all of VRAM.
    #
    # @param c [Symbol, String, Integer] fill color
    def clear_screen(c)
      record(Build.clear_screen(c))
      color_val = Color.resolve(c)
      # Pack two 16-bit pixels into one 32-bit word for DMA_32BIT transfer
      word = (color_val << 16) | color_val
      dma3_fill(VRAM_START, word, SCREEN_WIDTH * SCREEN_HEIGHT / 2)
    end

    # Fill a rectangular region using DMA3 (one row at a time).
    # Each row is a separate DMA transfer since VRAM rows aren't contiguous
    # for arbitrary rectangles.
    #
    # @param x [Integer] left edge
    # @param y [Integer] top edge
    # @param w [Integer] width in pixels (must be even for 32-bit DMA)
    # @param h [Integer] height in pixels
    # @param c [Symbol, String, Integer] fill color
    def dma_fill_rect(x, y, w, h, c)
      record(Build.dma_fill_rect(x, y, w, h, c))
      color_val = Color.resolve(c)
      word = (color_val << 16) | color_val
      transfers_per_row = w / 2  # 32-bit transfers (2 pixels each)

      h.times do |dy|
        row_addr = VRAM_START + ((y + dy) * SCREEN_WIDTH + x) * 2
        dma3_fill(row_addr, word, transfers_per_row)
      end
    end

    # --- Runtime Drawing ---

    # Draw a filled rectangle at a position determined at runtime.
    # Positions can be variables (Symbol) or constants (Integer).
    # Uses DMA3 row-by-row. Width must be even (for 32-bit DMA).
    #
    # Emits a runtime loop: for each row, compute dest address, fire DMA.
    # Uses r0-r7 as scratch.
    #
    # @param x_pos [Symbol, Integer] x position (variable or constant)
    # @param y_pos [Symbol, Integer] y position (variable or constant)
    # @param w [Integer] width in pixels (must be even, build-time constant)
    # @param h [Integer] height in pixels (build-time constant)
    # @param c [Symbol, String, Integer] fill color
    def draw_rect_at(x_pos, y_pos, w, h, c)
      record(Build.draw_rect_at(x_pos, y_pos, w, h, c))
      color_val = Color.resolve(c)
      word = (color_val << 16) | color_val
      transfers_per_row = w / 2

      # Store fill word to scratch
      ensure_var(:_dma_scratch)
      scratch_addr = @variables[:_dma_scratch][:address]
      @rom.emit(ASM.load_immediate(0, word))
      @rom.emit(ASM.load_immediate(1, scratch_addr))
      @rom.emit(ASM.str(0, 1))

      # Load x into r2
      if x_pos.is_a?(Symbol)
        ensure_var(x_pos)
        load_var_into(2, x_pos)
      else
        @rom.emit(ASM.load_immediate(2, x_pos))
      end

      # Load y into r3
      if y_pos.is_a?(Symbol)
        ensure_var(y_pos)
        load_var_into(3, y_pos)
      else
        @rom.emit(ASM.load_immediate(3, y_pos))
      end

      # Emit h separate DMA transfers (one per row, unrolled)
      # For each row dy=0..h-1:
      #   dest = VRAM_START + ((y + dy) * 240 + x) * 2
      #   = VRAM_START + (y*240 + dy*240 + x) * 2
      h.times do |dy|
        # Compute dest address:
        # r4 = y + dy
        if dy == 0
          @rom.emit(ASM.mov_reg(4, 3))
        else
          @rom.emit(ASM.add_imm(4, 3, dy))
        end

        # r4 = r4 * 240 (multiply by SCREEN_WIDTH)
        @rom.emit(ASM.load_immediate(5, SCREEN_WIDTH))
        @rom.emit(ASM.mul(4, 5, 4))  # r4 = r5 * r4 = 240 * (y+dy)

        # r4 = r4 + x
        @rom.emit(ASM.add_reg(4, 4, 2))

        # r4 = r4 * 2 (byte offset for 16-bit pixels)
        @rom.emit(ASM.lsl_imm(4, 4, 1))

        # r4 = r4 + VRAM_START
        @rom.emit(ASM.load_immediate(5, VRAM_START))
        @rom.emit(ASM.add_reg(4, 4, 5))

        # DMA3SAD = scratch_addr
        @rom.emit(ASM.load_immediate(0, scratch_addr))
        @rom.emit(ASM.load_immediate(1, REG_DMA3SAD))
        @rom.emit(ASM.str(0, 1))

        # DMA3DAD = r4
        @rom.emit(ASM.load_immediate(1, REG_DMA3DAD))
        @rom.emit(ASM.str(4, 1))

        # DMA3CNT = transfers | ENABLE | 32BIT | SRC_FIXED
        dma_src_fixed = 0x01000000
        dma_ctrl = transfers_per_row | DMA_ENABLE | DMA_32BIT | dma_src_fixed
        @rom.emit(ASM.load_immediate(0, dma_ctrl))
        @rom.emit(ASM.load_immediate(1, REG_DMA3CNT))
        @rom.emit(ASM.str(0, 1))
      end
    end

    # --- Sound ---

    # Built-in sound presets for common game sounds — the shared table, so the
    # DSL and the IR backends resolve a preset name to the same sound. The wave
    # shape / fade / frequency encoding lives in Sound::Registers, shared the same
    # way (so a beep sounds identical whether emitted here or lowered from the IR).
    SOUND_PRESETS = Sound::PRESETS

    # Enable the GBA sound hardware. Call once at the top of your build block.
    # Without this, all beep calls are silent.
    def enable_sound
      raise ArgumentError, "enable_sound already called — only call it once" if @sound_enabled
      @sound_enabled = true

      record(Build.enable_sound)
      Sound::Registers.enable.each { |address, value| emit_write_reg16(address, value) }
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
      @custom_sounds ||= {}
      @custom_sounds[name] = { frequency: frequency, duty: duty, decay: decay, volume: volume }
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
      effect = Sound.resolve_effect(tone, duty: duty, decay: decay, volume: volume,
                                          defined: @custom_sounds || {})
      Sound::Registers.channel2(**effect).each do |address, value|
        emit_write_reg16(address, value)
      end
    end

    # --- Music ---

    # Define a named song using the note/rest DSL.
    # Songs are collected at build time and emitted by play_song.
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

    # Emit a looping music sequencer for a previously defined song.
    # Uses channel 1 (square wave with sweep) so it doesn't conflict
    # with channel 2 beep/SFX sounds.
    #
    # Emits unrolled frame comparisons: each note becomes an if_eq check
    # on a frame counter variable, triggering channel 1 at the right time.
    # The counter auto-wraps for looping.
    #
    # @param name [Symbol] song name (defined with `song`)
    #
    # @example
    #   play_song :gameplay
    def play_song(name)
      raise ArgumentError, "call enable_sound before play_song" unless @sound_enabled

      ctx = @songs.fetch(name) do
        raise ArgumentError, "unknown song :#{name}. Define it with `song :#{name} do ... end`"
      end

      # One play_song node in the IR; the bytes still unroll the whole sequencer
      # (counter + per-frame note triggers), so keep those inner add/if/set calls
      # from recording their own nodes.
      record(Build.play_song(name))
      without_recording do
        # Internal frame counter variable for this song
        counter_var = :"_music_frame_#{name}"
        ensure_var(counter_var)

        # Increment frame counter each call
        add counter_var, 1

        # Emit note triggers: if counter == frame_offset, trigger channel 1
        ctx.events.each do |frame_offset, freq_hz|
          if_eq counter_var, frame_offset do
            emit_ch1_note(freq_hz, ctx.duty, ctx.volume)
          end
        end

        # Loop: if counter >= total_frames, reset to 0
        if_ge counter_var, ctx.total_frames do
          set counter_var, 0
        end
      end
    end

    # Silence the music channel (channel 1).
    # Call this when transitioning to a scene that shouldn't have music.
    def stop_music
      record(Build.stop_music)
      Sound::Registers.stop_music.each { |address, value| emit_write_reg16(address, value) }
    end

    # --- Text ---

    # Draw a text string at (x, y) using the built-in 5x7 bitmap font.
    # Each character is 6px wide (5px glyph + 1px gap), 7px tall.
    # All text is uppercased. Unsupported characters are skipped.
    #
    # Since positions are known at build time, this unrolls to direct
    # pixel writes — no runtime font lookup needed.
    #
    # @param text [String] text to render
    # @param x [Integer] left edge
    # @param y [Integer] top edge
    # @param c [Symbol, String, Integer] text color
    def draw_text(text, x, y, c)
      record(Build.draw_text(text, x, y, c))
      color_val = Color.resolve(c)

      # Load color once into r0
      @rom.emit(ASM.load_immediate(0, color_val))

      Font.each_pixel(text) do |dx, dy|
        px = x + dx
        py = y + dy
        next if px < 0 || px >= SCREEN_WIDTH || py < 0 || py >= SCREEN_HEIGHT

        vram_addr = VRAM_START + (py * SCREEN_WIDTH + px) * 2
        @rom.emit(ASM.load_immediate(1, vram_addr))
        @rom.emit(ASM.store_halfword(0, 1))
      end
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

    # Emit ARM instructions to write a 16-bit value to an I/O or memory address.
    # Uses r0 for value, r1 for address.
    def emit_write_reg16(address, value)
      @rom.emit(ASM.load_immediate(0, value))
      @rom.emit(ASM.load_immediate(1, address))
      @rom.emit(ASM.store_halfword(0, 1))
    end

    # Emit ARM instructions to write a 32-bit immediate to a memory address.
    # Uses r0 for value, r1 for address.
    def emit_store_immediate(address, value)
      @rom.emit(ASM.load_immediate(0, value))
      @rom.emit(ASM.load_immediate(1, address))
      @rom.emit(ASM.str(0, 1))
    end

    # Emit a conditional block: compare var against operand, skip block if condition is false.
    # @param cond [Symbol] condition (:eq, :ne, :gt, :lt, :ge, :le)
    # @param var_name [Symbol] variable to compare
    # @param operand [Integer, Symbol] immediate value or variable name to compare against
    def emit_conditional(cond, var_name, operand, &block)
      inverse = INVERSE_COND.fetch(cond)
      condition = Build.binop(COND_TO_OP.fetch(cond), Build.var_ref(var_name), Build.wrap(operand))

      # Record an `if` node and gather the block's statements into it, while the
      # bytes emit the usual compare-and-skip-over-the-block sequence.
      push_container(Build.if_(condition)) do
        # Load variable into r10
        ensure_var(var_name)
        load_var_into(10, var_name)

        # Compare: CMP r10, #imm or CMP r10, rm
        if operand.is_a?(Symbol)
          # Variable vs variable
          ensure_var(operand)
          load_var_into(11, operand)
          @rom.emit(ASM.cmp_reg(10, 11))
        else
          # Variable vs immediate
          encoding = ASM.encode_rotated_immediate(operand)
          if encoding
            @rom.emit(ASM.cmp_imm(10, operand))
          else
            # Large immediate: load into r11 and compare registers
            @rom.emit(ASM.load_immediate(11, operand))
            @rom.emit(ASM.cmp_reg(10, 11))
          end
        end

        # Branch over block if condition is NOT met (inverse condition)
        branch_pos = @rom.code_offset
        @rom.emit(ASM.branch_cond(inverse, 0))  # placeholder

        instance_eval(&block)

        # Patch branch to skip past the block
        block_end = @rom.code_offset
        skip_words = (block_end - branch_pos) / 4
        @rom.patch(branch_pos, ASM.branch_cond(inverse, skip_words))
      end
    end

    # Emit a DMA3 fill: writes a fixed 32-bit word to a destination address.
    # Uses DMA_ENABLE | DMA_32BIT with source fixed (same word repeated).
    # r0 = source word, r1 = address scratch, stored to a temp IWRAM location.
    #
    # @param dest [Integer] destination address (e.g. VRAM_START)
    # @param word [Integer] 32-bit value to fill with
    # @param count [Integer] number of 32-bit transfers
    def dma3_fill(dest, word, count)
      # Store the fill word to a known IWRAM scratch location (we use a dedicated var)
      ensure_var(:_dma_scratch)
      scratch_addr = @variables[:_dma_scratch][:address]

      # Write the fill word to scratch
      @rom.emit(ASM.load_immediate(0, word))
      @rom.emit(ASM.load_immediate(1, scratch_addr))
      @rom.emit(ASM.str(0, 1))

      # DMA3SAD = scratch address (source — fixed, same word repeated)
      @rom.emit(ASM.load_immediate(0, scratch_addr))
      @rom.emit(ASM.load_immediate(1, REG_DMA3SAD))
      @rom.emit(ASM.str(0, 1))

      # DMA3DAD = destination
      @rom.emit(ASM.load_immediate(0, dest))
      @rom.emit(ASM.load_immediate(1, REG_DMA3DAD))
      @rom.emit(ASM.str(0, 1))

      # DMA3CNT = count | DMA_ENABLE | DMA_32BIT | SRC_FIXED
      # DMA3CNT is 32 bits: low 16 = word count, high 16 = control flags.
      # Source addr control (CNT_H bits 7-8): 10 = fixed → (2 << 7) << 16 = 0x01000000
      dma_src_fixed = 0x01000000
      dma_ctrl = count | DMA_ENABLE | DMA_32BIT | dma_src_fixed
      @rom.emit(ASM.load_immediate(0, dma_ctrl))
      @rom.emit(ASM.load_immediate(1, REG_DMA3CNT))
      @rom.emit(ASM.str(0, 1))
    end

    # Emit channel 1 note trigger (used by play_song).
    # freq_hz=0 means rest (silence the channel).
    def emit_ch1_note(freq_hz, duty, volume)
      Sound::Registers.channel1_note(frequency: freq_hz, duty: duty, volume: volume).each do |address, value|
        emit_write_reg16(address, value)
      end
    end

    # Load a variable into a register (internal, uses r12 as address scratch).
    def load_var_into(reg, name)
      addr = var_address!(name)
      @rom.emit(ASM.load_immediate(12, addr))
      @rom.emit(ASM.ldr(reg, 12))
    end

    # Store a register into a variable (internal, uses r12 as address scratch).
    def store_var_from(reg, name)
      addr = var_address!(name)
      @rom.emit(ASM.load_immediate(12, addr))
      @rom.emit(ASM.str(reg, 12))
    end

    # Look up a variable's IWRAM address, raising if not declared.
    def var_address!(name)
      entry = @variables[name]
      raise ArgumentError, "unknown variable :#{name}. Use `set :#{name}, value` first." unless entry
      entry[:address]
    end

    # Allocate a variable if it doesn't exist yet.
    def ensure_var(name)
      return if @variables.key?(name)

      addr = @next_var_addr
      @next_var_addr += 4
      @variables[name] = { address: addr, initial: 0 }
    end

    # --- IR tree construction (built in parallel with the ARM bytes) ---

    # Attach a freshly built IR node to the open container and return it. A no-op
    # while recording is suppressed (see #without_recording).
    def record(node)
      @container_stack.last.add_child(node) unless @suppress_record
      node
    end

    # Build a container node, attach it, and keep it open while the block runs so
    # nested statements land inside it — then close it. The block-taking control
    # methods use this as they migrate.
    def push_container(node)
      record(node)
      @container_stack.push(node)
      yield
    ensure
      @container_stack.pop
    end

    # Run a block without recording IR — for a composite method (e.g. clamp) that
    # records its own single node but still emits its expansion through other,
    # recording DSL methods in bytes.
    def without_recording
      previous = @suppress_record
      @suppress_record = true
      yield
    ensure
      @suppress_record = previous
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
