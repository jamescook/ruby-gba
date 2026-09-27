# frozen_string_literal: true

require_relative "gba/asm" # the ARM instructions themselves, which everything below emits
require_relative "gba/sprite" # what the build worked out about one sprite, for the draw to read
require_relative "gba/pose_cutter" # how a sprite's picture is cut into the rectangles the console draws
require_relative "gba/sprite_pictures" # one sprite's pictures, and the sets of them sprites share
require_relative "gba/object_art" # where the sprites' pictures go in sprite memory
require_relative "gba/sprite_layout" # ...and one attempt at fitting them all into it
require_relative "gba/placed_fade" # a fade that sits at a place in the stack, and the twins holding it off
require_relative "gba/stretched_columns" # the pictures a stretched column draws, and where each holds pixels
require_relative "gba/address_register" # what the address register still holds, as code goes past
require_relative "gba/emit"
require_relative "gba/attribution"
require_relative "gba/lowering"
require_relative "gba/memory"
require_relative "gba/loop_form" # which shape a repeat gets; the cost model asks it too
require_relative "gba/bend_form" # ...and which way a row-by-row bend is lowered, likewise
require_relative "gba/statements"
require_relative "gba/lists"
require_relative "gba/functions"
require_relative "gba/emitter_calls" # the bare-name calls every file that writes drawing code makes
require_relative "gba/blob_upload" # copying data out of the cartridge into video memory
require_relative "gba/screen_effects" # the camera, fades and tints: the whole picture, not what is in it
require_relative "gba/sprite_drawing" # writing the rows of the console's sprite table
require_relative "gba/background_drawing" # putting background layers up, and changing them as the game runs
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
require_relative "gba/roomy"         # which collections go in the other, roomier memory
require_relative "gba/tile_vram"     # where the scenery's pictures and maps go, so they cannot collide
require_relative "gba/background_tiles" # ...and what those pictures are, each stored once
require_relative "gba/palette_banks" # sixteen colours to a picture, and the picture stored half the size
require_relative "gba/palette_tint"
require_relative "gba/layer_blend"
require_relative "gba/bios_compress"
require_relative "gba/screen_layout" # where every background and sprite goes, worked out before any code

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
      #   * r12 — where the VARIABLES' base waits between two variable accesses
      #   * r9  — where a COLLECTION's base waits between two touches of it
      #   * the CPU stack holds intermediate values inside a nested expression
      #
      # The last two are the exception to "registers are all scratch": each holds an
      # address across the statements between two accesses, for as long as nothing could
      # have written it. What may be believed about them is decided in one place, by
      # {AddressRegister}; being wrong does not fail, it sends a load somewhere else.
      # They are two registers rather than one because a collection and a variable are
      # touched alternately all through a pool walk, and sharing one would leave each
      # evicting the other every time.
      class GBA
        include RubyGBA::Console::Hardware
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
        # What a picture's palette-number form is filed under, beside its colors. Where each
        # of its columns holds pixels is filed beside them too — see StretchedColumns.
        INDEXED_SUFFIX = "__indexed"
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
        LIST_ADDR = 9 # where a collection's own base waits between two touches of it
        STACK = 13 # the stack pointer, for the rare value with nowhere else to wait

        # WHAT THIS BACKEND DECIDED ABOUT AN ASSET, as against what the asset IS (that is
        # IR::Assets, shared with every backend). These are facts about the cartridge and
        # the console, so they mean nothing anywhere else and belong here.

        # A table, once packed into the cartridge: how many elements, how wide each is, and
        # whether the count is a power of two — which decides whether an out-of-range index
        # is wrapped (one instruction) or clamped against both ends.
        TableLayout = Data.define(:count, :elem_bytes, :signed, :pow2)

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
        # StretchedColumns). The walk goes round once per stretch of them.
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
        COMPARISONS = Ractor.make_shareable({
          :>  => %i[gt le], :<  => %i[lt ge],
          :>= => %i[ge lt], :<= => %i[le gt],
          :== => %i[eq ne], :!= => %i[ne eq],
        })

        attr_reader :lowering

        # What each node of the program turned into, once #lower has run. See {Attribution}.
        attr_reader :attribution

        # Each func's byte span in @code (for dump_func) — lives on @functions.
        def func_ranges = @functions.func_ranges

        # The routines this build made for its scenes' moving sprites, each with the scene it
        # writes for. Read by the placement, which weighs them like routines somebody wrote.
        def scene_sprite_routines
          (@scene_sprites || []).to_h { |group| [SpriteDrawing.sprites_routine(group.scene), group.scene] }
        end

        # How many routines the frame's own body calls that the program never wrote: the
        # scenes' sprite writers and the still sprites'. Each is a call that grows if the
        # frame moves to the quick memory and the routine does not.
        def frame_calls_to_made_routines
          (@scene_sprites || []).length + (@movement&.still&.any? ? 1 : 0)
        end

        # The emitted machine code / the label table / where each embedded blob landed
        # — read straight from @emit, which is where they actually live (see {Emit}).
        def code = @emit.code
        def labels = @emit.labels
        def data_positions = @emit.data_positions
        def palette_entries = @palette_tint.palette_entries
        # A test reads a voice's/the mix buffers' state back (see {Mixer}).
        def bitmaps = @bitmaps
        def blob_codecs = @blob_codecs
        # Reached via `drawing: self` by Audio (still, until Drawing exists a few lines
        # into #initialize) and by PaletteTint/LayerBlend (Drawing isn't their own
        # object's collaborator name — this instance stands in), so these have to be
        # public: an explicit-receiver call ignores privacy on the DEFINING class, not
        # on whatever the receiver happens to evaluate to.
        def emit_flip_if_buffered = @drawing.emit_flip_if_buffered
        def emit_show_the_picture = @drawing.emit_show_the_picture
        # Where the game loop starts (see Frames#emit_start_counting), and only where the
        # screen's interrupt counts frames at all.
        def emit_start_counting_frames = @uses_vblank && @frames.emit_start_counting
        def fade_steps(percent) = @effects.fade_steps(percent)
        def fade_steps_value(amount) = @effects.fade_steps_value(amount)
        def emit_clamp_blend_steps = @effects.emit_clamp_blend_steps
        def emit_blend_weights_from_acc = @effects.emit_blend_weights_from_acc
        def emit_plain_dma_blob(blob_name, dest, units) = @uploads.emit_plain_dma_blob(blob_name, dest, units)
        def mix_buf0 = @mixer.mix_buf0
        def mix_buf1 = @mixer.mix_buf1
        def voice_base = @mixer.voice_base
        def voice_table = @mixer.voice_table
        def drop_table = @mixer.drop_table

        # +fast_cartridge+ picks the cartridge timing this ROM asks for at boot. True
        # (the default) is the quick timing every real cartridge handles; false leaves
        # the console's cautious power-on timing alone, which is the escape hatch for a
        # cartridge that can't keep up (see #emit_waitcnt_setup).
        # +fast_code+ decides whether the build works out for itself which routines are
        # worth keeping in the console's quick memory (see {Placement}). True is the
        # default; false leaves every routine in the cartridge unless the author asked for
        # one by name with `func :thing, fast: true`.
        # +progress+ is what this pass says it is doing while it does it. Most of a build's
        # time is spent in here, so it names its own phases; the default says nothing.
        def initialize(fast_cartridge: true, fast_code: true, progress: Messages::Progress.silent,
                       routine_profile: nil)
          @fast_cartridge = fast_cartridge
          @fast_code = fast_code
          @progress = progress
          # What a previous run of this game was MEASURED to spend its frames on, when there is
          # such a measurement. It decides what goes in the quick memory; without it the choice
          # is made from the shape of the program instead (see Placement#ranked_by_frame_cost).
          @routine_profile = routine_profile
          @fast_funcs = Set.new  # routines that run from the quick memory
          @emitting_hot = false  # are we emitting into the block that gets copied there?
          @hot_base = nil        # where that block lands, once every variable has a home
          @hot_bytes = 0
          @emit = Emit.new       # the code buffer + two-pass label/fixup machinery
          # The IWRAM allocator. It stops below the last 4K, which is where the divide
          # routines are copied and where the console's own startup code keeps its stack.
          @memory = Memory.new(start: IWRAM_START, ceiling: Placement::HOT_CEILING,
                               roomy: EWRAM_START, roomy_ceiling: EWRAM_START + EWRAM_SIZE)
          @primitives = Primitives.new(emitter: @emit, memory: @memory)
          @divide = Divide.new(emitter: @emit, memory: @memory, primitives: @primitives,
                               scales_objects: ScreenLayout.method(:scales?))
          @frames = Frames.new(emitter: @emit, primitives: @primitives)
          # The kind-keyed dispatch that replaces eval_value's case. Every statement in the
          # program goes through it, which also makes it the one place that can say how far
          # this pass has got — and the one place that can count what each part of the
          # program turned into.
          @attribution = Attribution.new(@emit)
          @lowering = Lowering.new(progress: progress, emitted: @emit.method(:pos),
                                   attribution: @attribution)
          @save = Save.new(emitter: @emit, primitives: @primitives, lowering: @lowering)
          @defined_sounds = {}   # name -> musical params (from define_sound)
          @songs = {}            # name -> :song node (from song)
          @blob_codecs = {}      # name -> :lz77/:rle/:none (how a VRAM blob was packed, if at all)
          @blob_raw_bytes = {}   # name -> its size before packing (for the build's savings line)
          @bitmaps = {}          # name -> { width:, height: } (a blob that has a shape)
          @tables = {}           # name -> { count:, elem_bytes:, signed:, pow2: } (a ROM lookup table)
          @screen = nil          # ScreenLayout: where every background and sprite goes — built in #lower
          @stretched_columns = nil # the pictures a stretched column draws — built in #lower, from the program
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
          # Where each timer's on_tick body landed inside the interrupt dispatcher, filled in
          # as that routine is emitted (see #emit_irq_handler).
          @timer_handlers = {}
          @functions = Functions.new(emitter: @emit, lowering: @lowering, placement: self,
                                     scene_preamble: method(:emit_scene_preamble),
                                     scene_art: method(:emit_scene_art_upload))
          @statements = Statements.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                       placement: self, functions: @functions)
          @framebuffer = Framebuffer.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                         divide: @divide)
          @raster = Raster.new(emitter: @emit, primitives: @primitives, memory: @memory,
                               lowering: @lowering, framebuffer: @framebuffer)
          @mixer = Mixer.new(emitter: @emit, memory: @memory, timers: @timers, primitives: @primitives)
          @audio = Audio.new(emitter: @emit, primitives: @primitives, lowering: @lowering, mixer: @mixer,
                             memory: @memory, sounds: @defined_sounds, songs: @songs,
                             frames: @frames, expressions: @expressions, raster: @raster, drawing: self,
                             uses_pressed: -> { @uses_pressed }, any_buffered: -> { @modes.any_buffered? })
          @palette_tint = PaletteTint.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                          drawing: self)
          @layer_blend = LayerBlend.new(emitter: @emit, lowering: @lowering, primitives: @primitives,
                                        drawing: self)
          @buffered = Buffered.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                   framebuffer: @framebuffer, call_cold_routine: method(:emit_call_cold_routine))
          @uploads = BlobUpload.new(emitter: @emit, primitives: @primitives,
                                    codecs: @blob_codecs, raw_bytes: @blob_raw_bytes)
          @effects = ScreenEffects.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                       palette_tint: @palette_tint, layer_blend: @layer_blend)
          @sprite_drawing = SpriteDrawing.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                              divide: @divide, framebuffer: @framebuffer,
                                              palette_tint: @palette_tint, uploads: @uploads)
          @background_drawing = BackgroundDrawing.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                                      divide: @divide, raster: @raster,
                                                      palette_tint: @palette_tint, uploads: @uploads)
          @drawing = Drawing.new(emitter: @emit, primitives: @primitives, lowering: @lowering,
                                 divide: @divide, framebuffer: @framebuffer, raster: @raster,
                                 palette_tint: @palette_tint, layer_blend: @layer_blend, buffered: @buffered,
                                 uploads: @uploads, sprite_drawing: @sprite_drawing,
                                 background_drawing: @background_drawing, backing_info: method(:backing_info),
                                 call_cold_routine: method(:emit_call_cold_routine))
          # Every value kind's handler, registered once in one place — see {Lowering}.
          @lowering.values(
            int: @expressions.method(:eval_int), var_ref: @expressions.method(:eval_var_ref),
            neg: @expressions.method(:eval_neg), binop: @expressions.method(:eval_binop),
            bit_not: @expressions.method(:eval_bit_not), absolute: @expressions.method(:eval_absolute),
            clamped: @expressions.method(:eval_clamped),
            mul_fix: @expressions.method(:eval_mul_fix), div_fix: @expressions.method(:eval_div_fix),
            shift_right: @expressions.method(:eval_shift_right), held: @expressions.method(:eval_held_node),
            pressed: @expressions.method(:eval_pressed_node), chance: @expressions.method(:eval_chance),
            pixels_overlap: @collision.method(:eval_pixels_overlap),
            data_byte: @expressions.method(:eval_data_byte), table_get: @expressions.method(:eval_table_get),
            list_get: @lists.method(:eval_list_get), list_len: @lists.method(:eval_list_len),
            save_read: @save.method(:eval_save_read), save_sum: @save.method(:eval_save_sum),
            read_scanline: @expressions.method(:eval_read_scanline), timer_ticks: method(:eval_timer_ticks),
          )
          # Every statement kind's handler, registered once in one place — see {Lowering}.
          # The definition kinds are collected during the definitions pass, earlier in
          # #lower, and emit nothing here — Lowering::NOTHING says so explicitly.
          @lowering.statements(
            func: Lowering::NOTHING, set: @statements.method(:emit_set), add: @statements.method(:emit_add),
            sub: @statements.method(:emit_sub), copy: @statements.method(:emit_copy),
            negate: @statements.method(:emit_negate), abs: @statements.method(:emit_abs),
            negate_abs: @statements.method(:emit_negate_abs), clamp: @statements.method(:emit_clamp),
            save_init: method(:emit_save_init), save_store: method(:emit_save_store),
            save_write: @save.method(:emit_save_write),
            if: @statements.method(:emit_if), loop: @statements.method(:emit_loop),
            repeat: @statements.method(:emit_repeat), inside: @statements.method(:emit_inside),
            every: @statements.method(:emit_every), after: @statements.method(:emit_after),
            list_new: @lists.method(:emit_list_new), list_push: @lists.method(:emit_list_push),
            list_drop: @lists.method(:emit_list_drop), list_set: @lists.method(:emit_list_set),
            call: @statements.method(:emit_call), case: @functions.method(:emit_case),
            call_one_of: @functions.method(:emit_call_one_of),
            raw: @statements.method(:emit_raw), halt: @statements.method(:emit_halt),
            wait_vblank: @audio.method(:emit_wait_vblank), screen: @drawing.method(:emit_screen),
            pixel: @drawing.method(:emit_pixel), fill_rect: @drawing.method(:emit_fill_rect),
            clear_screen: @drawing.method(:emit_clear_screen), dma_fill_rect: @drawing.method(:emit_dma_fill_rect),
            draw_rect_at: @drawing.method(:emit_draw_rect_at), draw_column_at: @drawing.method(:emit_draw_column_at),
            draw_text: @drawing.method(:emit_draw_text), draw_digit: @drawing.method(:emit_draw_digit),
            blit: @drawing.method(:emit_blit), blit_pose: @drawing.method(:emit_blit_pose),
            background: @drawing.method(:emit_background), scroll_background: @background_drawing.method(:emit_scroll_background),
            affine_background: @background_drawing.method(:emit_affine_background),
            scroll_rows: Lowering::NOTHING, camera: @effects.method(:emit_camera), fade: @effects.method(:emit_fade),
            tint: @effects.method(:emit_tint), see_through: @layer_blend.method(:emit_see_through),
            set_tile: @background_drawing.method(:emit_set_tile), show_map: @background_drawing.method(:emit_show_map),
            background_colors: @background_drawing.method(:emit_background_colors),
            present_objects: @sprite_drawing.method(:emit_present_objects), save_region: @drawing.method(:emit_save_region),
            restore_region: @drawing.method(:emit_restore_region), enable_sound: @audio.method(:emit_enable_sound),
            define_sound: Lowering::NOTHING, song: Lowering::NOTHING, data: Lowering::NOTHING,
            bitmap: Lowering::NOTHING, backing_buffer: Lowering::NOTHING, object: Lowering::NOTHING,
            font: Lowering::NOTHING,
            table: Lowering::NOTHING, layers: Lowering::NOTHING, see_through_layer: Lowering::NOTHING,
            beep: @audio.method(:emit_beep),
            noise: @audio.method(:emit_noise), wave: @audio.method(:emit_wave),
            stop_wave: @audio.method(:emit_stop_wave),
            play_song: @audio.method(:emit_play_song), stop_music: @audio.method(:emit_stop_music),
            song_list: Lowering::NOTHING, play_from_list: @audio.method(:emit_play_from_list),
            sound_effect_list: Lowering::NOTHING, play_sound_effect: @audio.method(:emit_play_sound_effect),
            timer_start: method(:emit_timer_start), timer_stop: method(:emit_timer_stop),
            on_timer: Lowering::NOTHING, sample: Lowering::NOTHING, play_sample: @mixer.method(:emit_play_sample),
            stop_sample: @mixer.method(:emit_stop_sample),
          )
          @layer_stack = []      # the layers the program declared, backmost first
          @uses_pressed = false  # whether the program reads edge-detected input
          @palette = nil         # the color table, built once when any scene is buffered
          @indexed_bitmaps = {}  # name -> the number meaning see-through, for pictures drawn indexed
          @modes = nil           # IR::Modes: which screen mode each scene resolves to
          @tiled = false         # does the program use tile mode (screen :tiled)?
          @has_objects = false   # does the program declare any composited objects (sprites)?
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

        # Which lists the program SHIFTS. Those are rings — a head that moves and a mask that
        # wraps it — where every other list is a plain row of slots, and the two are reached
        # differently (see Lists#emit_slot_address). A class method because the cost model asks
        # the same question to price a read: asked here, not restated there.
        def self.shifted_lists(program)
          program.walk.filter_map { |n| n.name if n.kind == :list_drop && n.from == :front }.to_set
        end

        # Whether the program asks anywhere whether a button has just gone DOWN. That one
        # question is what makes the frame boundary latch the buttons — this frame's become
        # last frame's, the console's are read afresh — so a program that never asks it pays
        # nothing for it and one that asks twenty times pays for it once. A class method for
        # the reason above: the cost model asks the same question to price a frame's boundary.
        def self.reads_button_edges?(program)
          program.walk.any? { |node| node.kind == :pressed }
        end

        # Everything this build worked out about the program it just lowered, in one piece,
        # for the cartridge to carry (see {RubyGBA::Cartridge::BuildRecord}). Valid after #lower —
        # every part of it is a decision the lowering made. Handing it over whole is what
        # lets a ROM be assembled in one call instead of being filled in field by field
        # afterwards.
        def build_record(program)
          RubyGBA::Cartridge::BuildRecord.new(source_program: program, placement: iwram_report,
                                   var_addresses: var_addresses, loop_shapes: loop_shapes,
                                   palette_entries: palette_entries,
                                   column_stretches: @stretched_columns&.to_h || {},
                                   compression: compression_report,
                                   emitted: @attribution.emitted,
                                   routines: routine_addresses,
                                   timer_handlers: timer_handler_addresses,
                                   voices: voice_table,
                                   sound_drops: drop_table,
                                   video_memory: @screen.video_memory_report,
                                   roomy_memory: roomy_memory_report,
                                   sprite_slots: @screen.sprite_slots,
                                   sprite_offsets: @screen.sprite_offsets,
                                   sprite_pose_in_room: sprite_pose_in_room,
                                   build_options: { fast_cartridge: @fast_cartridge, fast_code: @fast_code })
        end


        # WHERE A KEPT-TO-ONE-FRAME SPRITE SAYS WHICH POSE IT IS SHOWING: the address of the
        # variable the cartridge writes as it copies a frame into the sprite's room. Keyed by
        # the place in the console's table, the same as ScreenLayout#sprite_offsets, and a slot in here is
        # what says that the offsets for that slot are counted by pose rather than looked up by
        # what the row says. Empty for a game whose sprites all keep every picture they can show.
        def sprite_pose_in_room
          @screen.each_built_sprite.each_with_object({}) do |(_node, sprite), where|
            next unless sprite.frames

            address = var_addr(sprite.frame_in_room_var)
            sprite.pieces.times { |piece| where[sprite.slot + piece] = address }
          end
        end

        # WHAT WENT IN THE OTHER MEMORY, and how much of it is left.
        #
        # The console has 256K of it, eight times the quick memory and about six times the
        # wait on a read, and it used to hold nothing but the audio mixer's two buffers.
        # What is worth reporting is what the framework put there without being asked —
        # because a collection landing there is a decision nobody wrote, and the only way
        # to see it is to be told.
        def roomy_memory_report
          placed = @lists.roomy_lists
          return nil if placed.empty? && @memory.roomy_used.zero?

          Roomy::Usage.new(used: @memory.roomy_used, free: @memory.roomy_free,
                           collections: placed)
        end

        # WHERE EACH ROUTINE ENDED UP, as the span of addresses it really occupies while the
        # console runs. This is what turns a profile's raw addresses back into the author's own
        # names, and nothing can recover it from the finished bytes afterwards.
        #
        # A routine lives in one of two places and the answer differs for each. One left in the
        # cartridge runs where it was written, so its address is the cartridge's own base plus
        # the header we put in front of the code plus its offset among the other routines. One
        # the build kept in the console's quick memory was copied there at boot and runs from a
        # different address entirely — {Placement#fast_func_address} is the one that knows,
        # since it is the same answer a call to that routine had to be given.
        #
        # Either way the SIZE is its span in the emitted code, because the copy is a copy.
        # WHERE EACH TIMER'S HANDLER STARTS, as a real runtime address, and the rate its
        # program asked for. What reads it counts how many times that one instruction ran and
        # holds it against the rate — see {TickRate}.
        #
        # The offsets were kept while the dispatcher was emitted (#emit_irq_handler); the base
        # is that routine's own runtime address, which already accounts for the build having
        # possibly copied it into the console's quick memory.
        def timer_handler_addresses
          irq = routine_addresses[Placement::IRQ_ROUTINE] or return {}

          @timer_handlers.to_h { |name, info| [name, { hz: info[:hz], at: irq.begin + info[:at] }] }
        end

        def routine_addresses
          written = @functions.func_ranges.to_h do |name, span|
            base = runtime_base(name, span)
            [name, base...(base + span.size)]
          end
          # The two that are COPIED into the quick memory go on last: they are also emitted in
          # the cartridge, so the generic pass above finds them there, and it is the copy that
          # actually runs.
          written.merge(lowered_routine_addresses)
                 .merge(@divide.divide_routine_addresses)
                 .merge(@mixer.mix_routine_addresses)
        end

        # Where one routine's first instruction really is. The moved block is copied whole and
        # in order, so a routine's place inside it is its place in the emitted code — which
        # func_ranges already gives, and which the routines nobody wrote have as much as the
        # ones somebody did. (Placement#fast_func_address answers the same question from the
        # label table, and cannot be used here: the routine the console interrupts into is
        # labelled for the vector that points at it rather than as a func.)
        def runtime_base(name, span)
          hot_start = @emit.labels[Placement::HOT_START]
          return hot_base + (span.begin - hot_start) if hot_base && hot_start && fast_funcs.include?(name)

          ROM_START + RubyGBA::Cartridge::ROM::ENTRY_OFFSET + span.begin
        end

        # ROUTINES THE LOWERING MAKES, which an author never wrote and cannot be found in
        # func_ranges — the shared glyph walker each font gets so that a run-time digit is
        # called rather than emitted again at every call site, and its tear-free twin.
        #
        # They are real work and can be a large part of a frame: measured on
        # examples/breakout.rb, whose HUD draws numbers, a fifth of the frame is in one of
        # these. Unnamed it reads as code nothing can account for, which is the least useful
        # thing a profile can say.
        #
        # Found by the convention the divide routine already used — a routine brackets itself
        # with a start label and the same name with _end — so a new one is picked up by
        # bracketing it, with nothing to add here.
        def lowered_routine_addresses
          @emit.labels.filter_map do |name, start|
            finish = @emit.labels[:"#{name}_end"] or next
            next if @functions.func_ranges.key?(name) # a routine somebody wrote, already placed

            base = ROM_START + RubyGBA::Cartridge::ROM::ENTRY_OFFSET
            [name, (base + start)...(base + finish)]
          end.to_h
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
          # The throwaway measuring pass keeps the phase its caller named, since from the
          # outside it IS that phase — it is not lowering the program, it is finding out how
          # big the routines come out.
          @progress.step("lowering it to machine code") if fast_funcs.nil?
          # Nothing counted so far belongs to this pass. A backend lowered twice reports what
          # it emitted the second time, not the two runs added together.
          @attribution.reset
          # Which pictures a stretched column reads, which decides whether a see-through one
          # still needs its pixels in the cartridge. Wanted before the assets are registered.
          @stretched_columns = StretchedColumns.new(program, emitter: @emit)
          @framebuffer.stretched_columns = @stretched_columns
          @statements.unread_indexes = LoopForm.unread_indexes(program)
          # First in internal memory, before anything else is given a home there: only a
          # program that divides by something it works out as it runs carries the divide
          # routine, and every other division is settled at build time.
          reserve_divide_routine if needs_divide_routine?(program)
          reserve_divide_fix_routine if needs_divide_fix_routine?(program)
          collect_definitions(program)
          adopt_frame_body(program) # the game loop's body counts as a routine once it moves
          @mixer.prepare_direct_sound(program) # embed the program's samples as ROM data
          @audio.prepare_music(program) # number its tunes, and keep the mixer voices they play on
          @uses_vblank = program.walk.any? { |node| node.kind == :wait_vblank }
          @mixer.prepare_mixer(program) # the software mixer's rate, buffers, voice slots, timer
          @audio.build_score # every tune as one score — after the mixer's rate, which sets each note's step
          guard_mixer_needs_game_loop
          register_timers(program) # assign each named timer its hardware timer index(es)
          prepare_pixel_masks(program) # solid-pixel tables for any per-pixel collision test
          resolve_modes(program)
          # `screen :rotozoom` is tile hardware too — a different pair of layers (BG2/BG3,
          # rotate/scale rather than plain scroll) from `screen :tiled`'s four, but it
          # needs the same shared palette/character-block upload and background lowering,
          # so it counts here alongside :tiled.
          @tiled = Modes.draws_with_tiles?(program)
          # Where every background and sprite goes, and the cartridge data that says so.
          @screen = ScreenLayout.plan(program, bitmaps: @bitmaps, modes: @modes)
          @emit.data_blobs.merge!(@screen.blobs)
          @blob_codecs.merge!(@screen.codecs)
          @layer_blend.screen = @screen # built here, not at construction — see LayerBlend's class comment
          @raster.register_row_bends(program) # which layers bend row by row (armed at boot, run per line)
          @raster.prepare_row_bends(program, layers: @screen.hardware_layers)
          @has_objects = program.walk.any? { |node| node.kind == :object }
          @layer_blend.prepare_layer_blend(program) # ...and which layer, if any, you can see through
          @scene_blend = @tiled ? @layer_blend.scene_blend(@modes) : {}
          # ...which is what decides whether a fade may use the display's blend at all, or
          # has to walk the color table instead to leave that layer alone (see IR::Fading).
          @fading = IR::Fading.resolve(program)
          prepare_still_objects(program) if @has_objects
          # Save data reaches the chip too, so it needs the marker that maps it as much as a
          # saved number does.
          @uses_save = program.walk.any? { |node| %i[save_init save_write save_read].include?(node.kind) }
          prepare_palette(program) if @modes.any_buffered?
          # The colour tables a tint walks: the tear-free screen's, and the ones the layout
          # made for the scenery and the sprites (see PaletteTint's class comment).
          @palette_tint.layout = PaletteTint::Layout.new(palette: @palette, screen: @screen, blob_codecs: @blob_codecs)
          @palette_tint.prepare_palette_tint(program, fading: @fading)
          @uses_pressed = self.class.reads_button_edges?(program)
          # Everything the prepare passes above decided that Drawing/Buffered read, bundled
          # into one record rather than twenty keyword arguments (see Drawing's class
          # comment) — settled now, so handed over right before the first thing that emits.
          layout = Drawing::Layout.new(
            screen: @screen, bitmaps: @bitmaps, palette: @palette, indexed_bitmaps: @indexed_bitmaps,
            blob_codecs: @blob_codecs, blob_raw_bytes: @blob_raw_bytes,
            modes: @modes, fading: @fading, tiled: @tiled, has_objects: @has_objects,
            scene_blend: @scene_blend || {}, movement: @movement || IR::Movement::EVERYTHING_MOVES,
            scene_sprites: @scene_sprites || [],
            waits_for_frames: @uses_vblank,
          )
          @drawing.layout = layout
          @buffered.layout = layout
          @effects.layout = layout
          @sprite_drawing.layout = layout
          @background_drawing.layout = layout
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
          @drawing.emit_boot_screen if @modes.switched_per_scene? # set the boot mode (+ palette for buffered)
          # Upload the tiled assets once at boot only when the program stays in tiled
          # mode. When it crosses the bitmap/tiled boundary, a bitmap scene overwrites
          # the video memory the tiles live in, so the assets are (re)uploaded on each
          # entry into a tiled scene instead (enter_tiled_mode) — always current, and
          # only paid on the actual switch.
          unless @modes.switched_per_scene?
            @background_drawing.emit_boot_backgrounds if @tiled && !@screen.backgrounds.empty? # shared BG palette + tiles
            @sprite_drawing.emit_boot_objects if @has_objects # sprite tiles/colors + clear the sprite table
            @layer_blend.emit_boot_layer_blend if @layer_blend.see_through? # ...and which layer you can see through
          end
          # Clear each bending layer's table of row offsets, and start the engine that feeds
          # it to the display. Set up wherever the program starts out, since a bend is fed a
          # table rather than a picture — there is nothing here for a bitmap scene to
          # overwrite.
          emit_boot_row_bends if @raster.latches_row_bends?
          emit_tint_state_init if @palette_tint.moves_a_color_table? # the tables start as they were drawn
          @lowering.in_mode(@modes.default_mode) do
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
          # :fast_addr/:hot_size/:routine_word are Placement's own fixup kinds — Emit doesn't
          # know what "the quick memory" or "a DMA transfer's size" mean, so Placement
          # hands its own resolvers in rather than Emit reaching for them by name.
          @emit.resolve_fixups(fast_addr: method(:resolve_fast_address), hot_size: method(:resolve_hot_size),
                               routine_word: method(:resolve_routine_word))
          @emit.code
        end

        # Each variable's allocated IWRAM address (name => address), known once the
        # program has been lowered. This backend — not the builder — decides where a
        # variable lives, so this is the authoritative map a hardware test uses to
        # read a variable's value back from memory (see RubyGBA::Diagnostics::Verifier#var).
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
        # When a program switches the hardware per scene — because some scene double-
        # buffers, or because it crosses the bitmap/tiled boundary — the display
        # registers are managed centrally: set once at boot, then re-set only on a
        # scene's mode transition (its preamble). A single-display-system program
        # leaves each `screen` node to write DISPCNT inline, exactly as before. That is
        # IR::Modes#switched_per_scene?, which every reader here asks rather than each
        # keeping an answer of its own.
        def resolve_modes(program)
          @modes = IR::Modes.resolve(program)
          @functions.modes = @modes
          @palette_tint.modes = @modes
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
        def emit_call_through(reg) = @emit.emit_call_through(reg)
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
        def emit_mixer_handover = @mixer.emit_mixer_handover
        def emit_mixer_fill = @mixer.emit_mixer_fill
        def emit_mix_routine = @mixer.emit_mix_routine

        # Forwards to @audio (see {Audio}) — the music player the screen's interrupt runs.
        def emit_music_tick = @audio.emit_music_tick

        # Forwards to @palette_tint (see {PaletteTint}).
        def moves_a_color_table? = @palette_tint.moves_a_color_table?
        def emit_tint_state_init = @palette_tint.emit_tint_state_init

        # Forwards to @drawing (see {Drawing}) — the scene entry points Functions is handed
        # before @drawing exists, so it is given these instead.
        def emit_scene_preamble(name) = @drawing.emit_scene_preamble(name)
        def emit_scene_art_upload(name) = @drawing.emit_scene_art_upload(name)

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
          # ...and the screen's own frame, whose handler used to be nothing but the ack. Three
          # things ride on it now, all for the same reason: THE SCREEN KEEPS TIME WHATEVER THE
          # GAME IS DOING. It counts frames, which is what lets a pass of the game loop know how
          # many of them it took; it builds the next slice of sound, because a sixtieth of a
          # second of sound is a fact about the display and not about how long the game took to
          # think; and it moves the tune on a frame, because a tempo is too. A game whose pass
          # spans two frames comes round here twice, and gets two slices and two frames of tune
          # — see Mixer#emit_mixer_fill for what went wrong when it did not. The slice built last
          # frame is handed to the sound hardware before anything else (see
          # Mixer#emit_mixer_handover). Then the tune, so a note a recorded part starts this frame
          # is in the slice built this frame.
          emit_irq_source(IRQ_VBLANK, bios_ack: true) do
            emit_mixer_handover if @mixer.plays_samples?
            emit_frame_count
            emit_music_tick if @audio.plays_music?
            # ...and between the two, a frame of every sounding note's shape, so a note that has
            # just started has climbed and one that has just ended is on its way down before the
            # slice they are both in is built (see Mixer#emit_envelope_step).
            @mixer.emit_envelope_step if @mixer.shapes_notes?
            emit_mixer_fill if @mixer.plays_samples?
          end if @uses_vblank
          irq_timers.each do |name, info|
            emit_irq_source(timer_irq_bit(info[:rate])) do
              # WHERE THIS HANDLER'S FIRST INSTRUCTION SITS, kept so a profile can count how
              # many ticks really arrived. A handler's body is emitted inline here rather than
              # as a routine of its own, so there is no name in the profile to count — but its
              # first instruction runs exactly once per tick answered, and the source's own
              # test above has already branched past it when this timer did not fire.
              #
              # It is kept as an offset INSIDE this routine, not as an address. This routine is
              # one of the two the build may copy into the console's quick memory, where it runs
              # nowhere near where it sits in the cartridge — and the offset is the same either
              # way, because a copy is a copy. Whoever reads it adds the routine's own runtime
              # base (see #routine_addresses).
              @timer_handlers[name] = { hz: info[:hz], at: pos - start }
              info[:handler].children.each { |child| @lowering.statement(child) }
            end
          end
          emit(ASM.pop(*IRQ_SAVED_REGS))
          emit(ASM.return) # BX LR back to the BIOS dispatcher
          # The routines the music player calls to find its notes a voice, past the return and
          # inside this routine's span — so they move with it if it is copied to the quick
          # memory, and a call to them is always near enough.
          @mixer.emit_music_voice_routines if @mixer.music_takes_voices?
          @audio.emit_sound_effects_routine if @audio.plays_sound_effects?
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
          # WHICH LISTS ARE RINGS, asked before anything is allocated. A list is a ring only if
          # the program drops from its FRONT, which is what moves its head; every other one is
          # a plain array and is allocated at the size it asked for rather than rounded up to
          # the next power of two. Nearly all of them are — a pool's fields, a board, anything
          # filled once and then read by number — and on a cartridge with a lot of them the
          # rounding was thousands of bytes of the console's 32K. See Lists.
          shifted = self.class.shifted_lists(program)
          declarations = [] # every list, gathered here and registered coldest last

          program.walk do |node|
            case node.kind
            when :func
              @functions.funcs[node.name] = node
            when :define_sound
              @defined_sounds[node.name] = RubyGBA::Audio::Sound::Effect.new(
                frequency: node.frequency, duty: node.duty,
                decay: node.decay, volume: node.volume,
              )
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
              @emit.data_blobs[node.name] = node.pixels if !node.transparent || @stretched_columns.reads?(node.name)
              @stretched_columns.register(node)
            when :list_new
              # Storage is reserved once, up front, so every op that touches it (anywhere
              # in the tree, including funcs emitted later) already knows its base address
              # and capacity — but NOT here, where the order would be declaration order and
              # so decide by accident which collections get the quick memory. Gathered now,
              # registered after the walk, coldest last (see #register_the_collections).
              declarations << [node, shifted.include?(node.name)]
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
          register_the_collections(program, declarations)
        end

        # HAND THE QUICK MEMORY TO THE COLLECTIONS A FRAME TOUCHES, and let the rest fall
        # into the roomy one.
        #
        # Nothing is moved once it is placed — a collection simply takes whichever memory
        # has room when its turn comes. So the ORDER of the turns is the whole decision,
        # and it must not be declaration order: a game with a lot of state declares its
        # big cold tables early, those take the quick memory, and the things a frame walks
        # every pass land in the memory that makes the processor wait. Which is the wrong
        # way round, and invisible from the program.
        #
        # So the turns go: what a frame touches, then what it does not, then what the
        # author said is cold. See Roomy for how "what a frame touches" is read off the
        # program rather than guessed at.
        def register_the_collections(program, declarations)
          roomy = Roomy.new(program)
          ranked = declarations.sort_by do |node, _ring|
            asked = node.fast
            [asked == false ? 2 : (asked || roomy.hot?(node.name) ? 0 : 1), -node.capacity]
          end
          ranked.each do |node, ring|
            @lists.register_list(node.name, node.capacity, ring: ring,
                                                           width: node.width || :word, fast: node.fast)
          end
        end

        # Element size in bytes for each table width, and the Array#pack directive that
        # writes that many bytes little-endian. Packing signed keeps negatives as two's
        # complement; pack takes the low bytes, so the same directive serves an unsigned
        # table too (the read, ldrb/ldrh vs ldrsb/ldrsh, is what restores the sign).
        TABLE_ELEM = Ractor.make_shareable({ byte: [1, "c*"], half: [2, "s<*"], word: [4, "l<*"] })

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
        # Every picture the program declares, once it has a tear-free scene at all — rather than
        # only the ones such a scene draws. A program with no tear-free scene ships nothing
        # extra, and a picture used only on a direct-color scene stays as it was.
        #
        # Narrowing it to what is drawn would mean naming the verbs that draw a picture, and
        # that list is now real (`blit`, and `blit_pose` through it), so the narrowing is worth
        # doing — a game that declares a hundred pictures and draws two on its tear-free scene
        # ships ninety-eight second copies nobody reads.
        def prepare_indexed_bitmaps(program)
          program.walk do |node|
            next unless node.kind == :bitmap

            bytes, clear = @palette.indices_for(node)
            @emit.data_blobs[indexed_blob(node.name)] = bytes
            @indexed_bitmaps[node.name] = clear
          end
        end

        def indexed_blob(name) = :"#{name}#{INDEXED_SUFFIX}"

        # The console's tile size (8x8 pixels) and the number of cells across a
        # regular background map (32x32). These are fixed hardware facts.
        TILE_PX = 8
        MAP_CELLS = 32

        # How many layers the console stacks, and how many are left once one of them
        # turns, live with the rule that reads them — see
        # Guardrails::Checks::TooManyBackgroundLayers. Where each layer's tiles and map
        # GO is a different question, and that one is {TileVram}'s: it owns the whole 64K
        # the scenery lives in and is the only thing that decides an address there.
        SCREENBLOCK_BYTES = TileVram::SCREEN_BLOCK_BYTES
        CHAR_BLOCK_BYTES = TileVram::CHAR_BLOCK_BYTES

        # How big one tile is stored each way. A map names its tiles in units of its own
        # tile size, so which of these a layer uses decides both how much room its
        # tileset takes and what a tile number means in its map.
        SMALL_TILE_BYTES = (TILE_PX * TILE_PX) / 2
        BIG_TILE_BYTES = TILE_PX * TILE_PX

        # BGxCNT bit 7 (8bpp): this layer's pixels are whole bytes, so it reads across the
        # console's whole 256-color background table. Left clear (4bpp) a pixel is half a
        # byte and each TILE says which bank of sixteen it draws from — half the memory for
        # the same picture, and twice as many tiles in the block. Which a layer gets is
        # worked out from the colors in its tiles; nothing in the DSL says. See
        # {PaletteBanks}, whose comment maps the framework's words onto this console's.
        BG_256_COLOR = 0x0080

        # A map entry's bits 12-15: which palette bank this cell's tile draws from. Per
        # TILE, not per layer — so one 4bpp background can span all sixteen banks.
        BG_BANK_SHIFT = 12

        # BGxCNT bits 2-3: which 16K block this layer counts its tile numbers from. Every
        # layer's pictures are still one run uploaded in one piece — this only says where
        # in that run a given layer starts counting. See {TileVram} and {BackgroundTiles}.
        CHAR_BASE_SHIFT = 2

        BG_SHARED_PAL = :__bg_shared_pal   # the one palette every layer indexes into
        BG_SHARED_CHAR = :__bg_shared_char # every layer's tile pictures, uploaded as one piece


        # A background tile has no see-through marker of its own the way a sprite picture
        # does. Instead the BACKDROP color — what the screen shows where nothing was
        # drawn — is what "nothing here" looks like in a tile, so a layer in front of
        # another lets it through wherever it is that color. It always takes the number
        # the console reads as see-through, so it needs no slot of its own.
        BG_SEE_THROUGH = 0x0000

        # How many cells one screen block holds: a block is 2K and a regular map's cell is
        # a halfword, so 32x32 of them is exactly one.
        MAP_ENTRIES_A_BLOCK = MAP_CELLS * MAP_CELLS

        # BGxCNT bits 14-15: which of the four grid sizes this layer scrolls over. The
        # framework picks the smallest that holds what the author drew; nothing in the DSL
        # names one.
        REGULAR_MAP_SIZES =
          Ractor.make_shareable({ [32, 32] => 0, [64, 32] => 1, [32, 64] => 2, [64, 64] => 3 })
        MAP_SIZE_SHIFT = 14

        # The hardware layer a `screen :rotozoom` background always lives on — the console
        # gives rotate/scale hardware to exactly BG2 and BG3, and this feature uses one of
        # them (see the "only one affine background" check above).
        AFFINE_BG = 2

        # The scale/rotate matrix that means "no scaling, no rotation" — 1.0 in the
        # console's 8-fraction-bit fixed point. A turning background and the camera both
        # set it on that layer.
        FIXED_ONE = 0x0100

        # BG2CNT bits 14-15 on a rotate/scale layer mean a SQUARE grid — 16, 32, 64 or 128
        # tiles a side — rather than the four rectangles a regular layer picks between. So
        # this layer's map has to be square, which every other kind of background does not.
        AFFINE_MAP_SIZES = { 16 => 0, 32 => 1, 64 => 2, 128 => 3 }.freeze

        # attr0 bit 13 (8bpp): this sprite's pixels are whole bytes, so it reads across the
        # console's whole 256-color sprite table. Left clear (4bpp) a pixel is half a byte
        # and the sprite draws from one bank of sixteen — half the memory for the same
        # picture. Which one a sprite gets is worked out from the colors in its art (see
        # ScreenLayout#build_shared_object_palette); nothing in the DSL says. See {PaletteBanks}, whose
        # comment maps the framework's words onto this console's.
        OBJ_256_COLOR = 0x2000

        # attr1 bit 12: draw this sprite reversed left to right. The console does it as it
        # composites, for nothing, which is what lets a pose that is another pose mirrored
        # keep no pixels of its own (see PoseCutter#mirrors_of). It only means this while
        # the sprite is upright — once one turns, this bit and the one above it name its
        # rotation group instead.
        OBJ_HFLIP = 0x1000

        # attr2 bits 12-15: which palette bank a 4bpp sprite reads. Per SPRITE, so all of
        # its poses share one — unlike a background, where each tile names its own.
        OBJ_BANK_SHIFT = 12

        # attr2 bits 10-11: how deep this sprite sits, on the console's own scale where 0
        # is the front. A sprite is drawn over a background holding the SAME number, which
        # is what lets a picture put scenery in front of one sprite and behind another
        # without spending a number on each.
        OBJ_PRIORITY_SHIFT = 10

        # A sine lookup table baked into ROM, so the matrix math costs a memory read
        # rather than a per-frame sine. Entry d is sin(d°) in 8.8 fixed point (256 =
        # 1.0). It runs to 449°, not 359°, so cosine — sin(angle + 90) — is a straight
        # read at angle + 90 with no wrap, for any angle the DSL keeps in 0..359.
        OBJ_SINE_BLOB = :__obj_sine
        OBJ_SINE_ENTRIES = 450

        # WHICH SPRITES A FRAME NEED NOT WRITE AT ALL.
        #
        # The console composes its picture from a table it re-reads every frame, so a sprite
        # stays exactly where the last write to that table put it. A sprite nothing in the
        # program moves is therefore already right, on this frame and every frame after — and
        # writing it again is a few dozen instructions producing the numbers already there.
        # IR::Movement says which those are, less the ones the layout has to write every frame
        # whatever the program does (see ScreenLayout#written_every_frame).
        def prepare_still_objects(program)
          @movement = IR::Movement.of(program).except(@screen.written_every_frame)
          still = @movement.still
          @functions.mint(SpriteDrawing::STILL_ROUTINE) { @sprite_drawing.write_object_table(still) } if still.any?
          prepare_scene_sprites(program, still)
        end

        # WHICH SPRITES ARE WRITTEN BY THEIR SCENE'S OWN ROUTINE rather than by the frame's.
        #
        # A sprite declared inside a scene is on screen only while that scene is, so the rows
        # of the ones that move need writing only on that scene's frames. Written from the
        # frame's own body they were code in the routine the framework keeps in the quick
        # memory FIRST, for every scene the game has — so a file-select screen shown once took
        # that memory from the scene the player spends the game in. Written by a routine per
        # scene, each is placed like any other routine: by what a frame spends in it.
        #
        # They are still written in the gap after the picture, where every sprite is written, so
        # nothing about which frame's numbers a sprite is drawn from changes (see
        # SpriteDrawing#emit_scene_sprites).
        def prepare_scene_sprites(program, still)
          @scene_sprites = IR::Movement.by_scene(program).filter_map do |things|
            moving = things.names.select { |name| @screen.objects.key?(name) } - still
            things.with(names: moving) if moving.any?
          end
          @scene_sprites.each do |group|
            @functions.mint(SpriteDrawing.sprites_routine(group.scene)) { @sprite_drawing.write_object_table(group.names) }
          end
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
        # bit out of the mask instead, and costs nothing at all. See PlacedFade, which owns
        # all of it; these are the numbers the hardware reads.
        EFFECT_LINE = :__effect_line # where in the stack the fade now in force is sitting
        OBJ_WINDOW_MODE = 0x0800     # attr0 bits 10-11 = 2: a window rather than a picture
        OBJ_WINDOW_ENABLE = 0x8000   # DISPCNT bit 15: the object window is on
      end
    end
  end
end
