# frozen_string_literal: true

require_relative "gba/emit"
require_relative "gba/lowering"
require_relative "gba/memory"
require_relative "gba/loop_form" # which shape a repeat gets; the cost model asks it too
require_relative "gba/bend_form" # ...and which way a row-by-row bend is lowered, likewise
require_relative "gba/statements"
require_relative "gba/lists"
require_relative "gba/functions"
require_relative "gba/framebuffer"
require_relative "gba/drawing"
require_relative "gba/placement"
require_relative "gba/buffered"
require_relative "gba/audio"
require_relative "gba/reciprocal"
require_relative "gba/divide"
require_relative "gba/expressions"
require_relative "gba/primitives"
require_relative "gba/collision"
require_relative "gba/timers"
require_relative "gba/frames" # how many frames a pass of the game loop really took
require_relative "gba/raster"
require_relative "gba/mixer"
require_relative "gba/save"
require_relative "gba/palette_tint"
require_relative "gba/layer_blend"
require_relative "gba/bios_compress"

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
        include Placement

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
        # What a picture's palette-number form is filed under, beside its colors.
        INDEXED_SUFFIX = "__indexed"
        # ...and where each of its columns holds pixels (see #register_column_runs): the
        # stretches themselves, and where each column's list of them starts.
        #
        # A row number is one byte, so a taller picture ships none — and turning a picture row
        # into a screen row divides by the picture's height, which is a shift only when that
        # height is a power of two, so a picture of another height ships none either. Sprite
        # sheets are square powers of two almost without exception.
        RUNS_SUFFIX = "__runs"
        RUNS_START_SUFFIX = "__runstart"
        RUNS_MAX_ROWS = 256
        # The byte that ends a column's list. No row can be it, because a picture that tall
        # ships no runs at all.
        RUNS_END = 255
        RUNS_MAX_BYTES = 0xFFFF
        DISPCNT_STATE = :__dispcnt
        BACKBUF = :__backbuf

        # When scenes use different screen modes, the framework switches the
        # hardware as each scene takes over. A hidden variable holds which mode is
        # live, so a scene only touches the display registers when the mode actually
        # changes (a transition), not every frame. Direct = single-buffered Mode 3,
        # Buffered = double-buffered Mode 4, Tiled = tile backgrounds + hardware
        # sprites (Mode 0), Affine = the rotate/scale background layer (Mode 2).
        MODE_STATE = :__mode
        MODE_DIRECT = 0
        MODE_BUFFERED = 1
        MODE_TILED = 2
        MODE_AFFINE = 3

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
        STACK = 13 # the stack pointer, for the rare value with nowhere else to wait

        # WHAT THIS BACKEND DECIDED ABOUT AN ASSET, as against what the asset IS (that is
        # IR::Assets, shared with every backend). These are facts about the cartridge and
        # the console, so they mean nothing anywhere else and belong here.

        # A table, once packed into the cartridge: how many elements, how wide each is, and
        # whether the count is a power of two — which decides whether an out-of-range index
        # is wrapped (one instruction) or clamped against both ends.
        TableLayout = Data.define(:count, :elem_bytes, :signed, :pow2)

        # A background, once given hardware to live in: where its map sits, which of the
        # console's layers draws it, and how far forward that layer is. +affine+ marks a
        # `screen :affine` background — its map is one byte per cell (a plain tile
        # number, no flip bits), and it lives on the console's rotate/scale layer (BG2)
        # rather than a plain scrolling one.
        BackgroundPlacement = Data.define(:map, :map_units, :bg, :screen_block, :priority, :affine)

        # Two more scratch registers, live only inside one arithmetic expression and
        # never across a statement. A 64-bit multiply needs both of them, because its
        # answer does not fit in one register.
        SPARE = 2 # somewhere to keep a value while the accumulator is busy
        HIGH = 3  # the top half of a 64-bit product

        # How many bits of fraction the walk down a stretched column keeps. The step is a
        # picture row per screen row and is almost never whole — a wall twice as tall as its
        # picture advances half a row at a time — so it is kept in 65536ths and added, because
        # adding is one instruction and dividing is a subroutine. Both screens walk a column
        # this way, which is what makes them land every pixel in the same place.
        COLUMN_FIXED = 16

        # The registers a stretched column works in, shared by both screens' lowerings so there
        # is one story about them. r4 the screen column, r5 the screen row, r6 how many rows are
        # left, r8 where we are in the picture, r9 how far that moves per screen row, r10 the
        # picture's column. The tear-free screen needs one more, r11, for the address of the
        # 16-bit unit the current row writes into.
        COLUMN_X = 4
        COLUMN_Y = 5
        COLUMN_ROWS = 6
        COLUMN_POS = 8
        COLUMN_STEP = 9
        COLUMN_SRC = 10
        COLUMN_DEST = 11
        # ...and r7 for where the picture's column holds pixels, when it ships that (see
        # #register_column_runs). The walk goes round once per stretch of them.
        COLUMN_RUNS = 7

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

        attr_reader :lowering

        # Each func's byte span in @code (for dump_func) — lives on @functions.
        def func_ranges = @functions.func_ranges

        # The emitted machine code / the label table / where each embedded blob landed
        # — read straight from @emit, which is where they actually live (see {Emit}).
        def code = @emit.code
        def labels = @emit.labels
        def data_positions = @emit.data_positions
        def palette_entries = @palette_tint.palette_entries
        # A test reads a voice's/the mix buffers' state back (see {Mixer}).
        def bitmaps = @bitmaps
        def blob_codecs = @blob_codecs
        def backgrounds = @backgrounds
        # Reached via `drawing: self` by Audio (still, until Drawing exists a few lines
        # into #initialize) and by PaletteTint/LayerBlend (Drawing isn't their own
        # object's collaborator name — this instance stands in), so these have to be
        # public: an explicit-receiver call ignores privacy on the DEFINING class, not
        # on whatever the receiver happens to evaluate to.
        def emit_flip_if_buffered = @drawing.emit_flip_if_buffered
        def fade_steps(percent) = @drawing.fade_steps(percent)
        def fade_steps_value(amount) = @drawing.fade_steps_value(amount)
        def emit_clamp_blend_steps = @drawing.emit_clamp_blend_steps
        def emit_blend_weights_from_acc = @drawing.emit_blend_weights_from_acc
        def emit_plain_dma_blob(blob_name, dest, units) = @drawing.emit_plain_dma_blob(blob_name, dest, units)
        def mix_buf0 = @mixer.mix_buf0
        def mix_buf1 = @mixer.mix_buf1
        def voice_base = @mixer.voice_base

        # +fast_cartridge+ picks the cartridge timing this ROM asks for at boot. True
        # (the default) is the quick timing every real cartridge handles; false leaves
        # the console's cautious power-on timing alone, which is the escape hatch for a
        # cartridge that can't keep up (see #emit_waitcnt_setup).
        # +fast_code+ decides whether the build works out for itself which routines are
        # worth keeping in the console's quick memory (see {Placement}). True is the
        # default; false leaves every routine in the cartridge unless the author asked for
        # one by name with `func :thing, fast: true`.
        def initialize(fast_cartridge: true, fast_code: true)
          @fast_cartridge = fast_cartridge
          @fast_code = fast_code
          @fast_funcs = Set.new  # routines that run from the quick memory
          @emitting_hot = false  # are we emitting into the block that gets copied there?
          @hot_base = nil        # where that block lands, once every variable has a home
          @hot_bytes = 0
          @emit = Emit.new       # the code buffer + two-pass label/fixup machinery
          @memory = Memory.new(start: IWRAM_START) # the IWRAM bump allocator
          @primitives = Primitives.new(emitter: @emit, memory: @memory)
          @divide = Divide.new(emitter: @emit, memory: @memory, primitives: @primitives,
                               scales_objects: method(:object_scales?))
          @frames = Frames.new(emitter: @emit, primitives: @primitives)
          @save = Save.new(emitter: @emit, primitives: @primitives)
          @lowering = Lowering.new # the kind-keyed dispatch that replaces eval_value's case
          @defined_sounds = {}   # name -> musical params (from define_sound)
          @songs = {}            # name -> :song node (from song)
          @blob_codecs = {}      # name -> :lz77/:rle/:none (how a VRAM blob was packed, if at all)
          @blob_raw_bytes = {}   # name -> its size before packing (for the build's savings line)
          @bitmaps = {}          # name -> { width:, height: } (a blob that has a shape)
          @tables = {}           # name -> { count:, elem_bytes:, signed:, pow2: } (a ROM lookup table)
          @backgrounds = {}      # name -> resolved tiled-background layer (map blob, BG number, screen block, priority)
          @run_bitmaps = []      # pictures that ship where each of their columns holds pixels
          @timers = Timers.new(emitter: @emit) # named timer -> which hardware timer(s) back it
          @collision = Collision.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                     bitmaps: @bitmaps)
          @expressions = Expressions.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                         divide: @divide, tables: @tables)
          @lists = Lists.new(memory: @memory, primitives: @primitives, emitter: @emit, lowering: @lowering)
          # `placement: self` — Placement is not its own object yet (see its class
          # comment); its methods live directly on this instance, so handing self in is
          # what makes the dependency an explicit constructor argument instead of a bare
          # cross-file call. `drawing: self` below is the same shape, for the same
          # reason, until @drawing itself exists a few lines down — GBA forwards to it
          # once it does, so the call resolves fine the first time anything actually
          # emits (see the private forwarders).
          @functions = Functions.new(emitter: @emit, lowering: @lowering, placement: self,
                                     scene_preamble: method(:emit_scene_preamble))
          @statements = Statements.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                       placement: self, functions: @functions)
          @framebuffer = Framebuffer.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                         divide: @divide, run_bitmaps: @run_bitmaps)
          @raster = Raster.new(emitter: @emit, primitives: @primitives, memory: @memory,
                               lowering: @lowering, backgrounds: @backgrounds, framebuffer: @framebuffer)
          @mixer = Mixer.new(emitter: @emit, memory: @memory, timers: @timers, primitives: @primitives)
          @audio = Audio.new(emitter: @emit, primitives: @primitives, sounds: @defined_sounds, songs: @songs,
                             frames: @frames, expressions: @expressions, raster: @raster, drawing: self,
                             uses_pressed: -> { @uses_pressed }, any_buffered: -> { @any_buffered })
          @palette_tint = PaletteTint.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                          drawing: self)
          @layer_blend = LayerBlend.new(emitter: @emit, lowering: @lowering, primitives: @primitives,
                                        drawing: self)
          @buffered = Buffered.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                   framebuffer: @framebuffer, call_cold_routine: method(:emit_call_cold_routine))
          @drawing = Drawing.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                 divide: @divide, framebuffer: @framebuffer, raster: @raster,
                                 palette_tint: @palette_tint, layer_blend: @layer_blend, buffered: @buffered,
                                 backing_info: method(:backing_info), fade_targets: method(:fade_targets),
                                 effect_line: method(:effect_line),
                                 call_cold_routine: method(:emit_call_cold_routine))
          # Every value kind's handler, registered once in one place — see {Lowering}.
          @lowering.values(
            int: @expressions.method(:eval_int), var_ref: @expressions.method(:eval_var_ref),
            neg: @expressions.method(:eval_neg), binop: @expressions.method(:eval_binop),
            mul_fix: @expressions.method(:eval_mul_fix), div_fix: @expressions.method(:eval_div_fix),
            shift_right: @expressions.method(:eval_shift_right), held: @expressions.method(:eval_held_node),
            pressed: @expressions.method(:eval_pressed_node), chance: @expressions.method(:eval_chance),
            pixels_overlap: @collision.method(:eval_pixels_overlap),
            data_byte: @expressions.method(:eval_data_byte), table_get: @expressions.method(:eval_table_get),
            list_get: @lists.method(:eval_list_get), list_len: @lists.method(:eval_list_len),
            read_scanline: @expressions.method(:eval_read_scanline), timer_ticks: method(:eval_timer_ticks),
          )
          # Every statement kind's handler, registered once in one place — see {Lowering}.
          # The 12 definition kinds are collected during the definitions pass, earlier in
          # #lower, and emit nothing here — Lowering::NOTHING says so explicitly.
          @lowering.statements(
            func: Lowering::NOTHING, set: @statements.method(:emit_set), add: @statements.method(:emit_add),
            sub: @statements.method(:emit_sub), copy: @statements.method(:emit_copy),
            negate: @statements.method(:emit_negate), abs: @statements.method(:emit_abs),
            negate_abs: @statements.method(:emit_negate_abs), clamp: @statements.method(:emit_clamp),
            save_init: method(:emit_save_init), save_store: method(:emit_save_store),
            if: @statements.method(:emit_if), loop: @statements.method(:emit_loop),
            repeat: @statements.method(:emit_repeat), inside: @statements.method(:emit_inside),
            every: @statements.method(:emit_every), after: @statements.method(:emit_after),
            list_new: @lists.method(:emit_list_new), list_push: @lists.method(:emit_list_push),
            list_drop: @lists.method(:emit_list_drop), list_set: @lists.method(:emit_list_set),
            call: @statements.method(:emit_call), case: @functions.method(:emit_case),
            raw: @statements.method(:emit_raw), halt: @statements.method(:emit_halt),
            wait_vblank: @audio.method(:emit_wait_vblank), screen: @drawing.method(:emit_screen),
            pixel: @drawing.method(:emit_pixel), fill_rect: @drawing.method(:emit_fill_rect),
            clear_screen: @drawing.method(:emit_clear_screen), dma_fill_rect: @drawing.method(:emit_dma_fill_rect),
            draw_rect_at: @drawing.method(:emit_draw_rect_at), draw_column_at: @drawing.method(:emit_draw_column_at),
            draw_text: @drawing.method(:emit_draw_text), draw_digit: @drawing.method(:emit_draw_digit),
            blit: @drawing.method(:emit_blit), blit_pose: @drawing.method(:emit_blit_pose),
            background: @drawing.method(:emit_background), scroll_background: @drawing.method(:emit_scroll_background),
            affine_background: @drawing.method(:emit_affine_background),
            scroll_rows: Lowering::NOTHING, camera: @drawing.method(:emit_camera), fade: @drawing.method(:emit_fade),
            tint: @drawing.method(:emit_tint), see_through: @layer_blend.method(:emit_see_through),
            present_objects: @drawing.method(:emit_present_objects), save_region: @drawing.method(:emit_save_region),
            restore_region: @drawing.method(:emit_restore_region), enable_sound: @audio.method(:emit_enable_sound),
            define_sound: Lowering::NOTHING, song: Lowering::NOTHING, data: Lowering::NOTHING,
            bitmap: Lowering::NOTHING, backing_buffer: Lowering::NOTHING, object: Lowering::NOTHING,
            table: Lowering::NOTHING, layers: Lowering::NOTHING, beep: @audio.method(:emit_beep),
            noise: @audio.method(:emit_noise), wave: @audio.method(:emit_wave),
            stop_wave: @audio.method(:emit_stop_wave),
            play_song: @audio.method(:emit_play_song), stop_music: @audio.method(:emit_stop_music),
            timer_start: method(:emit_timer_start), timer_stop: method(:emit_timer_stop),
            on_timer: Lowering::NOTHING, sample: Lowering::NOTHING, play_sample: @mixer.method(:emit_play_sample),
            stop_sample: @mixer.method(:emit_stop_sample),
          )
          @layer_stack = []      # the layers the program declared, backmost first
          @uses_pressed = false  # whether the program reads edge-detected input
          @palette = nil         # the color table, built once when any scene is buffered
          @indexed_bitmaps = {}  # name -> the number meaning see-through, for pictures drawn indexed
          @modes = nil           # IR::Modes: which screen mode each scene resolves to
          @any_buffered = false  # does any scene use double buffering?
          @mixed_display = false # does the program cross the bitmap/tiled boundary?
          @manage_modes = false  # is the display switched per scene (buffered or mixed)?
          @default_mode = :direct # the boot screen mode (from the top-level `screen`)
          @func_mode = {}        # func name -> :direct | :buffered (resolved from the call graph)
          @scene_funcs = []      # funcs entered per frame, which switch the mode on entry
          @tiled = false         # does the program use tile mode (screen :tiled)?
          @bg_shared = nil       # the one palette + character block every background layer shares
          @has_objects = false   # does the program declare any composited objects (sprites)?
          @objects = {}          # name -> resolved sprite layout (OAM slot, tile/palette blobs)
        end

        # A summary of the asset packing this build did (see BiosCompress::Report),
        # tallied from the blobs that packed and how small they got. Valid after
        # #lower. When nothing packed, the report's `any?` is false and there is no
        # savings line to show.
        def compression_report
          packed = @blob_codecs.select { |_name, codec| codec != :none }
          BiosCompress::Report.new(
            count: packed.size,
            raw_bytes: packed.sum { |name, _codec| @blob_raw_bytes[name] },
            packed_bytes: packed.sum { |name, _codec| @emit.data_blobs[name].bytesize },
            schemes: packed.values.uniq.sort,
          )
        end

        # Lower a program to finished GBA machine code: run the emit pass and
        # resolve the jumps, then return the raw code bytes. Packaging them into a
        # cartridge — header, entry branch, checksum, padding — is ROM.assemble's
        # job; this method knows only how to compile the IR, not how a ROM is laid
        # out.
        # +fast_funcs+ forces the placement decision instead of working it out. Only the
        # throwaway measuring pass inside {Placement}#choose_fast_funcs passes it, so that
        # pass cannot set off another one.
        def lower(program, fast_funcs: nil)
          @fast_funcs = fast_funcs || choose_fast_funcs(program)
          # Which pictures a stretched column reads, which decides whether a see-through one
          # still needs its pixels in the cartridge. Wanted before the assets are registered.
          @column_bitmaps = program.walk.filter_map { |node| node.name if node.kind == :draw_column_at }.uniq
          # First in internal memory, before anything else is given a home there: only a
          # program that divides by something it works out as it runs carries the divide
          # routine, and every other division is settled at build time.
          reserve_divide_routine if needs_divide_routine?(program)
          reserve_divide_fix_routine if needs_divide_fix_routine?(program)
          collect_definitions(program)
          # How the picture stacks: which scenery and sprites there are, in what order,
          # and how deep each sits. Worked out once, before anything is given a hardware
          # slot, because both the background layers and the sprites read the same
          # answer and a slot handed out early cannot be taken back.
          @picture = IR::Stacking.picture(program)
          @layer_blend.picture = @picture # built here, not at construction — see LayerBlend's class comment
          adopt_frame_body(program) # the game loop's body counts as a routine once it moves
          @mixer.prepare_direct_sound(program) # embed the program's samples as ROM data
          @uses_vblank = program.walk.any? { |node| node.kind == :wait_vblank }
          @mixer.prepare_mixer(program) # the software mixer's rate, buffers, voice slots, timer
          guard_mixer_needs_game_loop
          register_timers(program) # assign each named timer its hardware timer index(es)
          prepare_pixel_masks(program) # solid-pixel tables for any per-pixel collision test
          resolve_modes(program)
          # `screen :affine` is tile hardware too — a different pair of layers (BG2/BG3,
          # rotate/scale rather than plain scroll) from `screen :tiled`'s four, but it
          # needs the same shared palette/character-block upload and background lowering,
          # so it counts here alongside :tiled.
          @tiled = program.walk.any? { |node| node.kind == :screen && %i[tiled affine].include?(node.mode) }
          guard_stack_fits if @tiled
          prepare_backgrounds(program) if @tiled
          @raster.register_row_bends(program) # which layers bend row by row (armed at boot, run per line)
          @raster.prepare_row_bends(program)
          @has_objects = program.walk.any? { |node| node.kind == :object }
          prepare_effect_layers(program) # which sprites an effect placed in the stack must skip
          @layer_blend.prepare_layer_blend(program) # ...and which layer, if any, you can see through
          prepare_objects(program) if @has_objects
          @uses_save = program.walk.any? { |node| node.kind == :save_init }
          prepare_palette(program) if @any_buffered
          # The palette layout: settled by now, across several prepare passes above —
          # handed to PaletteTint as one record rather than five ivars (see its class
          # comment).
          @palette_tint.layout = PaletteTint::Layout.new(palette: @palette, bg_shared: @bg_shared,
                                                          obj_palette_blob: @obj_palette_blob,
                                                          obj_palette_units: @obj_palette_units,
                                                          blob_codecs: @blob_codecs)
          @palette_tint.prepare_palette_tint(program)
          @uses_pressed = program.walk.any? { |node| node.kind == :pressed }
          # Everything the prepare passes above decided that Drawing/Buffered read, bundled
          # into one record rather than twenty keyword arguments (see Drawing's class
          # comment) — settled now, so handed over right before the first thing that emits.
          layout = Drawing::Layout.new(
            bitmaps: @bitmaps, objects: @objects, window_twins: @window_twins, backgrounds: @backgrounds,
            bg_shared: @bg_shared, palette: @palette, indexed_bitmaps: @indexed_bitmaps,
            run_bitmaps: @run_bitmaps, blob_codecs: @blob_codecs, blob_raw_bytes: @blob_raw_bytes,
            picture: @picture, modes: @modes, tiled: @tiled, has_objects: @has_objects,
            obj_palette_blob: @obj_palette_blob, obj_palette_units: @obj_palette_units,
            default_mode: @default_mode, any_buffered: @any_buffered, mixed_display: @mixed_display,
            manage_modes: @manage_modes, func_mode: @func_mode,
          )
          @drawing.layout = layout
          @buffered.layout = layout
          # Fast ROM + prefetch, first, unless it's all raw or the caller asked to keep
          # the console's cautious power-on timing.
          emit_waitcnt_setup if @fast_cartridge && !raw_escape_hatch?(program)
          emit_copy_divide_routines_to_iwram # a no-op when neither routine was reserved
          emit_copy_hot_code_to_iwram unless @fast_funcs.empty?
          # THE MIXER IS BROUGHT UP BEFORE THE INTERRUPTS ARE ARMED, and the order is load-bearing
          # rather than tidy. The screen's interrupt builds the next slice of sound (see
          # #emit_irq_handler), and it does that by jumping into a routine that boot copies into
          # the console's quick memory. Armed first, the very first frame can arrive while that
          # copy has not happened — and the jump lands in whatever the memory held at power-on,
          # which never comes back. It bit exactly as a race does: the boot code between the two
          # is where the sound buffers are silenced, so how long it takes depends on the sample
          # rate, and the machine hung above one rate and ran below it with nothing else changed.
          emit_mixer_boot if @mixer.plays_samples? # start the sound DMA + clock; voices added by `play`
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
            emit_boot_layer_blend if @layer_blend.see_through? # ...and which layer you can see through
          end
          # Clear each bending layer's table of row offsets, and start the engine that feeds
          # it to the display. Set up wherever the program starts out, since a bend is fed a
          # table rather than a picture — there is nothing here for a bitmap scene to
          # overwrite.
          emit_boot_row_bends if @raster.latches_row_bends?
          emit_tint_state_init if @palette_tint.palette_tint? # the color tables start as they were drawn
          @lowering.in_mode(@default_mode) do
            program.children.each { |stmt| @lowering.statement(stmt) }
          end
          guard_variables_clear_of_routines
          emit_functions
          emit_hot_functions # the routines worth running from the quick memory, as one block
          # After both: a hot func's body is only ever lowered here, inside
          # emit_hot_functions, so a digit routine a hot func alone reaches would
          # still be unregistered before this if it came any earlier.
          @drawing.emit_digit_routines  # the shared glyph loop each font's draw_number/draw_digit calls
          @buffered.emit_digit_routines # ...and its tear-free counterpart
          emit_mix_routine # the mixer's inner loop, placed in ROM and copied to IWRAM at boot
          emit_divide_routine # likewise the divide routine, for a divisor worked out at run time
          emit_divide_fix_routine # and the one for dividing numbers that hold a fraction
          # The interrupt dispatcher itself, reached only via the vector. When it was worth
          # keeping in the quick memory it has already been emitted inside the moved block.
          emit_irq_handler if uses_irq? && !irq_runs_fast?
          emit_data_region
          emit_save_signature if @uses_save # the marker that maps the save chip (past all code/data)
          # Only now does every variable have a home, so only now is it known where the
          # quick memory's spare room begins — which is where the moved block goes.
          place_hot_code
          # :fast_addr/:hot_size are Placement's own fixup kinds — Emit doesn't know
          # what "the quick memory" or "a DMA transfer's size" mean, so Placement
          # hands its own resolvers in rather than Emit reaching for them by name.
          @emit.resolve_fixups(fast_addr: method(:resolve_fast_address), hot_size: method(:resolve_hot_size))
          @emit.code
        end

        # Each variable's allocated IWRAM address (name => address), known once the
        # program has been lowered. This backend — not the builder — decides where a
        # variable lives, so this is the authoritative map a hardware test uses to
        # read a variable's value back from memory (see RubyGBA::Verifier#var).
        #
        # The cost model reads this too, and the reason is not bookkeeping. Reaching a
        # variable starts by building its address, and how many instructions that takes
        # depends on the address — so two identical statements cost different amounts
        # depending on which variable each touches. Nothing but this build knows where a
        # variable landed: the order is first-touch, a list or a save-under buffer takes
        # its whole size at once, and the framework's own counters and slots are in the
        # queue too. Handing the map over is what lets the estimate price a statement
        # where the variable actually is, instead of reproducing all of that and
        # drifting from it.
        def var_addresses
          @primitives.vars.dup
        end

        # Which shape each loop was given, keyed by its index — whether its counter stayed in
        # a register, and if not, what in the body stopped it. Known once the program has been
        # lowered, because this backend is what decides it, and handed to the cost estimate so
        # that it charges for the loop that will really run (see Statements#emit_repeat).
        def loop_shapes
          @statements.loop_shapes.dup
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
          @functions.modes = @modes
          @palette_tint.modes = @modes
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

        # Forwards to @emit — the code buffer + two-pass label/fixup collaborator built
        # in #initialize. Every other lowering concern in this class calls these as bare
        # methods (see {Emit}).
        def emit(bytes) = @emit.emit(bytes)
        def pos = @emit.pos
        def place_label(name) = @emit.place_label(name)
        def gensym = @emit.gensym
        def emit_branch(kind, target, cond: nil) = @emit.emit_branch(kind, target, cond: cond)
        def emit_data_region = @emit.emit_data_region
        def emit_load_data_address(reg, name) = @emit.emit_load_data_address(reg, name)
        def emit_load_label_address(reg, label) = @emit.emit_load_label_address(reg, label)
        def write_reg16(address, value) = @emit.write_reg16(address, value)

        # Forwards to @timers — the hardware-timer collaborator built in #initialize.
        def register_timers(program) = @timers.register_timers(program)
        def irq_timers = @timers.irq_timers
        def emit_timer_start(node) = @timers.emit_timer_start(node)
        def emit_timer_stop(node) = @timers.emit_timer_stop(node)
        def eval_timer_ticks(node) = @timers.eval_timer_ticks(node)

        # Forwards to @primitives — variable addressing, register stores, constant
        # folding (see {Primitives}).
        def var_addr(name) = @primitives.var_addr(name)
        def load_var(reg, name) = @primitives.load_var(reg, name)
        def store_var(reg, name) = @primitives.store_var(reg, name)
        def var_offset(name) = @primitives.var_offset(name)
        def not_holding(name, &block) = @primitives.not_holding(name, &block)
        def holding(name, reg, &block) = @primitives.holding(name, reg, &block)
        def store_word_acc(address) = @primitives.store_word_acc(address)
        def store_halfword_acc(address) = @primitives.store_halfword_acc(address)
        def store_word_immediate(value, address) = @primitives.store_word_immediate(value, address)
        def const_int(node) = @primitives.const_int(node)
        def constant_ints!(node, **sides) = @primitives.constant_ints!(node, **sides)
        def emit_row_loop(counter, &block) = @primitives.emit_row_loop(counter, &block)
        def emit_add_const(rd, rn, imm, scratch) = @primitives.emit_add_const(rd, rn, imm, scratch)
        def emit_and_const(rd, rn, imm, scratch) = @primitives.emit_and_const(rd, rn, imm, scratch)

        # Forwards to @divide (see {Divide}).
        def needs_divide_routine?(program) = @divide.needs_divide_routine?(program)
        def needs_divide_fix_routine?(program) = @divide.needs_divide_fix_routine?(program)
        def reserve_divide_routine = @divide.reserve_divide_routine
        def reserve_divide_fix_routine = @divide.reserve_divide_fix_routine
        def guard_variables_clear_of_routines = @divide.guard_variables_clear_of_routines
        def emit_copy_divide_routines_to_iwram = @divide.emit_copy_divide_routines_to_iwram
        def emit_divide_routine = @divide.emit_divide_routine
        def emit_divide_fix_routine = @divide.emit_divide_fix_routine
        def emit_call_divide_routine = @divide.emit_call_divide_routine

        # Forwards to @lists (see {Lists}).
        def backing_info(name) = @lists.backing_info(name)

        # Forwards to @functions (see {Functions}).
        def emit_functions = @functions.emit_functions

        # Forwards to @expressions (see {Expressions}).
        def emit_input_init = @expressions.emit_input_init

        # Forwards to @collision (see {Collision}).
        def prepare_pixel_masks(program) = @collision.prepare_pixel_masks(program)

        # Forwards to @frames and @save — both stateless (see {Frames}, {Save}).
        def emit_frame_count = @frames.emit_frame_count
        def emit_frame_step = @frames.emit_frame_step
        def emit_save_init(node) = @save.emit_save_init(node)
        def emit_save_store(node) = @save.emit_save_store(node)
        def emit_save_signature = @save.emit_save_signature

        # Forwards to @raster (see {Raster}).
        def emit_boot_row_bends = @raster.emit_boot_row_bends
        def emit_row_bend_handler = @raster.emit_row_bend_handler
        def interrupts_rows? = @raster.interrupts_rows?

        # Forwards to @mixer (see {Mixer}) — the whole sampled-audio picture, from
        # registering samples as ROM data to mixing and playing them.
        def emit_mixer_boot = @mixer.emit_mixer_boot
        def emit_mixer_tick = @mixer.emit_mixer_tick
        def emit_mix_routine = @mixer.emit_mix_routine

        # Forwards to @palette_tint (see {PaletteTint}).
        def palette_tint? = @palette_tint.palette_tint?
        def emit_tint_state_init = @palette_tint.emit_tint_state_init

        # Forwards to @layer_blend (see {LayerBlend}).
        def see_through_object?(node) = @layer_blend.see_through_object?(node)
        def emit_boot_layer_blend = @layer_blend.emit_boot_layer_blend

        # Forwards to @drawing (see {Drawing}) — the boot/frame/IRQ entry points #lower
        # and #emit_irq_handler call directly, rather than through the Lowering table.
        def emit_boot_screen = @drawing.emit_boot_screen
        def emit_boot_backgrounds = @drawing.emit_boot_backgrounds
        def emit_boot_objects = @drawing.emit_boot_objects
        def emit_scene_preamble(name) = @drawing.emit_scene_preamble(name)

        # Does the program need any interrupt at all — VBlank (for wait_vblank) or a timer
        # (for an on_tick handler)? The mixer needs none: it refills on the frame loop, in
        # the main thread, not off an interrupt.
        def uses_irq?
          @uses_vblank || irq_timers.any? || interrupts_rows?
        end

        # Playing samples means the mixer, and the mixer refills once per frame right after
        # wait_vblank — so a program that plays sound without a game loop would fill its
        # buffer once and then go silent. Catch that as a friendly build error.
        def guard_mixer_needs_game_loop
          return unless @mixer.plays_samples? && !@uses_vblank

          raise LoweringError,
                "this program plays samples but never waits for vblank, so the sound mixer has no " \
                "frame to refill on — play sound from inside a `game_loop` (with `wait_vblank`)."
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
        # Speed the cartridge up before running any code. The console powers on with
        # the slowest, safest ROM wait-states (so any cartridge works), which makes
        # code fetched from the .gba crawl. We write REG_WAITCNT once, as the very
        # first instruction, to pick fast timing (WS0 3/1) and switch on the prefetch
        # buffer — the unit that reads upcoming instructions from ROM ahead of the CPU.
        # Everything after it — the rest of boot, and the whole game — benefits.
        #
        # Measured on the emulator's timing model, per frame of real game code: the
        # raycaster's 224 scanlines of CPU become 133, breakout's 113 become 71, snake's
        # 108 become 62. Call it a third off, and more on ROM-heavy code. That is why it
        # is on by default. It's a timing SETTING, not a guarantee — it is what real
        # cartridges and mainstream flash carts are specified for, but a cartridge that
        # can't keep up would misbehave, so `fast_cartridge: false` leaves the cautious
        # power-on timing alone. (This is a hardware-timing concern, so it lives only in
        # this backend — the reference interpreter models behaviour, not cycles, and the
        # cost model prices timing separately.)
        def emit_waitcnt_setup
          write_io_halfword(REG_WAITCNT, WAITCNT_FAST)
        end

        # A program made only of `raw`/`entry` blocks is the escape hatch: the user is
        # writing the ROM's instructions themselves, so the framework injects nothing
        # (not even the wait-state setup) — their first instruction is the entry point,
        # and they can set REG_WAITCNT themselves if they want it.
        def raw_escape_hatch?(program)
          !program.children.empty? && program.children.all? { |node| node.kind == :raw }
        end

        def emit_irq_setup
          enabled = 0
          enabled |= IRQ_VBLANK if @uses_vblank
          enabled |= IRQ_HBLANK if interrupts_rows?
          irq_timers.each { |_, info| enabled |= timer_irq_bit(info[:rate]) }

          # Which moments the display announces: the gap between frames (so wait_vblank
          # can sleep until one), and the gap after every line it draws (so a bending
          # background answered per line can move before the next one). A bend fed by the
          # copier needs neither — the engine acts on the line-end by itself, with nobody
          # to tell.
          announce = 0
          announce |= DISPSTAT_VBLANK_IRQ if @uses_vblank
          announce |= DISPSTAT_HBLANK_IRQ if interrupts_rows?

          write_io_halfword(REG_IME, 0)                          # interrupts off while we wire things up
          write_io_halfword(REG_DISPSTAT, announce) unless announce.zero?
          write_io_halfword(REG_IE, enabled)                     # listen for exactly these interrupts
          emit(ASM.load_immediate(TMP, REG_INTR_VECTOR))         # the vector the BIOS reads on every interrupt
          # ...store our dispatcher's address there. It runs from wherever its bytes ended
          # up, and by this point the copy into the quick memory has already happened, so a
          # dispatcher that moved is pointed at its home there rather than the cartridge.
          if irq_runs_fast?
            emit_load_fast_address(ACC, IRQ_HANDLER_LABEL)
          else
            emit_load_label_address(ACC, IRQ_HANDLER_LABEL)
          end
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
          start = pos
          place_label(IRQ_HANDLER_LABEL)
          emit(ASM.push(*IRQ_SAVED_REGS))
          # A bending background is checked FIRST because it fires by far the most often —
          # once for every line the display draws, against once a frame for everything
          # else. Every check ahead of it would be paid 228 times a frame.
          emit_irq_source(IRQ_HBLANK) { emit_row_bend_handler } if interrupts_rows?
          # VBlank must ack in TWO places — the hardware flag (REG_IF) and the BIOS's own
          # copy (REG_IFBIOS) that VBlankIntrWait polls — or the CPU would never wake.
          # ...and the screen's own frame, whose handler used to be nothing but the ack. Two
          # things ride on it now, and both for the same reason: THE SCREEN KEEPS TIME WHATEVER
          # THE GAME IS DOING. It counts frames, which is what lets a pass of the game loop know
          # how many of them it took; and it builds the next slice of sound, because a sixtieth
          # of a second of sound is a fact about the display and not about how long the game
          # took to think. A game whose pass spans two frames comes round here twice, and gets
          # two slices — see Mixer#emit_mixer_tick for what went wrong when it did not.
          emit_irq_source(IRQ_VBLANK, bios_ack: true) do
            emit_frame_count
            emit_mixer_tick if @mixer.plays_samples?
          end if @uses_vblank
          irq_timers.each do |_, info|
            emit_irq_source(timer_irq_bit(info[:rate])) do
              info[:handler].children.each { |child| @lowering.statement(child) }
            end
          end
          emit(ASM.pop(*IRQ_SAVED_REGS))
          emit(ASM.return) # BX LR back to the BIOS dispatcher
          # Its byte span, so the build can weigh keeping it in the quick memory against
          # everything else that wants the room (see Placement#IRQ_ROUTINE).
          @functions.func_ranges[Placement::IRQ_ROUTINE] = (start...pos)
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
              @functions.funcs[node.name] = node
            when :define_sound
              @defined_sounds[node.name] = {
                frequency: node.frequency, duty: node.duty,
                decay: node.decay, volume: node.volume
              }
            when :song
              @songs[node.name] = node
            when :table
              register_table(node)
            when :data
              @emit.data_blobs[node.name] = node.bytes
            when :bitmap
              @bitmaps[node.name] = Assets::Image.of(node)
              # An opaque bitmap streams from ROM via DMA, so embed its pixels. A
              # transparent one is drawn pixel-by-pixel with its colors baked into
              # the code (letting transparent pixels be skipped), so it needs no
              # ROM copy.
              # ...and a see-through one is normally drawn pixel by pixel with its colors baked
              # into the code, so it needs no copy — unless a stretched column reads it, which
              # walks the picture as it runs and so needs it there. A scaled sprite in a
              # first-person view is exactly that case.
              @emit.data_blobs[node.name] = node.pixels if !node.transparent || @column_bitmaps.include?(node.name)
              register_column_runs(node)
            when :list_new
              # Reserve the list's IWRAM storage once, up front, so every op that
              # touches it (anywhere in the tree, including funcs emitted later)
              # already knows its base address and capacity. list_new *executing*
              # only resets it to empty; the storage itself is allocated here.
              @lists.register_list(node.name, node.capacity)
            when :backing_buffer
              # Reserve the save-under patch's RAM once, up front, so a save/restore
              # anywhere in the tree already knows its address. Nothing is emitted
              # when the declaration is reached inline — it's pure reservation.
              @lists.register_backing(node.name, node.width, node.height)
            when :layers
              # The stack of depths the picture is built from, backmost first. Things
              # name a layer wherever they're declared, so the order has to be known
              # before any of them is placed.
              @layer_stack = node.names
            end
          end
        end

        # Element size in bytes for each table width, and the Array#pack directive that
        # writes that many bytes little-endian. Packing signed keeps negatives as two's
        # complement; pack takes the low bytes, so the same directive serves an unsigned
        # table too (the read, ldrb/ldrh vs ldrsb/ldrsh, is what restores the sign).
        TABLE_ELEM = { byte: [1, "c*"], half: [2, "s<*"], word: [4, "l<*"] }.freeze

        # Embed a table's values as a ROM blob and remember its shape, so a table_get
        # can index it. A power-of-two length lets the read wrap with a cheap mask.
        def register_table(node)
          elem_bytes, directive = TABLE_ELEM.fetch(node.width)
          @emit.data_blobs[node.name] = node.values.pack(directive)
          count = node.values.length
          @tables[node.name] = TableLayout.new(
            count: count, elem_bytes: elem_bytes, signed: node.signed,
            pow2: count.positive? && (count & (count - 1)).zero?
          )
        end

        # Build the double-buffer color table and stash it as a ROM blob to be
        # uploaded at startup. Mode 4's screen stores a small index per pixel that
        # picks a color out of this table, so the table has to exist before anything
        # is drawn. Only the buffered scenes feed it — a direct-color scene stores
        # full colors per pixel and needs no slot — so its colors can't crowd the
        # 256-entry table (see IR::Palette::Overflow for the friendly limit error).
        def prepare_palette(program)
          @palette = IR::Palette.build(program, scopes: @modes.buffered_scopes)
          @emit.data_blobs[PALETTE_BLOB] = @palette.entries.pack("v*") # 15-bit entries, little-endian
          prepare_indexed_bitmaps(program)
        end

        # The indexed screen holds a NUMBER per pixel where a picture holds a whole color, so a
        # picture needs a second form before anything can draw it there. Built here, once, and
        # shipped beside the picture's colors.
        #
        # Only the pictures a tear-free scene actually draws: a program that never uses one
        # ships nothing extra, and a picture used only on a direct-color scene stays as it was.
        # Every picture the program declares, once it has a tear-free scene at all — rather than
        # only the ones such a scene draws. Narrowing it to what is drawn would mean naming the
        # verbs that draw a picture, and a program that draws none would then ship nothing, which
        # is the whole set today: no verb can put a picture on this screen yet. Narrow it when
        # there is something to narrow against.
        def prepare_indexed_bitmaps(program)
          program.walk do |node|
            next unless node.kind == :bitmap

            bytes, clear = @palette.indices_for(node)
            @emit.data_blobs[indexed_blob(node.name)] = bytes
            @indexed_bitmaps[node.name] = clear
          end
        end

        def indexed_blob(name) = :"#{name}#{INDEXED_SUFFIX}"
        def runs_blob(name) = :"#{name}#{RUNS_SUFFIX}"
        def runs_start_blob(name) = :"#{name}#{RUNS_START_SUFFIX}"

        # WHERE EACH COLUMN OF A SEE-THROUGH PICTURE HOLDS PIXELS, as the stretches of rows
        # that hold them.
        #
        # A stretched column walks down the screen asking each row for a pixel, and for a
        # picture that is mostly see-through most of those rows answer "nothing here". A
        # scaled sprite is exactly that: a lamp, a barrel, a clip of ammunition, each in the
        # middle of a square of see-through. Knowing the stretches, the walk goes round once
        # per stretch and never asks a row that cannot answer.
        #
        # THE STRETCHES AND NOT JUST THE FIRST AND LAST. A thing lying on the floor holds its
        # pixels in the bottom sixth of its column and one band would catch that — but a lamp
        # that hangs holds them at the TOP of its column and at the bottom, with the ceiling
        # between, and the gap in the middle is where a player standing under it is looking.
        # Measured on a real floor: the first-and-last band leaves 30 rows walked in every
        # hundred, and the stretches leave 17.
        #
        # A column that holds nothing at all gets an empty list, so it walks no rows.
        def register_column_runs(node)
          return unless node.transparent && @column_bitmaps.include?(node.name)
          return unless node.height <= RUNS_MAX_ROWS && power_of_two?(node.height)

          runs = column_runs(node)
          starts = []
          at = 0
          runs.each do |column|
            starts << at
            at += (column.length * 2) + 1 # a pair of rows each, then the byte that ends the list
          end
          # Where a column's list starts is a halfword, so a picture whose lists together run
          # past that ships none and walks its whole height, as it always did.
          return if at > RUNS_MAX_BYTES

          @emit.data_blobs[runs_blob(node.name)] =
            runs.flat_map { |column| column.flat_map { |run| [run.first, run.last] } << RUNS_END }
                .pack("C*")
          @emit.data_blobs[runs_start_blob(node.name)] = starts.pack("v*")
          @run_bitmaps << node.name
        end

        def power_of_two?(number) = number.positive? && (number & (number - 1)).zero?

        def column_runs(node)
          pixels = node.pixels.unpack("v*")
          (0...node.width).map do |x|
            rows = (0...node.height).select { |y| pixels[(y * node.width) + x] != node.transparent }
            rows.slice_when { |a, b| b != a + 1 }.map { |run| [run.first, run.last] }
          end
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
          # Back to front. A layer can put a background behind one declared before it,
          # and this order becomes the hardware layer number, which IS the paint order —
          # so it has to be settled here, before any layer is given a number.
          #
          # A `screen :affine` background lives on its own rotate/scale layer (BG2) —
          # a different pair of hardware layers from the four `screen :tiled` scrolls on
          # — so it's set aside from the regular stack rather than counted against it.
          nodes = @picture.scenery
          affine_nodes, regular_nodes = nodes.partition(&:affine)

          if affine_nodes.size > 1
            raise LoweringError,
                  "#{affine_nodes.size} affine backgrounds were declared " \
                  "(#{affine_nodes.map { |n| ":#{n.name}" }.join(', ')}), but only one can turn or " \
                  "resize on this console right now — keep one."
          end

          if regular_nodes.size > MAX_BG_LAYERS
            raise LoweringError,
                  "#{regular_nodes.size} background layers were declared, but the console stacks #{MAX_BG_LAYERS} " \
                  "tiled layers (BG0-BG3) — use at most #{MAX_BG_LAYERS} backgrounds"
          end

          # Seed the shared palette with the transparent backdrop at index 0, and the
          # shared character block with a blank tile 0 (all index 0), so an empty map cell
          # points at a see-through tile and layers behind it show through.
          palette = { 0x0000 => 0 }
          char = (+"").b << ("\x00" * (TILE_PX * TILE_PX)).b
          regular_nodes.each_with_index { |node, layer| prepare_one_background(node, layer, palette, char) }
          affine_nodes.each { |node| prepare_affine_background(node, palette, char) }

          tiles_total = char.bytesize / (TILE_PX * TILE_PX)
          if tiles_total > CHAR_BLOCK_TILES
            raise LoweringError,
                  "the tiled backgrounds use #{tiles_total} tiles together, past the #{CHAR_BLOCK_TILES}-tile " \
                  "limit of one character block — use fewer or shared tiles"
          end

          colors = palette.sort_by { |_color, index| index }.map { |color, _index| color }
          @emit.data_blobs[BG_SHARED_PAL] = colors.pack("v*")
          @emit.data_blobs[BG_SHARED_CHAR] = char
          @bg_shared = { pal_units: colors.size, char_units: char.bytesize / 2 }
        end

        # Fold one layer into the shared palette and character block, and build its map.
        # +layer+ is its place in the stack, which is also its hardware layer number
        # (BG0, BG1, ...). What decides its paint order is the priority below.
        def prepare_one_background(node, layer, palette, char)
          name = node.name
          tiles = node.tiles
          validate_tile_sizes!(name, tiles)
          validate_map_fits!(name, node.map)

          # Append this layer's tiles after whatever earlier layers put in the shared
          # character block, rewriting each pixel as an index into the shared palette.
          # tile_base is where this layer's first tile lands, so its map points at the
          # right tiles.
          tile_base = char.bytesize / (TILE_PX * TILE_PX)
          tiles.each do |tile|
            pixels = @bitmaps.fetch(tile).pixels
            (TILE_PX * TILE_PX).times do |i|
              color = (pixels.getbyte(i * 2) | (pixels.getbyte((i * 2) + 1) << 8)) & 0x7FFF
              char << shared_palette_index(palette, color).chr
            end
          end

          # The map: one 16-bit entry per cell in a 32x32 grid, holding the shared-block
          # tile number to draw there (tile_base + the tile's index within this layer).
          # Cells outside the authored map, and blank cells, stay 0 — the shared blank
          # tile, transparent so a layer behind shows through.
          entries = Array.new(MAP_CELLS * MAP_CELLS, 0)
          node.map.each_with_index do |row, r|
            next if r >= MAP_CELLS

            row.each_with_index do |index, c|
              next if c >= MAP_CELLS || index.nil?

              entries[(r * MAP_CELLS) + c] = tile_base + index
            end
          end

          map_blob = :"__bg_map_#{name}"
          @emit.data_blobs[map_blob] = entries.pack("v*")
          @backgrounds[name] = BackgroundPlacement.new(
            map: map_blob, map_units: entries.size,
            bg: layer,                           # hardware layer (BG0..BG3), in stack order
            screen_block: FIRST_MAP_SCREENBLOCK + layer,
            priority: hardware_priority(name),
            affine: false
          )
        end

        # The hardware layer a `screen :affine` background always lives on — the console
        # gives rotate/scale hardware to exactly BG2 and BG3, and this feature uses one of
        # them (see the "only one affine background" check above).
        AFFINE_BG = 2

        # Fold an affine background's tiles into the shared character block (same as a
        # regular one) but build its MAP differently: one byte per cell, not two, because
        # the console's rotate/scale layer reads a plain tile number with no flip bits —
        # so it can name only 256 tiles, not the 1024 a regular layer's map can.
        def prepare_affine_background(node, palette, char)
          name = node.name
          tiles = node.tiles
          validate_tile_sizes!(name, tiles)
          validate_map_fits!(name, node.map)

          # The same shared sine table a turning sprite reads (see #prepare_affine) —
          # baked in here too, since a program can turn a background without ever
          # turning a sprite.
          @emit.data_blobs[OBJ_SINE_BLOB] ||= build_sine_table

          tile_base = char.bytesize / (TILE_PX * TILE_PX)
          tiles.each do |tile|
            pixels = @bitmaps.fetch(tile).pixels
            (TILE_PX * TILE_PX).times do |i|
              color = (pixels.getbyte(i * 2) | (pixels.getbyte((i * 2) + 1) << 8)) & 0x7FFF
              char << shared_palette_index(palette, color).chr
            end
          end

          if tile_base + tiles.size > AFFINE_MAX_TILES
            raise LoweringError,
                  "background :#{name} is affine (`screen :affine`), so its map can only name " \
                  "#{AFFINE_MAX_TILES} tiles — one byte per cell, no room for more. It uses " \
                  "#{tile_base + tiles.size} tiles together with any other background sharing its tile set. " \
                  "Use fewer distinct tiles."
          end

          entries = Array.new(MAP_CELLS * MAP_CELLS, 0)
          node.map.each_with_index do |row, r|
            next if r >= MAP_CELLS

            row.each_with_index do |index, c|
              next if c >= MAP_CELLS || index.nil?

              entries[(r * MAP_CELLS) + c] = tile_base + index
            end
          end

          map_blob = :"__bg_map_#{name}"
          @emit.data_blobs[map_blob] = entries.pack("C*")
          @backgrounds[name] = BackgroundPlacement.new(
            map: map_blob, map_units: entries.size / 2, # DMA copies halfwords, so a byte map is half as many
            bg: AFFINE_BG,
            screen_block: FIRST_MAP_SCREENBLOCK,
            priority: hardware_priority(name),
            affine: true
          )
        end

        AFFINE_MAX_TILES = 256

        # The console keeps four levels of depth, and a picture can ask for more of them
        # than that. Say so in the author's own layer names — the number this refuses is
        # a hardware fact, but "BG2" is not a thing anybody wrote.
        #
        # There are only two ways to run out, so the message names the one that happened
        # rather than listing both: too much scenery, or a layer of sprites sitting
        # behind every piece of it (which needs a level of its own, above the lot).
        MAX_LEVELS = 4

        def guard_stack_fits
          needed = @picture.depths.count
          return if needed <= MAX_LEVELS || @picture.stack.empty?

          raise LoweringError,
                "This picture needs #{needed} levels of depth and the console stacks #{MAX_LEVELS}. " \
                "#{stack_overflow_cause}\n" \
                "The stack is #{@picture.stack.map { |name| ":#{name}" }.join(', ')}, back to front."
        end

        # Which of the two ways it ran out, and what to do about that one.
        def stack_overflow_cause
          backmost = @picture.objects.select { |node| @picture.depths[node.name].zero? }
          if backmost.any? && @picture.scenery.none? { |node| @picture.depths[node.name].zero? }
            behind = backmost.map(&:layer).uniq.compact
            "The sprites in #{behind.map { |name| ":#{name}" }.join(', ')} sit behind every background, " \
              "which takes a level of its own. To fix this, move that layer in front of one background, " \
              "or use one background less."
          else
            "Each background takes a level, and the sprites in front of it share that level. " \
              "To fix this, use fewer backgrounds."
          end
        end

        # What the console's stacking hardware is told about how deep a thing sits.
        #
        # It counts the other way round from the picture: 0 is the FRONT and 3 the back,
        # and there are only four of them. So the levels the picture needs are flipped
        # onto that scale, deepest first. Several named layers can land on one number,
        # which is the point — the console has more layers than it has priorities, and
        # it can already tell apart what shares one (a sprite is drawn over a background
        # of the same priority, and two sprites keep their table order).
        def hardware_priority(name)
          @picture.depths.count - 1 - @picture.depths[name]
        end

        # This color's slot in the shared background palette, adding it if it's new.
        #
        # Every tiled layer draws from one 256-color palette, and a tile pixel is a
        # single byte holding an index into it. So the 257th distinct color has no
        # index that fits in a pixel. The check belongs here, at the moment a color is
        # added, because the very next thing the caller does is pack the index into a
        # byte — past 255 that is a raw range error from deep inside the packing, which
        # tells the developer nothing.
        SHARED_PALETTE_COLORS = 256
        def shared_palette_index(palette, color)
          index = palette[color]
          return index if index

          if palette.size >= SHARED_PALETTE_COLORS
            raise LoweringError,
                  "the tiled backgrounds use more than #{SHARED_PALETTE_COLORS} colors together. " \
                  "All tiled layers share one palette of #{SHARED_PALETTE_COLORS} colors. " \
                  "To fix this, use fewer different colors in your tile images."
          end

          palette[color] = palette.size
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
            next if bmp.width == TILE_PX && bmp.height == TILE_PX

            raise LoweringError,
                  "screen :tiled needs #{TILE_PX}x#{TILE_PX} tiles, but tile #{tile.inspect} is " \
                  "#{bmp.width}x#{bmp.height} — resize it, or draw this background under screen :bitmap"
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

        # attr2 bits 10-11: how deep this sprite sits, on the console's own scale where 0
        # is the front. A sprite is drawn over a background holding the SAME number, which
        # is what lets a picture put scenery in front of one sprite and behind another
        # without spending a number on each.
        OBJ_PRIORITY_SHIFT = 10

        # Sprite tile memory: 32KB, holding all the sprites' tile pictures at once.
        OBJ_TILE_CAPACITY = 0x8000

        # Turning sprites (see #prepare_affine). The console applies a rotation to a
        # sprite through one of 32 shared "affine" parameter groups, so at most 32
        # sprites can turn at once. To rotate, a sprite points at a group; each frame we
        # fill that group with a rotation matrix built from the angle.
        MAX_AFFINE_GROUPS = 32

        # A sine lookup table baked into ROM, so the matrix math costs a memory read
        # rather than a per-frame sine. Entry d is sin(d°) in 8.8 fixed point (256 =
        # 1.0). It runs to 449°, not 359°, so cosine — sin(angle + 90) — is a straight
        # read at angle + 90 with no wrap, for any angle the DSL keeps in 0..359.
        OBJ_SINE_BLOB = :__obj_sine
        OBJ_SINE_ENTRIES = 450

        # Lay all the declared sprites out: one shared color table every sprite indexes
        # into, then each sprite's picture as tiles and its place in the sprite table.
        # Done up front so the addresses exist before the per-frame draw refers to them;
        # the boot upload (emit_boot_objects) and the per-frame draw
        # (emit_present_objects) are the run-time halves.
        #
        # Slots run backwards: the sprite drawn last takes the lowest table slot, and a
        # lower slot draws in front — so the last one in the frame's draw order sits on
        # top, the same front-to-back order the interpreter and the software sprites
        # use. That ordering is fixed at build time, which is what lets hardware sprites
        # hold a stable stack (one reliably in front of another) that software
        # save-under sprites can't.
        #
        # The order comes from the frame's own draw list, not from where the sprites
        # happen to sit in the tree. The two are usually the same and are not always:
        # a HUD is drawn after the game whatever order it was written in, and a layer
        # can put a sprite in front of one declared later. Reading the list the frame
        # actually draws is what keeps this console agreeing with every other backend
        # about which sprite is on top.
        def prepare_objects(program)
          nodes = @picture.objects
          if nodes.size > MAX_SPRITES
            raise LoweringError,
                  "#{nodes.size} sprites declared, but the console draws at most #{MAX_SPRITES} at once"
          end
          guard_window_twins_fit(nodes)
          build_shared_object_palette(nodes)

          # The window twins take the front slots and every real sprite moves back by as
          # many, which changes nothing about what is in front of what (a twin paints
          # nothing, and the sprites keep their order among themselves). It has to be
          # this way round: a twin only holds the effect off a sprite that is BEHIND it.
          front = @window_twins.size
          tile_unit = 0 # running offset into sprite tile memory, in 32-byte units
          nodes.each_with_index do |node, index|
            prepare_one_object(node, front + nodes.size - 1 - index, tile_unit)
            tile_unit += @objects[node.name][:tile_units]
          end
          prepare_affine(nodes)
          return unless tile_unit * 32 > OBJ_TILE_CAPACITY

          raise LoweringError,
                "the sprites' tiles need #{tile_unit * 32} bytes — sprite tile memory holds #{OBJ_TILE_CAPACITY}. " \
                "Use fewer or smaller sprites."
        end

        # Set up the sprites that turn or change size. Each is given one of the console's
        # 32 rotation/size parameter groups (its "affine slot"), and the shared sine
        # table is baked into ROM once. A sprite that does neither keeps its default
        # upright, drawn-size settings and gets no slot, so it costs nothing. More than
        # 32 is a friendly error — the hardware simply has no more groups.
        def prepare_affine(nodes)
          transformed = nodes.select { |node| object_transformed?(node) }
          return if transformed.empty?

          if transformed.size > MAX_AFFINE_GROUPS
            raise LoweringError,
                  "#{transformed.size} sprites turn or change size, but the console can do that to at " \
                  "most #{MAX_AFFINE_GROUPS} at once. Turn or resize fewer sprites at the same time."
          end
          transformed.each_with_index { |node, group| @objects[node.name][:affine_slot] = group }
          @emit.data_blobs[OBJ_SINE_BLOB] = build_sine_table
        end

        # Does this object turn or change size? It does unless BOTH its angle and its
        # size are still the constants they default to. Either one being a variable (or
        # any other constant) means it goes through an affine slot; both at their
        # defaults draws upright at its drawn size, for free.
        def object_transformed?(node)
          object_rotates?(node) || object_scales?(node)
        end

        def object_rotates?(node)
          value = const_int(node.angle)
          value.nil? || !value.zero?
        end

        def object_scales?(node)
          const_int(node.scale) != Build::SCALE_ONE
        end

        # The sine lookup table as ROM bytes: sin(d°) in 8.8 fixed point for d in
        # 0..449, each a signed 16-bit little-endian value (256 = 1.0, -256 = -1.0).
        # Built from the same helper the reference interpreter reads, so the two cannot
        # turn a sprite through different numbers.
        def build_sine_table
          (0...OBJ_SINE_ENTRIES).map { |degrees| Affine.sine(degrees) }.pack("s<*")
        end

        # --- an effect placed in the stack ---
        #
        # `fade :black, 100, under: :ui` blends what is behind :ui and leaves :ui and
        # everything in front of it alone. The console has two ways to say that, and the
        # asymmetry between them is what shapes all of this:
        #
        #   * The blend register names each background layer with a bit of its own, so
        #     scenery on the kept side simply stays out of the mask. Free.
        #   * It names every sprite on screen with ONE bit. So a line drawn between two
        #     sprites cannot be said there at all — and a HUD is sprites, which makes
        #     that the case the whole feature exists for.
        #
        # The way through is the OBJECT WINDOW. A sprite can be drawn as a window instead
        # of a picture: it paints nothing, and where its pixels would have been the color
        # effect is turned off. The region is the shape of the pixels it paints and not
        # its box, which is what makes it usable for a letter. So each kept sprite gets a
        # twin drawn that way, and the fade goes around the sprite.
        #
        # A twin costs one sprite slot and one table write a frame, so they are made only
        # where they are the only answer: a fade that keeps EVERY sprite leaves the OBJ
        # bit out of the mask instead, and costs nothing at all.
        EFFECT_LINE = :__effect_line # where in the stack the fade now in force is sitting
        OBJ_WINDOW_MODE = 0x0800     # attr0 bits 10-11 = 2: a window rather than a picture
        OBJ_WINDOW_ENABLE = 0x8000   # DISPCNT bit 15: the object window is on

        # Which sprites need a window twin, and for each one which table slot it takes and
        # when it shows. Worked out from every fade the program places, before any sprite
        # is given a slot, because the twins take the front ones (see #prepare_objects).
        #
        # A twin is a RIDER on its sprite rather than a second sprite to work out. Where it
        # is, which pose it holds and how big it is are all the same numbers, so the frame
        # writes them once and drops a copy into the twin's slot on the way past (see
        # Drawing#emit_present_object) — which is what keeps a HUD held out of a fade from
        # costing as much again as the HUD.
        #
        # Its gate is where the fade in force is sitting: EFFECT_LINE against this sprite's
        # place in the stack. So a program that also fades the whole screen somewhere else
        # puts the twins away for that one, and the HUD goes down with the game — which is
        # what a whole-screen fade means.
        #
        # Nothing to do — and not one emitted byte different — for a program that places no
        # fade, which is every program that names no layers.
        def prepare_effect_layers(program)
          @window_twins = {} # sprite name -> { slot:, gate: }: the window that keeps it out
          program.walk.filter_map { |node| node.under if node.kind == :fade }
                 .uniq
                 .flat_map { |layer| sprites_needing_a_window(layer) }
                 .uniq(&:name)
                 .each_with_index do |node, nth|
            place = @picture.stack.index(node.layer)
            @window_twins[node.name] = {
              slot: nth, # in front of every real sprite — see #prepare_objects
              gate: Build.binop(:<=, Build.var_ref(EFFECT_LINE), Build.int(place)),
            }
          end
        end

        # The sprites a fade under +layer+ has to hold itself off one at a time. None when
        # every sprite is on the kept side: they then leave the blend's target list
        # together, which is one register bit and no twins at all.
        def sprites_needing_a_window(layer)
          kept = IR::Stacking.at_or_above(@picture, layer).map(&:name)
          keeps, blends = @picture.objects.partition { |node| kept.include?(node.name) }
          blends.empty? ? [] : keeps
        end

        def guard_window_twins_fit(nodes)
          total = nodes.size + @window_twins.size
          return if total <= MAX_SPRITES

          raise LoweringError,
                "#{@window_twins.size} sprites are kept out of a fade, and each one needs a second " \
                "slot in the sprite table to hold the fade off it. That is #{total} slots with the " \
                "#{nodes.size} sprites themselves, and the console draws #{MAX_SPRITES} at once. " \
                "To fix this, keep fewer sprites out of the fade, or use fewer sprites."
        end

        # Which layers a fade blends, as the blend register's target bits. With no layer
        # named that is everything, exactly as it always was.
        def fade_targets(under)
          return BLD_ALL_LAYERS if under.nil?

          kept = IR::Stacking.at_or_above(@picture, under).map(&:name)
          bits = BLD_BACKDROP # the backdrop is behind everything, so a placed fade always reaches it
          @picture.scenery.each_with_index do |node, layer|
            bits |= (BLD_BG0 << layer) unless kept.include?(node.name)
          end
          bits |= BLD_OBJ if @picture.objects.any? { |node| !kept.include?(node.name) }
          bits
        end

        # Where in the stack a fade sits. One past the front for a fade that names no
        # layer, so no twin is ever shown for it.
        def effect_line(under)
          under.nil? ? @picture.stack.length : @picture.stack.index(under)
        end

        # Build the one color table every sprite shares (8-bit color has a single
        # 256-entry palette for all sprites). Collect every color used across all the
        # sprite pictures — index 0 reserved for see-through — so each sprite's tiles
        # index into the same table and no sprite's colors overwrite another's.
        def build_shared_object_palette(nodes)
          @obj_palette = {} # 15-bit color -> palette index (1-based; 0 = see-through)
          nodes.each do |node|
            node.poses.each do |image|
              bmp = @bitmaps.fetch(image) do
                raise LoweringError,
                      "sprite object #{node.name.inspect} references undefined image #{image.inspect}"
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
          @emit.data_blobs[@obj_palette_blob] = colors.pack("v*")
        end

        # Add every non-see-through color in a sprite picture to the shared palette,
        # each earning the next index the first time it's seen.
        def scan_object_colors(bmp, palette)
          pixels = bmp.pixels
          transparent = bmp.transparent
          (bmp.width * bmp.height).times do |i|
            color = pixels.getbyte(i * 2) | (pixels.getbyte((i * 2) + 1) << 8)
            next if transparent && color == transparent

            palette[color & 0x7FFF] ||= palette.size + 1
          end
        end

        def prepare_one_object(node, slot, tile_unit)
          name = node.name
          poses = node.poses
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
          @emit.data_blobs[tile_blob] = tiles
          @objects[name] = {
            slot: slot,
            tiles: tile_blob, tile_units: tiles.bytesize / 32, # sprite memory counts in 32-byte units
            tile_index: tile_unit, # this sprite's base tile number
            per_pose: per_pose,    # stride to the next pose's tiles
            pose: node.pose,     # the run-time pose selector (which pose to show)
            width: width, height: height,
            x: node.x, y: node.y, active: node.active, # the live position/visibility operands
            angle: node.angle,   # the rotation operand (a constant 0 unless the sprite turns)
            scale: node.scale,   # the size operand (the "as drawn" constant unless it resizes)
            transformed: object_transformed?(node), # draw it through an affine group rather than upright?
            scales: object_scales?(node),           # ...and does that group need a size worked out?
            # A sprite in the see-through layer carries the blend in its own entry, so it
            # rides here rather than costing anything at draw time.
            attr0_base: OBJ_256_COLOR | (shape << 14) |
              (see_through_object?(node) ? LayerBlend::OBJ_SEMI_TRANSPARENT : 0),
            attr1_base: size << 14,
            # attr2's top bits carry how deep the sprite sits. It stays 0 — the front —
            # in every picture where the sprites are over all the scenery, which is
            # every picture that names no layers.
            attr2_base: hardware_priority(name) << OBJ_PRIORITY_SHIFT,
          }
        end

        # All of a sprite's poses share one size (they swap in place). Confirm that and
        # return it; a size mismatch is a build error rather than a garbled sprite.
        def object_pose_size!(name, poses)
          sizes = poses.map do |image|
            bmp = @bitmaps.fetch(image) # presence already checked while building the palette
            [bmp.width, bmp.height]
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
          pixels = bmp.pixels
          width = bmp.width
          transparent = bmp.transparent
          bytes = (+"").b
          (bmp.height / TILE_PX).times do |tile_row|
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
