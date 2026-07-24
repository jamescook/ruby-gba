# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      # Lowers an IR program to a Game Boy Advance ROM.
      #
      # This is the GBA backend: it walks the IR tree and emits ARM7TDMI machine
      # code — the CPU the GBA runs — targeting the console's actual hardware: its
      # memory map (IWRAM for variables, VRAM for the screen), its memory-mapped
      # I/O registers (the display-control register, the DMA registers, the key
      # register), and its cartridge layout. The output is a ROM that boots on a
      # GBA (or an emulator); it would mean nothing to any other ARM device.
      #
      # How the "two passes" work. Emitting jumps is the hard part: a branch to a
      # block further down the program can't know its target address until that
      # block has been emitted (a *forward reference*). Rather than compute jump
      # distances by hand, we do it in two passes:
      #
      #   1. Walk the tree once, emitting real machine code into a buffer. Every
      #      point a jump might target gets a named *label* recorded at its byte
      #      position, and every jump is written as a 4-byte placeholder that
      #      remembers which label it wants.
      #   2. Resolve: now that every label's position is known, rewrite each
      #      placeholder as a real branch to its label.
      #
      # This works cleanly because only branches depend on addresses, and a branch
      # is always 4 bytes no matter how far it jumps — so emitting the placeholder
      # never changes any later position. Everything else (loading a number,
      # writing a pixel) has a fixed, value-determined size we emit immediately.
      #
      # Register conventions (no allocator yet — that's a later refinement). Between
      # statements the only live state lives in memory (variables in IWRAM, pixels
      # in VRAM); registers are all scratch, so each statement is free to reuse
      # them:
      #   * r0  — the value / expression accumulator
      #   * r1  — a temporary, and the address register for I/O writes
      #   * r2, r3 — scratch for computing a pixel's VRAM address at run time
      #   * r12 — address scratch when loading/storing a variable
      #   * the CPU stack holds intermediate values inside a nested expression
      class GBA
        include RubyGBA::Constants

        class LoweringError < StandardError; end

        # Friendly display-mode names → the display-control register value. Only
        # the direct-color bitmap mode is lowered here; other modes are their own
        # work. (This mirrors the DSL's names.)
        DISPLAY_MODES = { bitmap: MODE_3 | BG2_ENABLE }.freeze

        # Double-buffered (Mode 4) hardware layout. Mode 4 gives the program TWO
        # full screens — "pages" — in video memory, 0xA000 bytes apart. One is shown
        # on the TV while the program draws into the other, then a flip swaps them at
        # a frame boundary; because the TV never reads a half-drawn page, the picture
        # can't tear. DISPCNT bit 4 selects which page is shown.
        PAGE0 = VRAM_START            # the first framebuffer page (0x06000000)
        PAGE1 = VRAM_START + 0xA000   # the second (0x0600A000)
        PAGE_PAIR_SUM = PAGE0 + PAGE1 # flip trick: the other page is (this sum − current)
        DISPCNT_FRAME_SELECT = 0x0010 # the DISPCNT bit that chooses which page shows

        # A reserved data-blob name for the color table Mode 4 uploads, and the two
        # hidden variables that track the double-buffer state at run time: the live
        # DISPCNT value (so a flip toggles a single bit) and the address of the page
        # currently being drawn into.
        PALETTE_BLOB = :__palette
        DISPCNT_STATE = :__dispcnt
        BACKBUF = :__backbuf

        # When scenes use different display modes, the framework switches the
        # hardware as each scene takes over. A hidden variable holds which mode is
        # live, so a scene only touches the display registers when the mode actually
        # changes (a transition), not every frame. Direct = single-buffered Mode 3,
        # Buffered = double-buffered Mode 4.
        MODE_STATE = :__mode
        MODE_DIRECT = 0
        MODE_BUFFERED = 1

        # This backend's mapping of the shared button vocabulary (IR::Buttons) to
        # hardware: each name → its bit in the key register. The key register is
        # active-low, so a 0 bit means the button is down.
        BUTTON_BIT = {
          a: KEY_A, b: KEY_B, select: KEY_SELECT, start: KEY_START,
          right: KEY_RIGHT, left: KEY_LEFT, up: KEY_UP, down: KEY_DOWN,
          r: KEY_R, l: KEY_L,
        }.freeze

        # Hidden variables for edge-detected input. Each holds the set of buttons
        # that were down as of a frame — this frame and the previous one — stored
        # active-high (a 1 bit means the button is down). `pressed` is "down now,
        # up last frame" = CUR_KEYS AND NOT PREV_KEYS. They're snapshotted once per
        # vblank so every check within a frame compares against the same previous
        # frame, exactly like the interpreter does.
        CUR_KEYS = :__cur_keys
        PREV_KEYS = :__prev_keys
        KEY_MASK = 0x3FF # the ten button bits

        ACC = 0   # accumulator register
        TMP = 1   # temporary / I/O address register
        ADDR = 12 # variable address scratch

        # Comparison operator → the ARM condition that is TRUE for it and the
        # condition under which it is FALSE (used to skip setting the result to 1).
        COMPARISONS = {
          :>  => %i[gt le], :<  => %i[lt ge],
          :>= => %i[ge lt], :<= => %i[le gt],
          :== => %i[eq ne], :!= => %i[ne eq],
        }.freeze

        attr_reader :code, :labels, :func_ranges

        def initialize
          @code = +"".b          # emitted machine code; byte 0 is where execution starts
          @labels = {}           # label name -> byte offset within @code
          @fixups = []           # branch placeholders to resolve once labels are known
          @vars = {}             # variable name -> IWRAM address
          @next_var = IWRAM_START
          @funcs = {}            # func name -> its IR node (emitted after the main body)
          @func_ranges = {}      # func name -> byte span in @code (for dump_func)
          @defined_sounds = {}   # name -> musical params (from define_sound)
          @songs = {}            # name -> :song node (from song)
          @data_blobs = {}       # name -> bytes (embedded data, appended after code)
          @data_positions = {}   # name -> byte offset of its blob within @code
          @bitmaps = {}          # name -> { width:, height: } (a blob that has a shape)
          @lists = {}            # name -> { capacity:, mask:, base: } (a list's IWRAM layout)
          @label_seq = 0
          @uses_pressed = false  # whether the program reads edge-detected input
          @palette = nil         # the color table, built once when any scene is buffered
          @modes = nil           # IR::Modes: which display mode each scene resolves to
          @any_buffered = false  # does any scene use double buffering?
          @default_mode = :direct # the boot display mode (from the top-level `display`)
          @func_mode = {}        # func name -> :direct | :buffered (resolved from the call graph)
          @scene_funcs = []      # funcs entered per frame, which switch the mode on entry
          @lower_mode = :direct  # the mode draws currently lower in (set per func)
        end

        # Lower a program to finished GBA machine code: run the emit pass and
        # resolve the jumps, then return the raw code bytes. Packaging them into a
        # cartridge — header, entry branch, checksum, padding — is ROM.assemble's
        # job; this method knows only how to compile the IR, not how a ROM is laid
        # out.
        def lower(program)
          collect_definitions(program)
          resolve_modes(program)
          prepare_palette(program) if @any_buffered
          @uses_pressed = program.walk.any? { |node| node.kind == :pressed }
          emit_input_init if @uses_pressed
          emit_boot_display if @any_buffered # set the boot mode + upload the palette once
          @lower_mode = @default_mode
          program.children.each { |stmt| emit_statement(stmt) }
          emit_functions
          emit_data_region
          resolve_fixups
          @code
        end

        # Work out which display mode each scene draws in. A program that never uses
        # double buffering is left entirely alone (the direct-color path below is
        # unchanged). When some scene IS buffered, each func's mode comes from
        # IR::Modes — the shared, target-agnostic resolution that follows the call
        # graph from the game's entry points. A drawing helper reached in two
        # different modes can't be lowered both ways; Modes flags that, and we
        # surface it as a lowering error.
        def resolve_modes(program)
          @modes = IR::Modes.resolve(program)
          @default_mode = @modes.default_mode
          @func_mode = @modes.func_mode
          @scene_funcs = @modes.scene_funcs
          @any_buffered = @modes.any_buffered?
        rescue IR::Modes::Conflict => e
          raise LoweringError, e.message
        end

        private

        # Register every definition in the tree up front — funcs, named sound
        # effects, and songs — so a later reference can reach one defined earlier
        # or later (a forward reference). Func bodies are emitted after the main
        # code, never inline, so the main flow doesn't run into them; sounds and
        # songs are pure data with nothing to emit on their own.
        def collect_definitions(program)
          program.walk do |node|
            case node.kind
            when :func
              @funcs[node[:name]] = node
            when :define_sound
              @defined_sounds[node[:name]] = {
                frequency: node[:frequency], duty: node[:duty],
                decay: node[:decay], volume: node[:volume]
              }
            when :song
              @songs[node[:name]] = node
            when :data
              @data_blobs[node[:name]] = node[:bytes]
            when :bitmap
              @bitmaps[node[:name]] = { width: node[:width], height: node[:height],
                                        transparent: node[:transparent], pixels: node[:pixels] }
              # An opaque bitmap streams from ROM via DMA, so embed its pixels. A
              # transparent one is drawn pixel-by-pixel with its colors baked into
              # the code (letting transparent pixels be skipped), so it needs no
              # ROM copy.
              @data_blobs[node[:name]] = node[:pixels] unless node[:transparent]
            when :list_new
              # Reserve the list's IWRAM storage once, up front, so every op that
              # touches it (anywhere in the tree, including funcs emitted later)
              # already knows its base address and capacity. list_new *executing*
              # only resets it to empty; the storage itself is allocated here.
              register_list(node[:name], node[:capacity])
            end
          end
        end

        # Build the double-buffer color table and stash it as a ROM blob to be
        # uploaded at startup. Mode 4's screen stores a small index per pixel that
        # picks a color out of this table, so the table has to exist before anything
        # is drawn. Only the buffered scenes feed it — a direct-color scene stores
        # full colors per pixel and needs no slot — so its colors can't crowd the
        # 256-entry table (see IR::Palette::Overflow for the friendly limit error).
        def prepare_palette(program)
          @palette = IR::Palette.build(program, scopes: @modes.buffered_scopes)
          @data_blobs[PALETTE_BLOB] = @palette.entries.pack("v*") # 15-bit entries, little-endian
        end

        # --- emit helpers -------------------------------------------------------

        def emit(bytes)
          @code << bytes
        end

        # The current byte position — the program counter of the emit pass.
        def pos
          @code.bytesize
        end

        def place_label(name)
          @labels[name] = pos
        end

        def gensym
          "L#{@label_seq += 1}"
        end

        # Emit a 4-byte branch placeholder now and remember to resolve it against
        # +target+ later. kind is :b (unconditional), :bcond (conditional), or
        # :bl (call). The real branch is written in resolve_fixups.
        def emit_branch(kind, target, cond: nil)
          @fixups << { pos: pos, kind: kind, cond: cond, target: target }
          emit(ASM.nop)
        end

        # Second pass: every label and data-blob position is known now, so patch
        # each placeholder — a branch to a label, or a load of a blob's address.
        def resolve_fixups
          @fixups.each do |fix|
            fix[:kind] == :data_addr ? resolve_data_address(fix) : resolve_branch(fix)
          end
        end

        # Rewrite a branch placeholder as a real branch. The word offset is
        # (target - here)/4; ASM folds in the pipeline adjustment.
        def resolve_branch(fix)
          target = @labels.fetch(fix[:target]) do
            raise LoweringError, "unresolved jump to #{fix[:target].inspect}"
          end
          word_offset = (target - fix[:pos]) / 4
          encoded =
            case fix[:kind]
            when :b then ASM.branch(word_offset)
            when :bcond then ASM.branch_cond(fix[:cond], word_offset)
            when :bl then ASM.branch_link(word_offset)
            end
          @code[fix[:pos], 4] = encoded
        end

        # Patch a data-address load with the blob's run-time address. The blob
        # sits at +position+ within @code, and ROM.assemble drops @code into the
        # cartridge right after the header, so its address is the cartridge base
        # plus the header plus that position.
        def resolve_data_address(fix)
          position = @data_positions.fetch(fix[:target]) do
            raise LoweringError, "reference to undefined data #{fix[:target].inspect}"
          end
          address = ROM_START + RubyGBA::ROM::ENTRY_OFFSET + position
          @code[fix[:pos], 16] = ASM.load_immediate_fixed(fix[:reg], address)
        end

        # Lay the embedded blobs out after all the code, remembering where each
        # landed so resolve_data_address can turn a name into an address. Data
        # after the code means the main flow never runs into it.
        def emit_data_region
          @data_blobs.each do |name, bytes|
            @data_positions[name] = pos
            emit(bytes)
          end
        end

        # Load the run-time address of a named blob into +reg+. The address isn't
        # known until the data region is placed, so emit a fixed-size placeholder
        # and record a fixup to patch in the real address. Consumers (a blit's DMA
        # source, a sequencer's cursor) build on this.
        def emit_load_data_address(reg, name)
          @fixups << { pos: pos, kind: :data_addr, reg: reg, target: name }
          emit(ASM.load_immediate_fixed(reg, 0))
        end

        # --- statements ---------------------------------------------------------

        def emit_statement(node)
          case node.kind
          when :func then nil # emitted separately, after the main body
          when :set then emit_set(node)
          when :add then emit_accumulate(node, :add_reg)
          when :sub then emit_accumulate(node, :sub_reg)
          when :copy then emit_copy(node)
          when :negate then emit_negate(node)
          when :abs then emit_conditional_negate(node[:var], skip_when: :ge)
          when :negate_abs then emit_conditional_negate(node[:var], skip_when: :le)
          when :clamp then emit_clamp(node)
          when :if then emit_if(node)
          when :loop then emit_loop(node)
          when :repeat then emit_repeat(node)
          when :every then emit_every(node)
          when :after then emit_after(node)
          when :list_new then emit_list_new(node)
          when :list_push then emit_list_push(node)
          when :list_drop then emit_list_drop(node)
          when :list_set then emit_list_set(node)
          when :call then emit_branch(:bl, func_label(node[:target]))
          when :case then emit_case(node)
          when :raw then emit(node[:bytes]) # escape hatch: pre-assembled bytes, verbatim
          when :halt then emit(ASM.loop_forever)
          when :wait_vblank then emit_wait_vblank
          when :display then emit_display(node)
          when :pixel then emit_pixel(node)
          when :fill_rect then emit_fill_rect(node)
          when :clear_screen then emit_clear_screen(node)
          when :dma_fill_rect then emit_dma_fill_rect(node)
          when :draw_rect_at then emit_draw_rect_at(node)
          when :draw_text then emit_draw_text(node)
          when :draw_digit then emit_draw_digit(node)
          when :blit then emit_blit(node)
          when :enable_sound then emit_enable_sound
          when :define_sound, :song, :data, :bitmap then nil # definitions: collected, nothing to emit
          when :beep then emit_beep(node)
          when :play_song then emit_play_song(node)
          when :stop_music then emit_stop_music
          else
            raise LoweringError, "the GBA backend cannot lower #{node.kind.inspect} yet"
          end
        end

        def emit_set(node)
          eval_value(node[:value])
          store_var(ACC, node[:var])
        end

        # add/sub: new value = var (op) operand. Evaluate the operand into the
        # accumulator, load the variable alongside it, combine, store back.
        def emit_accumulate(node, op)
          eval_value(node[:operand])       # r0 = operand
          load_var(TMP, node[:var])        # r1 = current value
          emit(ASM.send(op, ACC, TMP, ACC)) # r0 = r1 (op) r0
          store_var(ACC, node[:var])
        end

        def emit_copy(node)
          load_var(ACC, node[:src])
          store_var(ACC, node[:dest])
        end

        def emit_negate(node)
          load_var(ACC, node[:var])
          emit(ASM.rsb_imm(ACC, ACC, 0))   # r0 = 0 - r0
          store_var(ACC, node[:var])
        end

        # Negate a variable only when it sits on one side of zero — the shared
        # shape of abs (|v|: negate when < 0, so skip when >= 0) and negate_abs
        # (-|v|: negate when > 0, so skip when <= 0). Compare to zero, jump over
        # the negate when the value is already on the wanted side.
        def emit_conditional_negate(var, skip_when:)
          load_var(ACC, var)
          emit(ASM.cmp_imm(ACC, 0))
          done = gensym
          emit_branch(:bcond, done, cond: skip_when)
          emit(ASM.rsb_imm(ACC, ACC, 0))
          place_label(done)
          store_var(ACC, var)
        end

        # Clamp a variable into [min, max] with two compare-and-maybe-replace steps.
        def emit_clamp(node)
          load_var(ACC, node[:var])

          below = gensym
          emit(ASM.load_immediate(TMP, node[:min]))
          emit(ASM.cmp_reg(ACC, TMP))                 # var - min
          emit_branch(:bcond, below, cond: :ge)       # var >= min? leave it
          emit(ASM.mov_reg(ACC, TMP))                 # else clamp up to min
          place_label(below)

          above = gensym
          emit(ASM.load_immediate(TMP, node[:max]))
          emit(ASM.cmp_reg(ACC, TMP))                 # var - max
          emit_branch(:bcond, above, cond: :le)       # var <= max? leave it
          emit(ASM.mov_reg(ACC, TMP))                 # else clamp down to max
          place_label(above)

          store_var(ACC, node[:var])
        end

        # if: run the then-body when the condition is non-zero. With no else, a
        # false condition jumps past the body. With an else, a false condition
        # jumps to the else-body, and the then-body jumps over it to the end.
        def emit_if(node)
          eval_value(node[:cond])
          emit(ASM.cmp_imm(ACC, 0))
          else_node = node[:else]

          if else_node
            else_label = gensym
            end_label = gensym
            emit_branch(:bcond, else_label, cond: :eq) # false => run the else
            node.children.each { |stmt| emit_statement(stmt) }
            emit_branch(:b, end_label)                 # then done => skip the else
            place_label(else_label)
            else_node.children.each { |stmt| emit_statement(stmt) }
            place_label(end_label)
          else
            skip = gensym
            emit_branch(:bcond, skip, cond: :eq) # zero => condition false => skip
            node.children.each { |stmt| emit_statement(stmt) }
            place_label(skip)
          end
        end

        # loop: an endless repeat of the body — a jump back to the top. A `halt`
        # (or the step budget, on the interpreter) is what ends it.
        def emit_loop(node)
          top = gensym
          place_label(top)
          node.children.each { |stmt| emit_statement(stmt) }
          emit_branch(:b, top)
        end

        # repeat: a counted loop. The count is evaluated once into a hidden limit
        # variable (matching the interpreter, which captures the bound up front),
        # a hidden counter runs 0..count-1, and the body runs each pass. Counter
        # and limit live in memory, so the body is free to clobber registers.
        def emit_repeat(node)
          index = node[:index]
          limit = :"#{index}__limit"

          eval_value(node[:count])        # r0 = count
          store_var(ACC, limit)           # limit = count (once)
          emit(ASM.load_immediate(ACC, 0))
          store_var(ACC, index)           # counter = 0

          top = gensym
          done = gensym
          place_label(top)
          load_var(ACC, index)            # r0 = counter
          load_var(TMP, limit)            # r1 = limit
          emit(ASM.cmp_reg(ACC, TMP))     # counter - limit
          emit_branch(:bcond, done, cond: :ge) # counter >= limit => finished

          node.children.each { |stmt| emit_statement(stmt) }

          load_var(ACC, index)
          emit(ASM.add_imm(ACC, ACC, 1))  # counter += 1
          store_var(ACC, index)
          emit_branch(:b, top)
          place_label(done)
        end

        # every: run the body once every `period` frames. Tick the hidden frame
        # counter, and when it reaches the period, reset it and run the body. Built
        # as a small sub-tree and emitted through the shared statement emitters
        # (rather than hand-written instructions), so it reuses the tested add/if
        # lowering.
        def emit_every(node)
          counter = node[:counter]
          reached = Build.binop(:>=, Build.var_ref(counter), Build.int(node[:period]))
          gate = Build.if_(reached, Build.set(counter, Build.int(0)), *node.children)
          emit_statement(Build.add(counter, 1))
          emit_statement(gate)
        end

        # after: run the body exactly once, `frames` frames in. Count up only until
        # the target — so the counter never overflows or fires twice — and run the
        # body on the one frame it lands on. Built as a sub-tree emitted through the
        # shared statement emitters, reusing the tested add/if lowering.
        def emit_after(node)
          counter = node[:counter]
          frames = node[:frames]
          lands = Build.if_(Build.binop(:==, Build.var_ref(counter), Build.int(frames)), *node.children)
          not_yet = Build.if_(Build.binop(:<, Build.var_ref(counter), Build.int(frames)),
                              Build.add(counter, 1), lands)
          emit_statement(not_yet)
        end

        # --- lists ---------------------------------------------------------------
        #
        # A list is stored as a ring buffer in IWRAM: a fixed block of `capacity`
        # 4-byte slots, plus two hidden variables — `head` (the index of the oldest
        # item) and `length` (how many items are live). The item logically at
        # position i sits in the physical slot (head + i) & mask, where mask is
        # capacity-1. Because capacity is a power of two, that wrap is a single
        # bitwise AND — no division — and because the AND confines every access to
        # the list's own block, a bad index can read a stale slot but can never
        # reach a neighbouring variable. This mirrors the interpreter's list exactly
        # (same items readable, same length, same overflow point); the interpreter's
        # friendly errors catch logic bugs in testing, and here the hardware just
        # stays bounded.

        # Reserve a list's IWRAM layout: the slot block, then the head and length
        # variables. Called once per name during the definitions pass; a name
        # created twice with different capacities is a contradiction.
        def register_list(name, capacity)
          if (existing = @lists[name])
            return if existing[:capacity] == capacity

            raise LoweringError,
                  "list #{name.inspect} is created with two different capacities " \
                  "(#{existing[:capacity]} and #{capacity})"
          end

          base = @next_var
          @next_var += capacity * 4 # the ring's slots
          var_addr(head_var(name))  # head and length, allocated alongside
          var_addr(length_var(name))
          @lists[name] = { capacity: capacity, mask: capacity - 1, base: base }
        end

        # A list's layout, or a friendly error if the program never created it.
        def list_info(name)
          @lists[name] ||
            raise(LoweringError,
                  "list #{name.inspect} was used before it was created — " \
                  "a `list #{name.inspect}, capacity: N` must run first")
        end

        def head_var(name)
          :"#{name}__head"
        end

        def length_var(name)
          :"#{name}__len"
        end

        # list_new: reset the list to empty. Its storage is already reserved (see
        # register_list); this just zeroes head and length. The slot contents are
        # left as-is — nothing reads them until a push makes them live.
        def emit_list_new(node)
          list_info(node[:name])
          emit(ASM.load_immediate(ACC, 0))
          store_var(ACC, head_var(node[:name]))
          store_var(ACC, length_var(node[:name]))
        end

        # list_push: append at the tail — slot (head + length) & mask — then grow
        # length by one. If the list is already full the push is dropped rather than
        # overwriting the oldest item (hardware has no way to raise, so it stays
        # safe and quiet; the interpreter is what flags the overflow in testing).
        def emit_list_push(node)
          info = list_info(node[:name])
          length = length_var(node[:name])

          load_var(ACC, length)                        # r0 = length (the tail offset)
          emit(ASM.load_immediate(TMP, info[:capacity]))
          emit(ASM.cmp_reg(ACC, TMP))                  # length - capacity
          skip = gensym
          emit_branch(:bcond, skip, cond: :ge)         # full => drop the push

          emit_slot_address(info, node[:name])         # r12 = &slot[(head+length)&mask]
          emit(ASM.push(ADDR))                         # hold the address across the value eval
          eval_value(node[:value])                     # r0 = value
          emit(ASM.pop(TMP))                           # r1 = address
          emit(ASM.str(ACC, TMP))                      # slot = value

          load_var(ACC, length)                        # length += 1
          emit(ASM.add_imm(ACC, ACC, 1))
          store_var(ACC, length)
          place_label(skip)
        end

        # list_drop: remove one item. A shift (:front) advances head past the oldest
        # item; a pop (:back) just forgets the newest. Either way length shrinks by
        # one. An empty list is left untouched (length never goes negative).
        def emit_list_drop(node)
          info = list_info(node[:name])
          head = head_var(node[:name])
          length = length_var(node[:name])

          load_var(ACC, length)
          emit(ASM.cmp_imm(ACC, 0))
          skip = gensym
          emit_branch(:bcond, skip, cond: :eq)         # empty => nothing to drop

          if node[:from] == :front
            load_var(ACC, head)                        # head = (head + 1) & mask
            emit(ASM.add_imm(ACC, ACC, 1))
            emit_and_const(ACC, ACC, info[:mask], TMP)
            store_var(ACC, head)
          end

          load_var(ACC, length)                        # length -= 1
          emit(ASM.sub_imm(ACC, ACC, 1))
          store_var(ACC, length)
          place_label(skip)
        end

        # list_set: overwrite the item at an index. The masked address confines the
        # write to the list's own slots, so an out-of-range index scribbles a stale
        # slot at worst, never a neighbouring variable.
        def emit_list_set(node)
          info = list_info(node[:name])

          eval_value(node[:index])                     # r0 = index
          emit_slot_address(info, node[:name])         # r12 = &slot[(head+index)&mask]
          emit(ASM.push(ADDR))
          eval_value(node[:value])                     # r0 = value
          emit(ASM.pop(TMP))                           # r1 = address
          emit(ASM.str(ACC, TMP))                      # slot = value
        end

        # list_get: read the item at an index into the accumulator (a value).
        def eval_list_get(node)
          info = list_info(node[:name])
          eval_value(node[:index])                     # r0 = index
          emit_slot_address(info, node[:name])         # r12 = &slot[(head+index)&mask]
          emit(ASM.ldr(ACC, ADDR))                     # r0 = slot
        end

        # list_len: read the length variable into the accumulator (a value).
        def eval_list_len(node)
          list_info(node[:name])
          load_var(ACC, length_var(node[:name]))
        end

        # Turn an offset-from-head (already in r0 — an index, or length for a push)
        # into the physical slot address in r12: base + ((head + offset) & mask)*4.
        # Clobbers r0/r1; leaves the address in ADDR (r12), ready for ldr/str.
        def emit_slot_address(info, name)
          load_var(TMP, head_var(name))                # r1 = head
          emit(ASM.add_reg(ACC, TMP, ACC))             # r0 = head + offset
          emit_and_const(ACC, ACC, info[:mask], TMP)   # r0 = slot (ring-wrapped)
          emit(ASM.lsl_imm(ACC, ACC, 2))               # r0 = slot * 4 bytes
          emit(ASM.load_immediate(TMP, info[:base]))   # r1 = base address
          emit(ASM.add_reg(ADDR, TMP, ACC))            # r12 = base + slot*4
        end

        # Func bodies live after the main code. A leading endless loop guards
        # against the main flow running off its end into the first body. Each func
        # saves the return address and restores it as the program counter.
        def emit_functions
          return if @funcs.empty?

          emit(ASM.loop_forever) # fall-through guard
          @funcs.each do |name, fnode|
            start = pos
            place_label(func_label(name))
            emit(ASM.push(14))                          # push {lr}
            # Draws in this func lower in its resolved mode; a scene (a per-frame
            # entry point) also switches the hardware to that mode as it takes over.
            @lower_mode = @func_mode.fetch(name, @default_mode)
            emit_scene_preamble(name) if @any_buffered && @scene_funcs.include?(name)
            fnode.children.each { |stmt| emit_statement(stmt) }
            emit(ASM.pop(15))                           # pop {pc}  (return)
            @func_ranges[name] = (start...pos)          # byte span, for dump_func
          end
        end

        def func_label(name)
          "func_#{name}"
        end

        # Multi-way dispatch lowers to one "if the variable equals this value, call
        # that scene" per clause — reusing the ordinary if/compare/call path. Each
        # comparison reloads the variable from memory itself, so a scene call is free
        # to clobber every register without disturbing the dispatch.
        def emit_case(node)
          node[:clauses].each do |value, target|
            test = Build.binop(:==, Build.var_ref(node[:var]), Build.int(value))
            emit_statement(Build.if_(test, Build.call(target)))
          end
        end

        # --- hardware / drawing -------------------------------------------------

        # Turn the screen on by writing the chosen mode to the display-control
        # register. Until this runs the screen stays black.
        #
        # In a program that uses double buffering, the display mode is managed for
        # the whole program by the boot setup and each scene's mode-switch preamble,
        # so a `display` node is only a build-time declaration of a scene's mode and
        # emits nothing here. Otherwise it's the plain one-time register write.
        def emit_display(node)
          return if @any_buffered

          mode = node[:mode]
          value = mode.is_a?(Integer) ? mode : DISPLAY_MODES.fetch(mode) do
            raise LoweringError, "the GBA backend cannot lower display mode #{mode.inspect} yet"
          end
          write_reg16(REG_DISPCNT, value)
        end

        # One-time boot for a program that uses double buffering: upload the color
        # table (palette memory keeps it across mode switches) and put the hardware
        # in the default scene's mode. Buffered starts by showing page 0 and drawing
        # into page 1; direct is the plain Mode 3 write.
        def emit_boot_display
          upload_palette
          if @default_mode == :buffered
            enter_buffered_mode
          else
            enter_direct_mode
          end
        end

        # Switch the hardware into double-buffered (Mode 4): remember the live DISPCNT
        # so a flip is a cheap bit-toggle, draw into page 1 first, show page 0, and
        # record that buffered is now the live mode.
        def enter_buffered_mode
          base = MODE_4 | BG2_ENABLE
          store_word_immediate(base, var_addr(DISPCNT_STATE))
          store_word_immediate(PAGE1, var_addr(BACKBUF))
          write_reg16(REG_DISPCNT, base)
          store_word_immediate(MODE_BUFFERED, var_addr(MODE_STATE))
        end

        # Switch the hardware into direct-color (Mode 3) and record it as live.
        def enter_direct_mode
          write_reg16(REG_DISPCNT, MODE_3 | BG2_ENABLE)
          store_word_immediate(MODE_DIRECT, var_addr(MODE_STATE))
        end

        # Emitted at the top of each scene when a program mixes modes: switch the
        # hardware into this scene's mode, but only if it isn't already there (a
        # transition). Steady frames — the same scene running again — cost just the
        # compare, and a buffered scene's DISPCNT is left to the page flip.
        def emit_scene_preamble(name)
          want = @func_mode[name] == :buffered ? MODE_BUFFERED : MODE_DIRECT
          load_var(ACC, MODE_STATE)
          emit(ASM.cmp_imm(ACC, want))
          skip = gensym
          emit_branch(:bcond, skip, cond: :eq) # already in this mode? nothing to do
          @func_mode[name] == :buffered ? enter_buffered_mode : enter_direct_mode
          place_label(skip)
        end

        # Copy the color table from the cartridge into background palette memory —
        # one DMA of `size` 16-bit entries, source and destination both advancing.
        def upload_palette
          emit_load_data_address(ACC, PALETTE_BLOB)     # r0 = table address in the cartridge
          emit(ASM.load_immediate(TMP, REG_DMA3SAD))
          emit(ASM.str(ACC, TMP))                       # DMA source = the table
          store_word_immediate(BG_PALETTE, REG_DMA3DAD) # DMA destination = palette memory
          store_word_immediate(@palette.size | DMA_ENABLE, REG_DMA3CNT) # go: 16-bit, both increment
        end

        # At the vblank boundary, flip the pages — but only while a buffered scene is
        # live (a direct scene draws straight to the screen and has nothing to flip).
        # The runtime check costs a compare; the mode rarely changes.
        def emit_flip_if_buffered
          load_var(ACC, MODE_STATE)
          emit(ASM.cmp_imm(ACC, MODE_BUFFERED))
          skip = gensym
          emit_branch(:bcond, skip, cond: :ne)
          emit_flip
          place_label(skip)
        end

        # Present the page just drawn and start drawing the other one — the page
        # flip, run once per frame at the vblank boundary. Toggle the DISPCNT bit
        # that selects the shown page (so the finished page becomes visible), then
        # point the back buffer at the other page (its address is the pair's sum
        # minus the current one).
        def emit_flip
          load_var(ACC, DISPCNT_STATE)
          emit(ASM.load_immediate(TMP, DISPCNT_FRAME_SELECT))
          emit(ASM.eor_reg(ACC, ACC, TMP))            # flip the page-select bit
          store_var(ACC, DISPCNT_STATE)
          emit(ASM.load_immediate(TMP, REG_DISPCNT))
          emit(ASM.store_halfword(ACC, TMP))          # the finished page is now shown

          load_var(ACC, BACKBUF)
          emit(ASM.load_immediate(TMP, PAGE_PAIR_SUM))
          emit(ASM.sub_reg(ACC, TMP, ACC))            # the other page
          store_var(ACC, BACKBUF)
        end

        # Plot one pixel. With constant coordinates the VRAM address is known now,
        # so it's a single store. With a computed coordinate (e.g. a variable) the
        # address is built at run time from the evaluated x/y.
        def emit_pixel(node)
          return emit_pixel_buffered(node) if @lower_mode == :buffered

          color = Color.resolve(node[:color])
          xi = const_int(node[:x])
          yi = const_int(node[:y])

          if xi && yi
            return unless in_bounds?(xi, yi) # off-screen: clip, like the framebuffer

            write_reg16(VRAM_START + ((yi * SCREEN_WIDTH) + xi) * 2, color)
          else
            eval_value(node[:y])            # r0 = y
            emit(ASM.push(ACC))
            eval_value(node[:x])            # r0 = x
            emit(ASM.pop(TMP))              # r1 = y
            emit(ASM.load_immediate(2, SCREEN_WIDTH))
            emit(ASM.mul(3, TMP, 2))        # r3 = y * width
            emit(ASM.add_reg(3, 3, ACC))    # r3 = y*width + x
            emit(ASM.lsl_imm(3, 3, 1))      # r3 = offset * 2 bytes
            emit(ASM.load_immediate(2, VRAM_START))
            emit(ASM.add_reg(3, 2, 3))      # r3 = VRAM address
            emit(ASM.load_immediate(ACC, color))
            emit(ASM.store_halfword(ACC, 3))
          end
        end

        # Fill a rectangle of constant size. Load the color once, then write each
        # on-screen pixel (off-screen pixels are clipped).
        def emit_fill_rect(node)
          return emit_fill_rect_buffered(node) if @lower_mode == :buffered

          x, y, w, h = constant_ints!(node, :x, :y, :w, :h)
          color = Color.resolve(node[:color])
          emit(ASM.load_immediate(ACC, color))
          h.times do |dy|
            row = y + dy
            next unless (0...SCREEN_HEIGHT).cover?(row)

            w.times do |dx|
              col = x + dx
              next unless (0...SCREEN_WIDTH).cover?(col)

              emit(ASM.load_immediate(TMP, VRAM_START + ((row * SCREEN_WIDTH) + col) * 2))
              emit(ASM.store_halfword(ACC, TMP))
            end
          end
        end

        # Clear the whole screen with one DMA transfer: repeat a packed two-pixel
        # word across VRAM. The DMA engine copies far faster than a pixel loop.
        def emit_clear_screen(node)
          return emit_clear_screen_buffered(node) if @lower_mode == :buffered

          color = Color.resolve(node[:color])
          word = (color << 16) | color
          count = SCREEN_WIDTH * SCREEN_HEIGHT / 2
          scratch = var_addr(:_dma_scratch)

          store_word_immediate(word, scratch)                 # hold the fill word in IWRAM
          store_word_immediate(scratch, REG_DMA3SAD)          # source: the fixed word
          store_word_immediate(VRAM_START, REG_DMA3DAD)       # destination: the screen
          store_word_immediate(dma_fill_control(count), REG_DMA3CNT) # kick off the transfer
        end

        # A rectangle at a fixed position and size, filled fast with per-row DMA:
        # each row is one block transfer of a repeated two-pixel word. Rows off the
        # top/bottom of the screen are skipped.
        def emit_dma_fill_rect(node)
          return emit_fill_rect_buffered(node) if @lower_mode == :buffered

          x, y, w, h = constant_ints!(node, :x, :y, :w, :h)
          even_width!(w, :dma_fill_rect)
          scratch = hold_fill_word(node[:color])
          control = dma_fill_control(w / 2)

          h.times do |dy|
            row = y + dy
            next unless (0...SCREEN_HEIGHT).cover?(row)

            row_addr = VRAM_START + ((row * SCREEN_WIDTH) + x) * 2
            fire_dma_fill(scratch, row_addr, control)
          end
        end

        # A rectangle whose position is computed at run time (x/y may be
        # variables), its size a constant. Same per-row DMA fill as
        # dma_fill_rect, but each row's destination address is built from the
        # live x/y instead of known up front. r2/r3 hold x/y across the loop;
        # r4/r5 are address scratch. (No run-time bounds clip yet — the caller is
        # expected to keep it on-screen, as pong does by clamping.)
        def emit_draw_rect_at(node)
          return emit_draw_rect_at_buffered(node) if @lower_mode == :buffered

          w, h = constant_ints!(node, :w, :h)
          even_width!(w, :draw_rect_at)
          scratch = hold_fill_word(node[:color])
          control = dma_fill_control(w / 2)

          x_reg = 2
          y_reg = 3
          eval_value(node[:x])
          emit(ASM.mov_reg(x_reg, ACC))
          eval_value(node[:y])
          emit(ASM.mov_reg(y_reg, ACC))

          h.times do |dy|
            # r4 = VRAM_START + ((y + dy) * width + x) * 2
            if dy.zero?
              emit(ASM.mov_reg(4, y_reg))
            else
              emit(ASM.add_imm(4, y_reg, dy))
            end
            emit(ASM.load_immediate(5, SCREEN_WIDTH))
            emit(ASM.mul(4, 5, 4))           # r4 = width * (y + dy)
            emit(ASM.add_reg(4, 4, x_reg))   # + x
            emit(ASM.lsl_imm(4, 4, 1))       # * 2 bytes per pixel
            emit(ASM.load_immediate(5, VRAM_START))
            emit(ASM.add_reg(4, 4, 5))       # + VRAM base

            store_word_immediate(scratch, REG_DMA3SAD)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(4, TMP))            # destination is the computed address
            store_word_immediate(control, REG_DMA3CNT)
          end
        end

        # Draw a defined bitmap at a runtime (x, y). An opaque bitmap streams from
        # ROM by DMA; one with transparency is drawn pixel-by-pixel so its
        # transparent pixels can be skipped. Either way the draw is clipped to the
        # screen at run time — a bitmap pushed partway off an edge draws only its
        # visible part, with nothing written past the framebuffer.
        def emit_blit(node)
          blit_unsupported_in_buffered! if @lower_mode == :buffered
          bmp = @bitmaps.fetch(node[:name]) do
            raise LoweringError, "blit of undefined image #{node[:name].inspect}"
          end
          bmp[:transparent] ? emit_blit_transparent(node, bmp) : emit_blit_opaque(node, bmp)
        end

        # Opaque bitmap: one 16-bit DMA per row, source in the cartridge (source
        # and destination both increment, unlike a fill), so each row's pixels
        # stream straight from ROM into VRAM.
        #
        # Every row is clipped to the screen at run time, since x/y are runtime
        # values (variables) — the clip math can't be done at build time. A row
        # off the top or bottom is skipped whole; a row crossing a side edge has
        # its transfer trimmed to the on-screen span: the DMA source skips the
        # columns clipped off the left, the destination starts at the first
        # on-screen column, and the count is just the visible width. Without this
        # trim a row that ran past the screen's right edge would wrap onto the
        # start of the next line.
        #
        # r6 holds the bitmap base and r7/r8 hold x/y across the whole blit; the
        # rest (r2–r5, r9–r11) are per-row scratch.
        def emit_blit_opaque(node, bmp)
          width = bmp[:width]
          base_reg = 6
          x_reg = 7
          y_reg = 8
          eval_value(node[:x])
          emit(ASM.mov_reg(x_reg, ACC))
          eval_value(node[:y])
          emit(ASM.mov_reg(y_reg, ACC))
          emit_load_data_address(base_reg, node[:name]) # r6 = bitmap address in the cartridge

          bmp[:height].times do |row|
            skip = gensym

            # screen_y = y + row; drop the whole row if it's above or below screen.
            emit_add_const(9, y_reg, row, 2)          # r9 = screen_y
            emit(ASM.cmp_imm(9, 0))
            emit_branch(:bcond, skip, cond: :lt)
            emit(ASM.cmp_imm(9, SCREEN_HEIGHT))
            emit_branch(:bcond, skip, cond: :ge)

            # visible_left = max(x, 0)  -> r10
            emit(ASM.mov_reg(10, x_reg))
            emit(ASM.cmp_imm(x_reg, 0))
            keep_left = gensym
            emit_branch(:bcond, keep_left, cond: :ge)
            emit(ASM.load_immediate(10, 0))
            place_label(keep_left)

            # visible_right = min(x + width, SCREEN_WIDTH)  -> r11
            emit_add_const(11, x_reg, width, 2)
            emit(ASM.cmp_imm(11, SCREEN_WIDTH))
            keep_right = gensym
            emit_branch(:bcond, keep_right, cond: :le)
            emit(ASM.load_immediate(11, SCREEN_WIDTH))
            place_label(keep_right)

            # visible_width = visible_right - visible_left  -> r4; if <= 0 the row
            # is entirely off to one side, so skip it.
            emit(ASM.sub_reg(4, 11, 10))
            emit(ASM.cmp_imm(4, 0))
            emit_branch(:bcond, skip, cond: :le)

            # source = base + (row*width + left_skip) * 2  -> r5
            emit(ASM.sub_reg(5, 10, x_reg))           # left_skip = visible_left - x
            emit_add_const(5, 5, row * width, 2)      # + this row's start in the pixels
            emit(ASM.lsl_imm(5, 5, 1))                # * 2 bytes/pixel
            emit(ASM.add_reg(5, base_reg, 5))

            # dest = VRAM + (screen_y*SCREEN_WIDTH + visible_left) * 2  -> r3
            emit(ASM.load_immediate(2, SCREEN_WIDTH))
            emit(ASM.mul(3, 9, 2))                    # r3 = screen_y * width
            emit(ASM.add_reg(3, 3, 10))               # + visible_left
            emit(ASM.lsl_imm(3, 3, 1))
            emit(ASM.load_immediate(2, VRAM_START))
            emit(ASM.add_reg(3, 3, 2))

            # control = visible_width | DMA_ENABLE (16-bit, src+dest increment).
            emit(ASM.orr_imm(4, 4, DMA_ENABLE))

            emit(ASM.load_immediate(TMP, REG_DMA3SAD))
            emit(ASM.str(5, TMP))                     # source: visible span in ROM
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(3, TMP))                     # destination: visible span in VRAM
            emit(ASM.load_immediate(TMP, REG_DMA3CNT))
            emit(ASM.str(4, TMP))                     # kick off the row copy

            place_label(skip)
          end
        end

        # Transparent bitmap: the art is known at build time, so unroll it. Emit a
        # store only for each NON-transparent pixel — with its color baked in, at
        # the run-time-computed destination — and simply skip transparent ones, so
        # the background shows through.
        #
        # Each store is guarded by a run-time screen-bounds check (x/y are runtime
        # values), so a lit pixel pushed off an edge is dropped rather than written
        # off the framebuffer — the same per-pixel clipping the interpreter does.
        # The row's off-top/off-bottom test is hoisted out of the pixel loop.
        #
        # r2/r3 hold x/y across the blit; r4/r6 are the per-row screen_y and row
        # base; r7/r8 are per-pixel scratch.
        def emit_blit_transparent(node, bmp)
          width = bmp[:width]
          colors = bmp[:pixels].unpack("v*")

          x_reg = 2
          y_reg = 3
          eval_value(node[:x])
          emit(ASM.mov_reg(x_reg, ACC))
          eval_value(node[:y])
          emit(ASM.mov_reg(y_reg, ACC))

          bmp[:height].times do |row|
            lit = width.times.reject { |col| colors[(row * width) + col] == bmp[:transparent] }
            next if lit.empty? # a fully transparent row draws nothing

            skip_row = gensym
            emit_add_const(4, y_reg, row, 5)          # r4 = screen_y
            emit(ASM.cmp_imm(4, 0))
            emit_branch(:bcond, skip_row, cond: :lt)
            emit(ASM.cmp_imm(4, SCREEN_HEIGHT))
            emit_branch(:bcond, skip_row, cond: :ge)
            emit(ASM.load_immediate(5, SCREEN_WIDTH))
            emit(ASM.mul(6, 4, 5))                    # r6 = screen_y * width (row base)

            lit.each do |col|
              color = colors[(row * width) + col]
              skip_px = gensym

              emit_add_const(7, x_reg, col, 8)        # r7 = screen_x
              emit(ASM.cmp_imm(7, 0))
              emit_branch(:bcond, skip_px, cond: :lt)
              emit(ASM.cmp_imm(7, SCREEN_WIDTH))
              emit_branch(:bcond, skip_px, cond: :ge)

              emit(ASM.add_reg(7, 6, 7))              # r7 = row_base + screen_x
              emit(ASM.lsl_imm(7, 7, 1))              # * 2 bytes/pixel
              emit(ASM.load_immediate(8, VRAM_START))
              emit(ASM.add_reg(7, 7, 8))              # VRAM address
              emit(ASM.load_immediate(8, color))
              emit(ASM.store_halfword(8, 7))

              place_label(skip_px)
            end
            place_label(skip_row)
          end
        end

        # rd = rn + imm. A small immediate rides directly in the ADD; a larger one
        # (a wide bitmap's row offset, say) is loaded into +scratch+ first, since
        # ARM can only fold an 8-bit rotated immediate into the instruction.
        def emit_add_const(rd, rn, imm, scratch)
          if imm.zero?
            emit(ASM.mov_reg(rd, rn)) unless rd == rn
          elsif ASM.encode_rotated_immediate(imm)
            emit(ASM.add_imm(rd, rn, imm))
          else
            emit(ASM.load_immediate(scratch, imm))
            emit(ASM.add_reg(rd, rn, scratch))
          end
        end

        # rd = rn & imm — the ring-wrap mask. A mask that fits an 8-bit rotated
        # immediate (capacity up to 256) rides directly in the AND; a wider one is
        # loaded into +scratch+ first, since ARM can't fold it into the instruction.
        def emit_and_const(rd, rn, imm, scratch)
          if ASM.encode_rotated_immediate(imm)
            emit(ASM.and_imm(rd, rn, imm))
          else
            emit(ASM.load_immediate(scratch, imm))
            emit(ASM.and_reg(rd, rn, scratch))
          end
        end

        # Draw a line of text with the built-in bitmap font. The color loads once,
        # then every set pixel of every glyph is a single halfword store at its
        # fixed VRAM address; off-screen pixels are dropped. Positions are constant.
        def emit_draw_text(node)
          return emit_draw_text_buffered(node) if @lower_mode == :buffered

          x, y = constant_ints!(node, :x, :y)
          emit(ASM.load_immediate(ACC, Color.resolve(node[:color])))

          Font.each_pixel(node[:text]) do |dx, dy|
            px = x + dx
            py = y + dy
            next unless in_bounds?(px, py)

            emit(ASM.load_immediate(TMP, VRAM_START + ((py * SCREEN_WIDTH) + px) * 2))
            emit(ASM.store_halfword(ACC, TMP))
          end
        end

        # Draw the run-time digit: render whichever of 0..9 the value works out to.
        # The bitmap font can't be indexed by a run-time value, so this expands to
        # ten mutually exclusive guards, one per digit, exactly one of which draws.
        # Built as a sub-tree and emitted through the shared statement paths, so it
        # honors the current display mode (direct or buffered) via draw_text.
        def emit_draw_digit(node)
          10.times do |k|
            emit_statement(Build.if_(Build.binop(:==, node[:value], Build.int(k)),
                                     Build.draw_text(k.to_s, node[:x], node[:y], node[:color])))
          end
        end

        # Stash a solid fill color as a packed two-pixel word in IWRAM and return
        # its address — the fixed source a DMA fill re-reads for every pixel.
        def hold_fill_word(color)
          value = Color.resolve(color)
          word = (value << 16) | value
          scratch = var_addr(:_dma_scratch)
          store_word_immediate(word, scratch)
          scratch
        end

        # The DMA3 control word for a source-fixed 32-bit fill of +count+ words.
        def dma_fill_control(count)
          count | DMA_ENABLE | DMA_32BIT | DMA_SRC_FIXED
        end

        # Point DMA3 at (source, destination), then kick it off — one filled row.
        def fire_dma_fill(source_addr, dest_addr, control)
          store_word_immediate(source_addr, REG_DMA3SAD)
          store_word_immediate(dest_addr, REG_DMA3DAD)
          store_word_immediate(control, REG_DMA3CNT)
        end

        # Guard the fast block-fill's even-width assumption: it moves two pixels at
        # a time, so an odd width would drop the last column (and a width of 0 or 1
        # would ask DMA for a runaway transfer).
        def even_width!(w, kind)
          return if w.positive? && w.even?

          raise LoweringError,
                "#{kind} needs an even, positive width (got #{w}) — the fast " \
                "block fill moves two pixels per step"
        end

        # --- Mode 4 (double-buffered) drawing -----------------------------------
        #
        # These mirror the direct-color fills above, with two differences forced by
        # the indexed screen: a pixel is one byte (an index into the color table),
        # not two, so addresses and counts are in bytes; and video memory can't be
        # written a single byte at a time (a lone byte write hits both halves of its
        # 16-bit slot), so fills move whole 16-bit units — two pixels — at once, and
        # a fill must start on an even column. The destination is the hidden page,
        # whose address lives in a run-time variable (BACKBUF) and swaps every flip.

        # Clear the hidden page to a solid color: one DMA that repeats the packed
        # index word across the whole page.
        def emit_clear_screen_buffered(node)
          scratch = hold_index_word(node[:color])
          store_word_immediate(scratch, REG_DMA3SAD)
          point_dma_dest_at_backbuf
          count = SCREEN_WIDTH * SCREEN_HEIGHT / 4 # 32-bit words, 4 indices each
          store_word_immediate(dma_fill_control(count), REG_DMA3CNT)
        end

        # A rectangle at a constant position/size, filled per row into the hidden
        # page. fill_rect and dma_fill_rect share this — in Mode 4 both are the same
        # packed block fill.
        def emit_fill_rect_buffered(node)
          x, y, w, h = constant_ints!(node, :x, :y, :w, :h)
          even_width!(w, node.kind)
          x &= ~1 # the tear-free screen fills two pixels at a time, so start on an even
                  # column — snap x down to keep it aligned, matching draw_rect_at
          scratch = hold_index_word(node[:color])
          control = dma_fill_control_16(w / 2)

          h.times do |dy|
            row = y + dy
            next unless (0...SCREEN_HEIGHT).cover?(row)

            store_word_immediate(scratch, REG_DMA3SAD)
            load_var(ACC, BACKBUF)                             # r0 = hidden page base
            emit(ASM.load_immediate(TMP, (row * SCREEN_WIDTH) + x)) # + byte offset (1 byte/pixel)
            emit(ASM.add_reg(ACC, ACC, TMP))
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(ACC, TMP))                            # destination = that row
            store_word_immediate(control, REG_DMA3CNT)
          end
        end

        # A rectangle whose position is computed at run time, filled per row into the
        # hidden page. Its size is constant; its x should be even (the caller keeps
        # it so — grid games move on an even step). r2/r3 hold x/y across the loop.
        def emit_draw_rect_at_buffered(node)
          w, h = constant_ints!(node, :w, :h)
          even_width!(w, :draw_rect_at)
          scratch = hold_index_word(node[:color])
          control = dma_fill_control_16(w / 2)

          x_reg = 2
          y_reg = 3
          eval_value(node[:x])
          emit(ASM.mov_reg(x_reg, ACC))
          # The tear-free screen is written two pixels at a time, so a fill must start
          # on an even column. x is decided at run time, so we snap it down to the
          # nearest even column (clear its low bit) — a stray odd x just nudges the
          # rectangle one pixel left rather than landing misaligned.
          emit(ASM.lsr_imm(x_reg, x_reg, 1))
          emit(ASM.lsl_imm(x_reg, x_reg, 1))
          eval_value(node[:y])
          emit(ASM.mov_reg(y_reg, ACC))

          h.times do |dy|
            # r4 = (y + dy) * SCREEN_WIDTH + x  — the byte offset into the page
            if dy.zero?
              emit(ASM.mov_reg(4, y_reg))
            else
              emit(ASM.add_imm(4, y_reg, dy))
            end
            emit(ASM.load_immediate(5, SCREEN_WIDTH))
            emit(ASM.mul(4, 5, 4))            # r4 = SCREEN_WIDTH * (y + dy)
            emit(ASM.add_reg(4, 4, x_reg))    # + x
            load_var(5, BACKBUF)              # r5 = hidden page base
            emit(ASM.add_reg(4, 4, 5))        # r4 = destination

            store_word_immediate(scratch, REG_DMA3SAD)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(4, TMP))
            store_word_immediate(control, REG_DMA3CNT)
          end
        end

        # Stash a solid fill color as a word of four packed indices in IWRAM and
        # return its address — the fixed source a Mode 4 DMA fill re-reads. A 16-bit
        # fill reads its low half (two indices); a 32-bit fill reads all four.
        def hold_index_word(color)
          index = @palette.index_of(color)
          word = index * 0x01010101 # the same index in all four bytes
          scratch = var_addr(:_dma_scratch)
          store_word_immediate(word, scratch)
          scratch
        end

        # Point DMA3's destination at the hidden page's base (a run-time value).
        def point_dma_dest_at_backbuf
          load_var(ACC, BACKBUF)
          emit(ASM.load_immediate(TMP, REG_DMA3DAD))
          emit(ASM.str(ACC, TMP))
        end

        # The DMA3 control word for a source-fixed 16-bit fill of +count+ halfwords —
        # the Mode 4 fill unit (two packed indices per halfword).
        def dma_fill_control_16(count)
          count | DMA_ENABLE | DMA_SRC_FIXED # 16-bit is the default (DMA_16BIT == 0)
        end

        # Draw a line of text on the hidden page. Each lit font pixel is a single
        # color index (one byte), but the indexed screen can't take a lone byte
        # write, so each pixel is a read-modify-write: read the 16-bit unit that
        # contains it, splice the index into the correct half, write it back. The
        # glyph positions are known while building, so which half each pixel lands in
        # is settled here, not at run time. Off-screen pixels are dropped.
        def emit_draw_text_buffered(node)
          x, y = constant_ints!(node, :x, :y)
          index = @palette.index_of(node[:color])
          base = 6
          load_var(base, BACKBUF) # the hidden page base, held for the whole line

          Font.each_pixel(node[:text]) do |dx, dy|
            px = x + dx
            py = y + dy
            next unless in_bounds?(px, py)

            emit_write_index_pixel_const(base, px, py, index)
          end
        end

        # Plot one pixel on the hidden page. With constant coordinates the target
        # half is known while building; with a computed coordinate it's found from
        # the live x at run time.
        def emit_pixel_buffered(node)
          index = @palette.index_of(node[:color])
          xi = const_int(node[:x])
          yi = const_int(node[:y])

          if xi && yi
            return unless in_bounds?(xi, yi)

            base = 6
            load_var(base, BACKBUF)
            emit_write_index_pixel_const(base, xi, yi, index)
          else
            emit_pixel_buffered_runtime(node, index)
          end
        end

        # Read-modify-write one pixel at a build-time-constant position: overwrite
        # its byte inside the 16-bit unit, leaving the paired pixel untouched.
        # +base_reg+ holds the hidden page base. Uses r0/r1 as scratch.
        def emit_write_index_pixel_const(base_reg, px, py, index)
          halfword_offset = ((py * SCREEN_WIDTH) + px) & ~1 # start of the pixel's 16-bit unit
          emit_add_const(1, base_reg, halfword_offset, ACC) # r1 = &unit (scratch r0)
          emit(ASM.load_halfword(ACC, 1))                   # r0 = the current pixel pair
          splice_index_byte(ACC, index, px.odd?)
          emit(ASM.store_halfword(ACC, 1))
        end

        # Read-modify-write one pixel whose coordinates are computed at run time: the
        # address and which half to touch both come from the live x/y. r2/r3 hold
        # x/y; r1 the unit address; r0 the value being spliced; r4/r5 scratch.
        def emit_pixel_buffered_runtime(node, index)
          eval_value(node[:x])
          emit(ASM.mov_reg(2, ACC))
          eval_value(node[:y])
          emit(ASM.mov_reg(3, ACC))

          emit(ASM.load_immediate(4, SCREEN_WIDTH))
          emit(ASM.mul(4, 3, 4))          # r4 = y * width
          emit(ASM.add_reg(4, 4, 2))      # r4 = y*width + x (byte offset)
          load_var(5, BACKBUF)            # r5 = hidden page base
          emit(ASM.add_reg(1, 5, 4))      # r1 = base + byte offset (maybe odd)
          emit(ASM.lsr_imm(1, 1, 1))      # clear the low bit ->
          emit(ASM.lsl_imm(1, 1, 1))      # r1 = the containing 16-bit unit's address
          emit(ASM.load_halfword(ACC, 1)) # r0 = the current pixel pair

          emit(ASM.and_imm(4, 2, 1))      # r4 = x & 1 (0 = left/low byte, 1 = right/high)
          emit(ASM.cmp_imm(4, 0))
          high = gensym
          done = gensym
          emit_branch(:bcond, high, cond: :ne)
          splice_index_byte(ACC, index, false) # even x: low byte
          emit_branch(:b, done)
          place_label(high)
          splice_index_byte(ACC, index, true)  # odd x: high byte
          place_label(done)
          emit(ASM.store_halfword(ACC, 1))
        end

        # Replace one byte of the 16-bit pixel pair in +reg+ with +index+, keeping
        # the other pixel: the high byte when +high+ (an odd column), else the low.
        def splice_index_byte(reg, index, high)
          if high
            emit(ASM.and_imm(reg, reg, 0x00FF))     # keep the left (low) pixel
            emit(ASM.orr_imm(reg, reg, index << 8)) # set the right (high) pixel
          else
            emit(ASM.and_imm(reg, reg, 0xFF00))     # keep the right (high) pixel
            emit(ASM.orr_imm(reg, reg, index))      # set the left (low) pixel
          end
        end

        # blit doesn't work on the indexed screen: its images are stored as direct
        # colors, which need converting to palette indices first. Point at what does.
        def blit_unsupported_in_buffered!
          raise LoweringError,
                "blit can't draw on the tear-free screen (tear_free: true). Its images are stored as " \
                "direct colors, which the tear-free screen can't show without converting them to a color " \
                "table first. Draw with the rectangle fills, draw_text, or pixel there, or drop " \
                "`tear_free:` to use the direct-color screen, where blit works."
        end

        # --- audio ---------------------------------------------------------------
        #
        # Each op resolves to a short list of sound-register writes via the shared
        # Sound module, so the ROM and the interpreter play the same thing. A write
        # is just "put this 16-bit value at this register address."

        def emit_writes(writes)
          writes.each { |address, value| write_reg16(address, value) }
        end

        # Power on the audio hardware.
        def emit_enable_sound
          emit_writes(Sound::Registers.enable)
        end

        # A one-off sound effect on channel 2. Resolve the beep to concrete musical
        # values (a defined-sound name, a preset, or a raw frequency), then write
        # the channel-2 registers.
        def emit_beep(node)
          effect = Sound.resolve_effect(node[:tone], duty: node[:duty], decay: node[:decay],
                                                     volume: node[:volume], defined: @defined_sounds)
          emit_writes(Sound::Registers.channel2(**effect))
        end

        # Silence the music channel.
        def emit_stop_music
          emit_writes(Sound::Registers.stop_music)
        end

        # Advance a song by one frame. A per-song counter in IWRAM ticks up; each
        # note whose frame matches the counter triggers, and once the counter
        # reaches the song's length it wraps to 0 so the tune loops. This unrolls
        # the whole score into frame comparisons — the same sequencer the legacy
        # emitter builds, so migrated songs sound identical.
        def emit_play_song(node)
          song = @songs.fetch(node[:name]) do
            raise LoweringError, "play_song for undefined song #{node[:name].inspect}"
          end
          counter = :"_music_frame_#{node[:name]}"

          load_var(ACC, counter)             # counter += 1
          emit(ASM.add_imm(ACC, ACC, 1))
          store_var(ACC, counter)

          song[:events].each do |frame, frequency|
            skip = gensym
            load_var(ACC, counter)
            compare_acc_to(frame)
            emit_branch(:bcond, skip, cond: :ne) # counter != this note's frame? skip it
            emit_writes(Sound::Registers.channel1_note(frequency: frequency,
                                                       duty: song[:duty], volume: song[:volume]))
            place_label(skip)
          end

          wrap = gensym                        # loop: if counter >= length, reset to 0
          load_var(ACC, counter)
          compare_acc_to(song[:total_frames])
          emit_branch(:bcond, wrap, cond: :lt)
          emit(ASM.load_immediate(ACC, 0))
          store_var(ACC, counter)
          place_label(wrap)
        end

        # Compare the accumulator to a constant. The constant loads into a temp
        # first, so any 32-bit value works (the immediate compare form only encodes
        # small constants, and frame counts can exceed that).
        def compare_acc_to(value)
          emit(ASM.load_immediate(TMP, value))
          emit(ASM.cmp_reg(ACC, TMP))
        end

        # Busy-wait for the vertical blank — the brief pause between drawn frames,
        # the safe moment to change what's on screen. We poll the scanline counter:
        # first let any current blank finish, then wait for the next to begin. The
        # two back-jumps are a fixed two instructions, so they need no label.
        def emit_wait_vblank
          emit(ASM.load_immediate(ACC, REG_VCOUNT))
          emit(ASM.load_halfword(TMP, ACC))
          emit(ASM.cmp_imm(TMP, 160))
          emit(ASM.branch_cond(:ge, -2))  # still past line 160: keep waiting
          emit(ASM.load_halfword(TMP, ACC))
          emit(ASM.cmp_imm(TMP, 160))
          emit(ASM.branch_cond(:lt, -2))  # not yet at line 160: keep waiting

          # A new frame begins now, so refresh the input snapshot: last frame's
          # keys become "previous", and we latch this frame's keys as "current".
          snapshot_keys if @uses_pressed

          # This is the safe moment to swap pages when a buffered scene is live:
          # show the frame just drawn and hand the program the other page. Which mode
          # is live can change frame to frame, so the flip is decided at run time.
          emit_flip_if_buffered if @any_buffered
        end

        # --- value expressions --------------------------------------------------

        # Emit code that leaves the value of +node+ in the accumulator (r0).
        def eval_value(node)
          case node.kind
          when :int then emit(ASM.load_immediate(ACC, Int32.wrap(node[:value])))
          when :var_ref then load_var(ACC, node[:name])
          when :neg
            eval_value(node[:operand])
            emit(ASM.rsb_imm(ACC, ACC, 0))
          when :binop then eval_binop(node)
          when :held then eval_held(node[:button])
          when :pressed then eval_pressed(node[:button])
          # A chance is "the random draw is below the threshold" — evaluate it as
          # exactly that comparison.
          when :chance then eval_value(Build.binop(:<, node[:draw], Build.int(node[:percent])))
          when :data_byte then eval_data_byte(node)
          when :list_get then eval_list_get(node)
          when :list_len then eval_list_len(node)
          else
            raise LoweringError, "the GBA backend cannot evaluate #{node.kind.inspect}"
          end
        end

        # Read one byte of a named blob: point the address register at the blob,
        # then load the byte at its fixed index into the accumulator.
        def eval_data_byte(node)
          emit_load_data_address(ADDR, node[:name])
          emit(ASM.ldrb_offset(ACC, ADDR, node[:index]))
        end

        # Evaluate lhs and rhs, holding lhs on the stack while rhs is computed, then
        # combine. Using the stack for the intermediate keeps arbitrarily nested
        # expressions correct without a register allocator.
        def eval_binop(node)
          eval_value(node[:lhs])
          emit(ASM.push(ACC))
          eval_value(node[:rhs])
          emit(ASM.pop(TMP))             # r1 = lhs, r0 = rhs

          op = node[:op]
          case op
          when :+ then emit(ASM.add_reg(ACC, TMP, ACC))
          when :- then emit(ASM.sub_reg(ACC, TMP, ACC))
          when :* then emit(ASM.mul(ACC, TMP, ACC))
          # Condition composition: both sides are already 0/1, so a bitwise
          # and/or gives the combined 0/1 the branch tests for.
          when :and then emit(ASM.and_reg(ACC, TMP, ACC))
          when :or then emit(ASM.orr_reg(ACC, TMP, ACC))
          when :/ then emit_division
          else emit_comparison(op)
          end
        end

        # Divide through the BIOS Div routine — the ARM7TDMI has no divide
        # instruction, so a division traps into the BIOS. It wants the numerator
        # in r0 and the denominator in r1; after the binop setup r1 already holds
        # lhs (numerator) and r0 holds rhs (denominator), so swap them (via r2)
        # and trap. The quotient comes back in r0, our accumulator — right where
        # an expression's result belongs. (r1 gets the remainder, r3 is clobbered;
        # neither survives a statement here, so that's fine.)
        def emit_division
          emit(ASM.mov_reg(2, ACC))   # r2 = denominator (rhs)
          emit(ASM.mov_reg(ACC, TMP)) # r0 = numerator (lhs)
          emit(ASM.mov_reg(TMP, 2))   # r1 = denominator
          emit(ASM.swi(0x06 << 16))   # BIOS Div: r0 = r0 / r1
        end

        # A comparison yields 1 or 0. Compare, default the result to 0, and set it
        # to 1 only when the comparison holds.
        def emit_comparison(op)
          _true_cond, false_cond = COMPARISONS.fetch(op) do
            raise LoweringError, "unknown operator #{op.inspect}"
          end
          emit(ASM.cmp_reg(TMP, ACC))          # lhs - rhs
          done = gensym
          emit(ASM.load_immediate(ACC, 0))
          emit_branch(:bcond, done, cond: false_cond)
          emit(ASM.load_immediate(ACC, 1))
          place_label(done)
        end

        # `held` reads the key register and tests the button's bit. The register is
        # active-low, so the bit reads 0 while the button is down: TST sets the zero
        # flag exactly then, and we turn that into 1 (held) or 0 (not).
        def eval_held(button)
          mask = BUTTON_BIT.fetch(button) do
            raise LoweringError, "unknown button #{button.inspect}"
          end
          emit(ASM.load_immediate(TMP, REG_KEYINPUT))
          emit(ASM.load_halfword(ACC, TMP))
          emit(ASM.tst_imm(ACC, mask))         # zero flag set => button down
          done = gensym
          emit(ASM.load_immediate(ACC, 0))
          emit_branch(:bcond, done, cond: :ne) # bit not zero => not held => leave 0
          emit(ASM.load_immediate(ACC, 1))
          place_label(done)
        end

        # `pressed` is the down-edge: down this frame, up last frame. The snapshots
        # are active-high, so newly-pressed buttons = CUR_KEYS AND NOT PREV_KEYS;
        # test the button's bit in that.
        def eval_pressed(button)
          mask = BUTTON_BIT.fetch(button) do
            raise LoweringError, "unknown button #{button.inspect}"
          end
          load_var(ACC, CUR_KEYS)
          load_var(TMP, PREV_KEYS)
          emit(ASM.mvn_reg(TMP, TMP))          # ~prev
          emit(ASM.and_reg(ACC, ACC, TMP))     # cur & ~prev = buttons newly down
          emit(ASM.tst_imm(ACC, mask))
          done = gensym
          emit(ASM.load_immediate(ACC, 0))
          emit_branch(:bcond, done, cond: :eq) # bit zero => not a fresh press => 0
          emit(ASM.load_immediate(ACC, 1))
          place_label(done)
        end

        # Start both snapshots empty (no button pressed) before the game runs.
        def emit_input_init
          emit(ASM.load_immediate(ACC, 0))
          store_var(ACC, CUR_KEYS)
          store_var(ACC, PREV_KEYS)
        end

        # Once per frame: shift this frame's "current" into "previous", then latch
        # the live key state as the new "current". The key register is active-low,
        # so invert it and keep the ten button bits to get an active-high set.
        def snapshot_keys
          load_var(ACC, CUR_KEYS)
          store_var(ACC, PREV_KEYS)              # previous = last frame's current
          emit(ASM.load_immediate(TMP, REG_KEYINPUT))
          emit(ASM.load_halfword(ACC, TMP))
          emit(ASM.mvn_reg(ACC, ACC))            # invert: 1 bit now means "down"
          emit(ASM.lsl_imm(ACC, ACC, 22))        # drop everything above the
          emit(ASM.lsr_imm(ACC, ACC, 22))        # ten button bits
          store_var(ACC, CUR_KEYS)               # current = this frame's keys
        end

        # --- variables & small emit primitives ----------------------------------

        # A variable is 4 bytes in IWRAM, addresses handed out on first mention.
        def var_addr(name)
          @vars[name] ||= begin
            address = @next_var
            @next_var += 4
            address
          end
        end

        def load_var(reg, name)
          emit(ASM.load_immediate(ADDR, var_addr(name)))
          emit(ASM.ldr(reg, ADDR))
        end

        def store_var(reg, name)
          emit(ASM.load_immediate(ADDR, var_addr(name)))
          emit(ASM.str(reg, ADDR))
        end

        # Write a 16-bit value to a memory-mapped register / VRAM halfword.
        def write_reg16(address, value)
          emit(ASM.load_immediate(ACC, value))
          emit(ASM.load_immediate(TMP, address))
          emit(ASM.store_halfword(ACC, TMP))
        end

        # Write a full 32-bit word to an address (used for the DMA registers).
        def store_word_immediate(value, address)
          emit(ASM.load_immediate(ACC, value))
          emit(ASM.load_immediate(TMP, address))
          emit(ASM.str(ACC, TMP))
        end

        # The integer value of a constant operand, or nil if it isn't a constant.
        def const_int(node)
          return Int32.wrap(node) if node.is_a?(Integer)
          return Int32.wrap(node[:value]) if node.is_a?(Node) && node.kind == :int

          nil
        end

        def constant_ints!(node, *keys)
          keys.map do |key|
            const_int(node[key]) ||
              raise(LoweringError,
                    "the GBA backend needs a constant #{key} for #{node.kind} " \
                    "(a computed one is the runtime-rect work, tracked separately)")
          end
        end

        def in_bounds?(x, y)
          (0...SCREEN_WIDTH).cover?(x) && (0...SCREEN_HEIGHT).cover?(y)
        end
      end
    end
  end
end
