# frozen_string_literal: true

require_relative "gba/emit"
require_relative "gba/statements"
require_relative "gba/lists"
require_relative "gba/drawing"
require_relative "gba/buffered"
require_relative "gba/audio"
require_relative "gba/expressions"
require_relative "gba/primitives"

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
          @backing = {}          # name -> { width:, height:, base: } (a sprite's save-under RAM)
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

      end
    end
  end
end
