# frozen_string_literal: true

require_relative "gba/emit"
require_relative "gba/statements"
require_relative "gba/lists"
require_relative "gba/drawing"
require_relative "gba/buffered"
require_relative "gba/audio"
require_relative "gba/expressions"
require_relative "gba/primitives"
require_relative "gba/collision"
require_relative "gba/timers"

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
        include Emit
        include Statements
        include Lists
        include Drawing
        include Buffered
        include Audio
        include Expressions
        include Primitives
        include Collision
        include Timers

        class LoweringError < StandardError; end

        # Friendly screen-mode names → the display-control register value. Only
        # the direct-color bitmap mode is lowered here; other modes are their own
        # work. (This mirrors the DSL's names.)
        SCREEN_MODES = {
          bitmap: MODE_3 | BG2_ENABLE, # direct-color framebuffer
          tiled:  MODE_0 | BG0_ENABLE, # one regular tiled background layer
        }.freeze

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

        # When scenes use different screen modes, the framework switches the
        # hardware as each scene takes over. A hidden variable holds which mode is
        # live, so a scene only touches the display registers when the mode actually
        # changes (a transition), not every frame. Direct = single-buffered Mode 3,
        # Buffered = double-buffered Mode 4, Tiled = tile backgrounds + hardware
        # sprites (Mode 0).
        MODE_STATE = :__mode
        MODE_DIRECT = 0
        MODE_BUFFERED = 1
        MODE_TILED = 2

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

        # Interrupt-driven frame timing. `wait_vblank` asks the BIOS to sleep the CPU
        # until the next VBlank rather than busy-poll the scanline counter — the BIOS
        # routine VBlankIntrWait (software-interrupt number 5). It only returns once a
        # VBlank interrupt has fired, which needs the interrupts set up at boot and a
        # small handler that acknowledges each one (see #emit_irq_setup / #emit_irq_handler).
        SWI_VBLANK_INTR_WAIT = 0x05
        IRQ_HANDLER_LABEL = "__irq_vblank" # the interrupt routine, addressed by the vector

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
          @backing = {}          # name -> { width:, height:, base: } (a sprite's save-under RAM)
          @lists = {}            # name -> { capacity:, mask:, base: } (a list's IWRAM layout)
          @timers = {}           # name -> { rate:, count: } (which hardware timer(s) back it)
          @next_hw_timer = 0     # next free hardware timer index (0-3)
          @label_seq = 0
          @uses_pressed = false  # whether the program reads edge-detected input
          @palette = nil         # the color table, built once when any scene is buffered
          @modes = nil           # IR::Modes: which screen mode each scene resolves to
          @any_buffered = false  # does any scene use double buffering?
          @mixed_display = false # does the program cross the bitmap/tiled boundary?
          @manage_modes = false  # is the display switched per scene (buffered or mixed)?
          @default_mode = :direct # the boot screen mode (from the top-level `screen`)
          @func_mode = {}        # func name -> :direct | :buffered (resolved from the call graph)
          @scene_funcs = []      # funcs entered per frame, which switch the mode on entry
          @lower_mode = :direct  # the mode draws currently lower in (set per func)
          @tiled = false         # does the program use tile mode (screen :tiled)?
          @backgrounds = {}      # name -> resolved tiled-background layer (map blob, BG number, screen block, priority)
          @bg_shared = nil       # the one palette + character block every background layer shares
          @has_objects = false   # does the program declare any composited objects (sprites)?
          @objects = {}          # name -> resolved sprite layout (OAM slot, tile/palette blobs)
        end

        # Lower a program to finished GBA machine code: run the emit pass and
        # resolve the jumps, then return the raw code bytes. Packaging them into a
        # cartridge — header, entry branch, checksum, padding — is ROM.assemble's
        # job; this method knows only how to compile the IR, not how a ROM is laid
        # out.
        def lower(program)
          collect_definitions(program)
          register_timers(program) # assign each named timer its hardware timer index(es)
          prepare_pixel_masks(program) # solid-pixel tables for any per-pixel collision test
          resolve_modes(program)
          @tiled = program.walk.any? { |node| node.kind == :screen && node[:mode] == :tiled }
          prepare_backgrounds(program) if @tiled
          @has_objects = program.walk.any? { |node| node.kind == :object }
          prepare_objects(program) if @has_objects
          prepare_palette(program) if @any_buffered
          @uses_pressed = program.walk.any? { |node| node.kind == :pressed }
          @uses_vblank = program.walk.any? { |node| node.kind == :wait_vblank }
          emit_irq_setup if uses_irq? # arm the interrupts the program needs (VBlank and/or timers)
          emit_input_init if @uses_pressed
          emit_boot_screen if @manage_modes # set the boot mode (+ palette for buffered)
          # Upload the tiled assets once at boot only when the program stays in tiled
          # mode. When it crosses the bitmap/tiled boundary, a bitmap scene overwrites
          # the video memory the tiles live in, so the assets are (re)uploaded on each
          # entry into a tiled scene instead (enter_tiled_mode) — always current, and
          # only paid on the actual switch.
          unless @manage_modes
            emit_boot_backgrounds if @tiled && !@backgrounds.empty? # shared BG palette + tiles
            emit_boot_objects if @has_objects # sprite tiles/colors + clear the sprite table
          end
          @lower_mode = @default_mode
          program.children.each { |stmt| emit_statement(stmt) }
          emit_functions
          emit_irq_handler if uses_irq? # the interrupt dispatcher itself, reached only via the vector
          emit_data_region
          resolve_fixups
          @code
        end

        # Each variable's allocated IWRAM address (name => address), known once the
        # program has been lowered. This backend — not the builder — decides where a
        # variable lives, so this is the authoritative map a hardware test uses to
        # read a variable's value back from memory (see RubyGBA::Verifier#var).
        def var_addresses
          @vars.dup
        end

        # Work out which screen mode each scene draws in. A program that never uses
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
          @mixed_display = @modes.mixed_display?
          # When a program switches the hardware per scene — because some scene double-
          # buffers, or because it crosses the bitmap/tiled boundary — the display
          # registers are managed centrally: set once at boot, then re-set only on a
          # scene's mode transition (its preamble). A single-display-system program
          # leaves each `screen` node to write DISPCNT inline, exactly as before.
          @manage_modes = @any_buffered || @mixed_display
        rescue IR::Modes::Conflict => e
          raise LoweringError, e.message
        end

        private

        # Does the program need any interrupt at all — VBlank (for wait_vblank) or a timer
        # (for an on_tick handler)? If so we arm the interrupts and install the dispatcher.
        def uses_irq?
          @uses_vblank || irq_timers.any?
        end

        # The registers the dispatcher saves around a handler body: r4-r11 (callee-saved,
        # which the BIOS does NOT preserve on interrupt entry) plus lr (a handler body may
        # call a func, which overwrites it — we need it intact for the final return). The
        # BIOS already saved r0-r3 and r12, so a body may clobber those freely.
        IRQ_SAVED_REGS = [4, 5, 6, 7, 8, 9, 10, 11, 14].freeze

        # Arm the interrupts the program uses at boot. The DSL hides this whole dance:
        # point the interrupt vector at our dispatcher, enable each source in IE (and, for
        # VBlank, tell the display to raise it each frame via DISPSTAT), then switch
        # interrupts on. IME goes off first so nothing fires mid-setup and on last once
        # everything's in place — the order boot code uses.
        def emit_irq_setup
          enabled = 0
          enabled |= IRQ_VBLANK if @uses_vblank
          irq_timers.each { |_, info| enabled |= timer_irq_bit(info[:rate]) }

          write_io_halfword(REG_IME, 0)                          # interrupts off while we wire things up
          write_io_halfword(REG_DISPSTAT, DISPSTAT_VBLANK_IRQ) if @uses_vblank # display raises VBlank each frame
          write_io_halfword(REG_IE, enabled)                     # listen for exactly these interrupts
          emit(ASM.load_immediate(TMP, REG_INTR_VECTOR))         # the vector the BIOS reads on every interrupt
          emit_load_label_address(ACC, IRQ_HANDLER_LABEL)        # ...store our dispatcher's address there
          emit(ASM.str(ACC, TMP))
          write_io_halfword(REG_IME, 1)                          # interrupts on
        end

        # The interrupt dispatcher, reached only through the vector. The BIOS enters it in
        # ARM state having saved r0-r3/r12/lr and set up the interrupt stack, so it may use
        # r0-r3 freely and returns with BX LR. It checks each armed source in turn: if that
        # source is pending in REG_IF, run its handler, then acknowledge it. VBlank's
        # handler is empty (just the ack) so wait_vblank wakes; a timer's is its on_tick
        # body. The body may clobber r0-r3/r12, so REG_IF is re-read per source.
        def emit_irq_handler
          place_label(IRQ_HANDLER_LABEL)
          emit(ASM.push(*IRQ_SAVED_REGS))
          # VBlank must ack in TWO places — the hardware flag (REG_IF) and the BIOS's own
          # copy (REG_IFBIOS) that VBlankIntrWait polls — or the CPU would never wake.
          emit_irq_source(IRQ_VBLANK, bios_ack: true) if @uses_vblank
          irq_timers.each do |_, info|
            emit_irq_source(timer_irq_bit(info[:rate])) do
              info[:handler].children.each { |child| emit_statement(child) }
            end
          end
          emit(ASM.pop(*IRQ_SAVED_REGS))
          emit(ASM.return) # BX LR back to the BIOS dispatcher
        end

        # The IE/IF bit for the interrupt hardware timer +index+ raises (timer 0 -> bit
        # IRQ_TIMER0, timer 1 the next bit up, and so on).
        def timer_irq_bit(index)
          IRQ_TIMER0 << index
        end

        # Service one source: if its +bit+ is pending in REG_IF, run its handler (the block,
        # if any) and acknowledge it. REG_IF is loaded fresh here because a previous
        # source's body may have clobbered the scratch registers.
        def emit_irq_source(bit, bios_ack: false)
          skip = gensym
          emit(ASM.load_immediate(TMP, REG_IF))
          emit(ASM.load_halfword(ACC, TMP))     # r0 = pending interrupt flags
          emit(ASM.tst_imm(ACC, bit))
          emit_branch(:bcond, skip, cond: :eq)  # this source's bit is clear -> it didn't fire
          yield if block_given?
          emit_irq_ack(bit, bios: bios_ack)
          place_label(skip)
        end

        # Acknowledge an interrupt: clear its bit in the hardware flag register (writing a
        # 1 bit clears it), and for VBlank also OR it into the BIOS's mirror (REG_IFBIOS)
        # that VBlankIntrWait polls. Uses only r0-r2 (all BIOS-saved).
        def emit_irq_ack(bit, bios: false)
          emit(ASM.load_immediate(ACC, bit))       # r0 = the bit
          emit(ASM.load_immediate(TMP, REG_IF))    # r1 = &REG_IF
          emit(ASM.store_halfword(ACC, TMP))       # REG_IF = bit -> clear it in hardware
          return unless bios

          emit(ASM.load_immediate(TMP, REG_IFBIOS)) # r1 = &REG_IFBIOS
          emit(ASM.load_halfword(2, TMP))           # r2 = its current value
          emit(ASM.orr_reg(2, 2, ACC))              # r2 |= bit
          emit(ASM.store_halfword(2, TMP))          # write it back -> VBlankIntrWait can wake
        end

        # Store a 16-bit immediate into a memory-mapped I/O register — both the address and
        # the value are known at build time, so: load the address, load the value, store the
        # halfword. (r0/r1 are scratch between statements, so this needs no save/restore.)
        def write_io_halfword(address, value)
          emit(ASM.load_immediate(TMP, address))
          emit(ASM.load_immediate(ACC, value))
          emit(ASM.store_halfword(ACC, TMP))
        end

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
            when :backing_buffer
              # Reserve the save-under patch's RAM once, up front, so a save/restore
              # anywhere in the tree already knows its address. Nothing is emitted
              # when the declaration is reached inline — it's pure reservation.
              register_backing(node[:name], node[:width], node[:height])
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

        # The console's tile size (8x8 pixels) and the number of cells across a
        # regular background map (32x32). These are fixed hardware facts.
        TILE_PX = 8
        MAP_CELLS = 32

        # The four regular tiled layers the console can stack (BG0..BG3), and how many
        # 8x8 tiles fit in one 16KB character block (all layers share it in 256-color
        # mode). Maps go in screen blocks 8.. (2KB each), just past that character block.
        MAX_BG_LAYERS = 4
        CHAR_BLOCK_TILES = 256
        FIRST_MAP_SCREENBLOCK = 8
        SCREENBLOCK_BYTES = 0x800
        BG_256_COLOR = 0x0080 # BGxCNT bit 7: 8-bit (256-color) tiles
        BG_SHARED_PAL = :__bg_shared_pal   # the one palette every layer indexes into
        BG_SHARED_CHAR = :__bg_shared_char # the one character block every layer's tiles live in

        # Turn the tiled backgrounds into the data tile hardware reads — one shared color
        # palette, one shared block of tile pictures, and a map per layer — and stash them
        # as ROM blobs uploaded at startup. 256-color layers all draw from a single
        # palette and (here) a single character block, so the tiles and colors of every
        # layer are folded together, each layer remembering where its tiles start. Done up
        # front (after every tile image is collected) so the addresses exist before the
        # code refers to them. emit_background (in Drawing) is the run-time half.
        def prepare_backgrounds(program)
          nodes = program.walk.select { |node| node.kind == :background }
          if nodes.size > MAX_BG_LAYERS
            raise LoweringError,
                  "#{nodes.size} background layers were declared, but the console stacks #{MAX_BG_LAYERS} " \
                  "tiled layers (BG0-BG3) — use at most #{MAX_BG_LAYERS} backgrounds"
          end

          # Seed the shared palette with the transparent backdrop at index 0, and the
          # shared character block with a blank tile 0 (all index 0), so an empty map cell
          # points at a see-through tile and layers behind it show through.
          palette = { 0x0000 => 0 }
          char = (+"").b << ("\x00" * (TILE_PX * TILE_PX)).b
          nodes.each_with_index { |node, layer| prepare_one_background(node, layer, nodes.size, palette, char) }

          tiles_total = char.bytesize / (TILE_PX * TILE_PX)
          if tiles_total > CHAR_BLOCK_TILES
            raise LoweringError,
                  "the tiled backgrounds use #{tiles_total} tiles together, past the #{CHAR_BLOCK_TILES}-tile " \
                  "limit of one character block — use fewer or shared tiles"
          end
          if palette.size > 256
            raise LoweringError,
                  "the tiled backgrounds use #{palette.size} colors together — the shared background palette holds 256"
          end

          colors = palette.sort_by { |_color, index| index }.map { |color, _index| color }
          @data_blobs[BG_SHARED_PAL] = colors.pack("v*")
          @data_blobs[BG_SHARED_CHAR] = char
          @bg_shared = { pal_units: colors.size, char_units: char.bytesize / 2 }
        end

        # Fold one layer into the shared palette and character block, and build its map.
        # +layer+ is its declaration order, which is also its hardware layer number
        # (BG0, BG1, ...) and decides its paint order: the first declared is the backmost.
        def prepare_one_background(node, layer, count, palette, char)
          name = node[:name]
          tiles = node[:tiles]
          validate_tile_sizes!(name, tiles)
          validate_map_fits!(name, node[:map])

          # Append this layer's tiles after whatever earlier layers put in the shared
          # character block, rewriting each pixel as an index into the shared palette.
          # tile_base is where this layer's first tile lands, so its map points at the
          # right tiles.
          tile_base = char.bytesize / (TILE_PX * TILE_PX)
          tiles.each do |tile|
            pixels = @bitmaps.fetch(tile)[:pixels]
            (TILE_PX * TILE_PX).times do |i|
              color = (pixels.getbyte(i * 2) | (pixels.getbyte((i * 2) + 1) << 8)) & 0x7FFF
              char << (palette[color] ||= palette.size).chr
            end
          end

          # The map: one 16-bit entry per cell in a 32x32 grid, holding the shared-block
          # tile number to draw there (tile_base + the tile's index within this layer).
          # Cells outside the authored map, and blank cells, stay 0 — the shared blank
          # tile, transparent so a layer behind shows through.
          entries = Array.new(MAP_CELLS * MAP_CELLS, 0)
          node[:map].each_with_index do |row, r|
            next if r >= MAP_CELLS

            row.each_with_index do |index, c|
              next if c >= MAP_CELLS || index.nil?

              entries[(r * MAP_CELLS) + c] = tile_base + index
            end
          end

          map_blob = :"__bg_map_#{name}"
          @data_blobs[map_blob] = entries.pack("v*")
          @backgrounds[name] = {
            map: map_blob, map_units: entries.size,
            bg: layer,                           # hardware layer (BG0..BG3), in declaration order
            screen_block: FIRST_MAP_SCREENBLOCK + layer,
            priority: count - 1 - layer,         # first declared is backmost (higher priority number = drawn behind)
          }
        end

        # A tiled background fits one screen block: up to 32x32 tiles (256x256 pixels,
        # already larger than the screen, and it wraps). A bigger map would need the
        # multi-block layouts, so for now it's a friendly build error rather than a
        # silently cropped level. (This is what a "larger maps" slice lifts.)
        def validate_map_fits!(name, map)
          cols = map.map(&:length).max || 0
          rows = map.length
          return if cols <= MAP_CELLS && rows <= MAP_CELLS

          raise LoweringError,
                "background :#{name} is #{cols}x#{rows} tiles, but a tiled background is at most " \
                "#{MAP_CELLS}x#{MAP_CELLS} tiles for now (256x256 pixels, which already scrolls and wraps). " \
                "Use a smaller map, or split the level."
        end

        def validate_tile_sizes!(name, tiles)
          tiles.each do |tile|
            bmp = @bitmaps.fetch(tile) do
              raise LoweringError, "background :#{name} references undefined tile image #{tile.inspect}"
            end
            next if bmp[:width] == TILE_PX && bmp[:height] == TILE_PX

            raise LoweringError,
                  "screen :tiled needs #{TILE_PX}x#{TILE_PX} tiles, but tile #{tile.inspect} is " \
                  "#{bmp[:width]}x#{bmp[:height]} — resize it, or draw this background under screen :bitmap"
          end
        end

        # The picture sizes sprite hardware can draw, each mapped to the two shape/size
        # numbers that describe it. A sprite's image must be one of these; anything
        # else gets a friendly build error listing the choices. (The sizes fall out of
        # how the hardware groups an object's 8x8 tiles into a rectangle.)
        OBJ_SIZES = {
          [8, 8] => [0, 0],  [16, 16] => [0, 1], [32, 32] => [0, 2], [64, 64] => [0, 3],
          [16, 8] => [1, 0], [32, 8] => [1, 1],  [32, 16] => [1, 2], [64, 32] => [1, 3],
          [8, 16] => [2, 0], [8, 32] => [2, 1],  [16, 32] => [2, 2], [32, 64] => [2, 3],
        }.freeze

        # attr0 bit 13: every sprite reads an 8-bit (256-color) palette, the same color
        # model the tiled background uses — so sprite colors are ordinary named colors,
        # no palette banks to think about.
        OBJ_256_COLOR = 0x2000

        # Sprite tile memory: 32KB, holding all the sprites' tile pictures at once.
        OBJ_TILE_CAPACITY = 0x8000

        # Lay all the declared sprites out: one shared color table every sprite indexes
        # into, then each sprite's picture as tiles and its place in the sprite table.
        # Done up front so the addresses exist before the per-frame draw refers to them;
        # the boot upload (emit_boot_objects) and the per-frame draw
        # (emit_present_objects) are the run-time halves.
        #
        # Slots run backwards: the last-declared sprite takes the lowest table slot, and
        # a lower slot draws in front — so a sprite declared later sits on top of one
        # declared earlier, the same front-to-back order the interpreter and the
        # software sprites use. That ordering is fixed at build time, which is what lets
        # hardware sprites hold a stable stack (one reliably in front of another) that
        # software save-under sprites can't.
        def prepare_objects(program)
          nodes = program.walk.select { |node| node.kind == :object }
          if nodes.size > MAX_SPRITES
            raise LoweringError,
                  "#{nodes.size} sprites declared, but the console draws at most #{MAX_SPRITES} at once"
          end
          build_shared_object_palette(nodes)

          tile_unit = 0 # running offset into sprite tile memory, in 32-byte units
          nodes.each_with_index do |node, index|
            prepare_one_object(node, nodes.size - 1 - index, tile_unit)
            tile_unit += @objects[node[:name]][:tile_units]
          end
          return unless tile_unit * 32 > OBJ_TILE_CAPACITY

          raise LoweringError,
                "the sprites' tiles need #{tile_unit * 32} bytes — sprite tile memory holds #{OBJ_TILE_CAPACITY}. " \
                "Use fewer or smaller sprites."
        end

        # Build the one color table every sprite shares (8-bit color has a single
        # 256-entry palette for all sprites). Collect every color used across all the
        # sprite pictures — index 0 reserved for see-through — so each sprite's tiles
        # index into the same table and no sprite's colors overwrite another's.
        def build_shared_object_palette(nodes)
          @obj_palette = {} # 15-bit color -> palette index (1-based; 0 = see-through)
          nodes.each do |node|
            node[:poses].each do |image|
              bmp = @bitmaps.fetch(image) do
                raise LoweringError,
                      "sprite object #{node[:name].inspect} references undefined image #{image.inspect}"
              end
              scan_object_colors(bmp, @obj_palette)
            end
          end
          if @obj_palette.size + 1 > 256
            raise LoweringError,
                  "the sprites use #{@obj_palette.size} colors between them — sprites share one 255-color set " \
                  "(plus see-through)"
          end

          colors = Array.new(@obj_palette.size + 1, 0x0000) # entry 0 = the see-through slot
          @obj_palette.each { |color, index| colors[index] = color }
          @obj_palette_blob = :__obj_palette
          @obj_palette_units = colors.size
          @data_blobs[@obj_palette_blob] = colors.pack("v*")
        end

        # Add every non-see-through color in a sprite picture to the shared palette,
        # each earning the next index the first time it's seen.
        def scan_object_colors(bmp, palette)
          pixels = bmp[:pixels]
          transparent = bmp[:transparent]
          (bmp[:width] * bmp[:height]).times do |i|
            color = pixels.getbyte(i * 2) | (pixels.getbyte((i * 2) + 1) << 8)
            next if transparent && color == transparent

            palette[color & 0x7FFF] ||= palette.size + 1
          end
        end

        def prepare_one_object(node, slot, tile_unit)
          name = node[:name]
          poses = node[:poses]
          width, height = object_pose_size!(name, poses)
          shape, size = OBJ_SIZES.fetch([width, height]) do
            raise LoweringError,
                  "a sprite in screen :tiled must be one of these sizes: " \
                  "#{OBJ_SIZES.keys.map { |w, h| "#{w}x#{h}" }.join(', ')} — sprite #{name.inspect} is " \
                  "#{width}x#{height}. Resize it (sprite pictures are built from 8x8 tiles)."
          end

          # Upload every pose's tiles back to back; the per-frame draw points the
          # sprite at pose k by adding k * (one pose's tile count) to its tile number.
          tiles = poses.each_with_object(+"".b) { |image, bytes| bytes << encode_object_tiles(@bitmaps.fetch(image)) }
          per_pose = (tiles.bytesize / 32) / poses.size # tile-number stride between poses (32-byte units)

          tile_blob = :"__obj_tiles_#{name}"
          @data_blobs[tile_blob] = tiles
          @objects[name] = {
            slot: slot,
            tiles: tile_blob, tile_units: tiles.bytesize / 32, # sprite memory counts in 32-byte units
            tile_index: tile_unit, # this sprite's base tile number
            per_pose: per_pose,    # stride to the next pose's tiles
            pose: node[:pose],     # the run-time pose selector (which pose to show)
            width: width, height: height,
            x: node[:x], y: node[:y], active: node[:active], # the live position/visibility operands
            attr0_base: OBJ_256_COLOR | (shape << 14),
            attr1_base: size << 14,
          }
        end

        # All of a sprite's poses share one size (they swap in place). Confirm that and
        # return it; a size mismatch is a build error rather than a garbled sprite.
        def object_pose_size!(name, poses)
          sizes = poses.map do |image|
            bmp = @bitmaps.fetch(image) # presence already checked while building the palette
            [bmp[:width], bmp[:height]]
          end
          return sizes.first if sizes.uniq.size == 1

          raise LoweringError,
                "sprite #{name.inspect} has poses of different sizes " \
                "(#{sizes.uniq.map { |w, h| "#{w}x#{h}" }.join(', ')}) — a sprite's poses must all be the same size"
        end

        # Pack a sprite's picture into 8-bit tiles the way sprite hardware reads them:
        # 8x8 tiles in reading order (left to right, top to bottom), each tile's 64
        # pixels row by row, every pixel an index into the shared palette. A see-through
        # pixel becomes index 0. Because we use 1D mapping, the tiles simply sit one
        # after another in memory.
        def encode_object_tiles(bmp)
          pixels = bmp[:pixels]
          width = bmp[:width]
          transparent = bmp[:transparent]
          bytes = (+"").b
          (bmp[:height] / TILE_PX).times do |tile_row|
            (width / TILE_PX).times do |tile_col|
              TILE_PX.times do |row|
                TILE_PX.times do |col|
                  i = (((tile_row * TILE_PX) + row) * width) + (tile_col * TILE_PX) + col
                  color = pixels.getbyte(i * 2) | (pixels.getbyte((i * 2) + 1) << 8)
                  index = transparent && color == transparent ? 0 : @obj_palette.fetch(color & 0x7FFF)
                  bytes << index.chr
                end
              end
            end
          end
          bytes
        end

      end
    end
  end
end
