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
          @modes = nil           # IR::Modes: which screen mode each scene resolves to
          @any_buffered = false  # does any scene use double buffering?
          @default_mode = :direct # the boot screen mode (from the top-level `screen`)
          @func_mode = {}        # func name -> :direct | :buffered (resolved from the call graph)
          @scene_funcs = []      # funcs entered per frame, which switch the mode on entry
          @lower_mode = :direct  # the mode draws currently lower in (set per func)
          @tiled = false         # does the program use tile mode (screen :tiled)?
          @backgrounds = {}      # name -> resolved tiled-background blobs (palette/tiles/map)
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
          resolve_modes(program)
          @tiled = program.walk.any? { |node| node.kind == :screen && node[:mode] == :tiled }
          prepare_backgrounds(program) if @tiled
          @has_objects = program.walk.any? { |node| node.kind == :object }
          prepare_objects(program) if @has_objects
          prepare_palette(program) if @any_buffered
          @uses_pressed = program.walk.any? { |node| node.kind == :pressed }
          emit_input_init if @uses_pressed
          emit_boot_screen if @any_buffered # set the boot mode + upload the palette once
          emit_boot_objects if @has_objects # upload sprite tiles/colors + clear the sprite table
          @lower_mode = @default_mode
          program.children.each { |stmt| emit_statement(stmt) }
          emit_functions
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

        # The console's tile size (8x8 pixels) and the number of cells across a
        # regular background map (32x32). These are fixed hardware facts.
        TILE_PX = 8
        MAP_CELLS = 32

        # Turn each tiled background into the three blocks of data tile hardware
        # actually reads — a color palette, the tile pictures, and the map — and
        # stash them as ROM blobs uploaded at startup. Done up front (after every
        # tile image is collected) so the addresses exist before the code refers to
        # them. This is the build-time half of the tiled lowering; emit_background
        # (in Drawing) is the run-time half that DMAs these into video memory.
        def prepare_backgrounds(program)
          program.walk { |node| prepare_one_background(node) if node.kind == :background }
        end

        def prepare_one_background(node)
          name = node[:name]
          tiles = node[:tiles]
          validate_tile_sizes!(name, tiles)

          # Convert the tiles to indexed color: collect every distinct color into one
          # palette (index 0 reserved for the black backdrop an empty cell shows), and
          # rewrite each tile's pixels as palette indices. Tile 0 of the character data
          # is a blank tile, so a map cell with no tile points at it.
          palette = { 0x0000 => 0 }
          char = (+"").b << ("\x00" * (TILE_PX * TILE_PX)).b
          tiles.each do |tile|
            pixels = @bitmaps.fetch(tile)[:pixels]
            (TILE_PX * TILE_PX).times do |i|
              color = (pixels.getbyte(i * 2) | (pixels.getbyte((i * 2) + 1) << 8)) & 0x7FFF
              char << (palette[color] ||= palette.size).chr
            end
          end
          if palette.size > 256
            raise LoweringError,
                  "background :#{name} uses #{palette.size} colors — a tiled background is limited to 256"
          end

          # The map: one 16-bit entry per cell in a 32x32 grid, holding which tile to
          # draw there (+1 because character tile 0 is the blank). Cells outside the
          # authored map stay 0 (blank).
          entries = Array.new(MAP_CELLS * MAP_CELLS, 0)
          node[:map].each_with_index do |row, r|
            next if r >= MAP_CELLS

            row.each_with_index do |index, c|
              next if c >= MAP_CELLS || index.nil?

              entries[(r * MAP_CELLS) + c] = index + 1
            end
          end

          colors = palette.sort_by { |_color, index| index }.map { |color, _index| color }
          pal_blob = :"__bg_pal_#{name}"
          char_blob = :"__bg_char_#{name}"
          map_blob = :"__bg_map_#{name}"
          @data_blobs[pal_blob] = colors.pack("v*")
          @data_blobs[char_blob] = char
          @data_blobs[map_blob] = entries.pack("v*")
          @backgrounds[name] = {
            pal: pal_blob, pal_units: colors.size,
            char: char_blob, char_units: char.bytesize / 2,
            map: map_blob, map_units: entries.size,
          }
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

        # attr0 bit 13: the object reads an 8-bit (256-color) palette, the same color
        # model the tiled background uses — so a sprite's colors are ordinary named
        # colors, no palette banks to think about.
        OBJ_256_COLOR = 0x2000

        # Turn each declared object into the two things sprite hardware needs — its
        # picture as tiles, and the colors those tiles index — and lay them out (which
        # slot in the sprite table, where its tiles sit in sprite memory). Done up
        # front so the addresses exist before the per-frame draw refers to them; the
        # boot upload (emit_boot_objects) and the per-frame draw (emit_present_objects)
        # are the run-time halves.
        def prepare_objects(program)
          slot = 0
          tile_unit = 0 # running offset into sprite tile memory, in 32-byte units
          program.walk do |node|
            next unless node.kind == :object

            prepare_one_object(node, slot, tile_unit)
            info = @objects[node[:name]]
            slot += 1
            tile_unit += info[:tile_units]
          end
        end

        def prepare_one_object(node, slot, tile_unit)
          name = node[:name]
          image = node[:image]
          bmp = @bitmaps.fetch(image) do
            raise LoweringError, "sprite object #{name.inspect} references undefined image #{image.inspect}"
          end
          width = bmp[:width]
          height = bmp[:height]
          shape, size = OBJ_SIZES.fetch([width, height]) do
            raise LoweringError,
                  "a sprite in screen :tiled must be one of these sizes: " \
                  "#{OBJ_SIZES.keys.map { |w, h| "#{w}x#{h}" }.join(', ')} — image #{image.inspect} is " \
                  "#{width}x#{height}. Resize it (sprite pictures are built from 8x8 tiles)."
          end

          palette = {} # color -> palette index; index 0 is reserved for see-through
          tiles = encode_object_tiles(bmp, palette)
          if palette.size + 1 > 256
            raise LoweringError,
                  "sprite #{image.inspect} uses #{palette.size} colors — a sprite is limited to 255 (plus see-through)"
          end

          colors = Array.new(palette.size + 1, 0x0000) # entry 0 = the see-through slot
          palette.each { |color, index| colors[index] = color }

          pal_blob = :"__obj_pal_#{name}"
          tile_blob = :"__obj_tiles_#{name}"
          @data_blobs[pal_blob] = colors.pack("v*")
          @data_blobs[tile_blob] = tiles
          @objects[name] = {
            slot: slot,
            pal: pal_blob, pal_units: colors.size,
            tiles: tile_blob, tile_units: tiles.bytesize / 32, # sprite memory counts in 32-byte units
            tile_index: tile_unit,
            width: width, height: height,
            x: node[:x], y: node[:y], active: node[:active], # the live position/visibility operands
            attr0_base: OBJ_256_COLOR | (shape << 14),
            attr1_base: size << 14,
          }
        end

        # Pack a sprite's picture into 8-bit tiles the way sprite hardware reads them:
        # 8x8 tiles in reading order (left to right, top to bottom), each tile's 64
        # pixels row by row, every pixel a palette index. A see-through pixel becomes
        # index 0 (the reserved transparent slot); every other color earns the next
        # palette index. Because we use 1D mapping, the tiles simply sit one after
        # another in memory.
        def encode_object_tiles(bmp, palette)
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
                  index = if transparent && color == transparent
                            0
                          else
                            palette[color & 0x7FFF] ||= palette.size + 1
                          end
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
