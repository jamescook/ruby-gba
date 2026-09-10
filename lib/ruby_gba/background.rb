# frozen_string_literal: true

module RubyGBA
  # A handle to a tiled background you can scroll. `background :world, ...` hands one
  # back; move the visible window over the map with `scroll_by` / `scroll_to`:
  #
  #   world = background :world, tiles: :terrain, map: BIG_MAP
  #   game_loop do
  #     wait_vblank
  #     held(:right).then { world.scroll_by 2, 0 }   # slide the view right
  #   end
  #
  # The map is a torus: scroll past an edge and it wraps around, so a map only needs
  # to be as big as the pattern you want to repeat. Scroll it right after `wait_vblank`
  # (the safe window to change the screen) so the whole view moves cleanly together.
  #
  # You never touch a scroll register or think about where the map lives in video
  # memory — you say where the window sits, in pixels, and the framework moves it
  # (the console's own background hardware does it for free).
  class Background
    Build = IR::Build

    # Built by the `background` verb, which allocates the hidden offset variables the
    # window's top-left corner is tracked in.
    #
    # @param builder [Builder] the build these operations record into
    # @param name [Symbol] the background this handle scrolls
    # @param scroll_x [Symbol] the variable holding the window's left edge (in pixels)
    # @param scroll_y [Symbol] the variable holding the window's top edge (in pixels)
    # @param walls [Array<Array(Integer,Integer,Integer,Integer)>] the solid-tile
    #   rectangles [x, y, w, h] in pixels, if the tileset marked any tiles `solid:`
    # @param affine [Boolean] built under `screen :rotozoom` — the console's rotate/scale
    #   layer, which pans by moving the whole matrix (see #rotate / #scale) rather than
    #   the plain scroll registers a `screen :tiled` layer pans with
    # @param cells [Array(Integer, Integer)] how many cells across and down the map is
    # @param tile_index [Hash] each name the map was written in (a tileset character, or
    #   a number from an imported sheet) to the tile it means — what `set_tile` reads
    # @param bitmap [Boolean] declared under `screen :bitmap`, where a background is
    #   stamped into the one picture rather than drawn by tile hardware
    def initialize(builder, name:, scroll_x:, scroll_y:, walls: [], affine: false,
                   cells: [0, 0], tile_index: {}, bitmap: false)
      @builder = builder
      @name = name
      @scroll_x = scroll_x
      @scroll_y = scroll_y
      @walls = walls
      @affine = affine
      @cells = cells
      @tile_index = tile_index
      @bitmap = bitmap
    end

    # PUT A DIFFERENT TILE IN ONE CELL, while the game runs.
    #
    #   room.set_tile 4, 7, "."    # the door is open now
    #   room.set_tile 4, 7, "#"    # ...and shut again
    #
    # A door that opens, a pot that breaks, a wall a bomb takes out, a block the player
    # pushes — every one of those is one tile changing, and without this every one of
    # them has to be a sprite instead, out of a budget a game would rather spend on
    # things that move.
    #
    # +col+ and +row+ are CELL coordinates, not pixels, and either may be something the
    # game works out. The tile is named the way the map was written — one of the
    # tileset's own characters, or a number from an imported sheet — so nothing here is
    # a tile number, a place in video memory, or a moment it is safe to write.
    #
    # A cell outside the map is left alone rather than writing over something else, so a
    # coordinate the game worked out can be off the edge without a test around it.
    def set_tile(col, row, tile)
      refuse_on_a_bitmap_screen!
      index = @tile_index[tile]
      raise ArgumentError, unknown_tile_message(tile) if index.nil?

      record(Build.set_tile(@name, Value.node_for(col), Value.node_for(row), index))
      self
    end

    # How many cells across and down this background's map is — what a game needs to
    # walk it, and what `set_tile` holds a coordinate against.
    def cols = @cells[0]
    def rows = @cells[1]

    # The background's walls as {Box}es a sprite can be tested against — the merged
    # solid-tile rectangles from the tileset's `solid:` tiles. Empty if none were
    # marked solid. A {HardwareSprite} reads these when it's told to be `blocked_by`
    # this background.
    def solid_boxes
      @solid_boxes ||= @walls.map { |x, y, w, h| @builder.box(x, y, w, h) }
    end

    # Slide the view by (+dx+, +dy+) pixels from where it is now — the usual way to
    # scroll as the player moves. dx/dy may be numbers or {Value} expressions.
    def scroll_by(dx, dy)
      ensure_not_affine!("scroll_by")
      record(Build.add(@scroll_x, Value.node_for(dx)))
      record(Build.add(@scroll_y, Value.node_for(dy)))
      apply
    end

    # Put the view's top-left corner at an exact (+x+, +y+) on the map — for snapping
    # the camera to a spot. x/y may be numbers or {Value} expressions.
    def scroll_to(x, y)
      ensure_not_affine!("scroll_to")
      record(Build.set(@scroll_x, Value.node_for(x)))
      record(Build.set(@scroll_y, Value.node_for(y)))
      apply
    end

    # Slide each ROW of the picture sideways by its own amount, so the whole background
    # bends instead of moving as one flat rectangle. The block is given the row (0 at the
    # top of the screen, 159 at the bottom) and gives back how far across that row sits:
    #
    #   ripple = table :ripple, (0...64).map { |i| (Math.sin(i / 64.0 * 2 * Math::PI) * 4).round }
    #   phase  = var :phase, 0
    #
    #   water.scroll_each_row { |row| ripple[(row + phase) % ripple.length] }
    #   game_loop { phase.add 1 }         # the wave travels down the water
    #
    # That is wavy water, a heat haze over a desert, a reflection in a lake, a screen
    # melting into a transition. The offset is ON TOP of the background's own scroll, so a
    # scrolling background can ripple too, and the block is read once for every row of
    # every frame — a `table` lookup is the usual body, because whatever you write there
    # is paid for 160 times a frame.
    #
    # All 160 rows are worked out in the gap between frames, before any of the picture is
    # drawn, which is where a sprite's position is settled too. So a boat riding on the
    # water is showing the same frame the water is.
    #
    # Declare it once, where the background is declared. It keeps running from there, so
    # there is nothing to call each frame; animate it by moving a variable the block reads
    # (the `phase` above). Calling it again on the same background replaces the bend.
    #
    # Rows only bend sideways. A row shows the same part of the map vertically as it
    # always did, which is what a reflection or a haze wants.
    def scroll_each_row(&block)
      unless block
        raise ArgumentError,
              "scroll_each_row needs a block that gives back how far across a row sits: " \
              "#{@name}.scroll_each_row { |row| ripple[row] }"
      end

      @builder.record_row_bend(@name, row_var, &block)
      self
    end

    # Turn the whole background to point +degrees+ clockwise from upright, pivoting on
    # the middle of the screen — the affine counterpart to a sprite's `face_angle`, done
    # to a background layer instead of one picture. +degrees+ can be a whole number or a
    # {Value} (an angle the game works out at run time). Needs `screen :rotozoom` — see
    # {Builder::Tiled#make_background_affine} for why.
    #
    #   world = background :world, tiles: :terrain, map: MAP
    #   world.rotate 15          # tilt the whole picture
    #   world.rotate spin        # or however far `spin` says
    #
    # The angle wraps, so 370 is the same as 10. A background that never turns keeps its
    # upright angle and costs nothing extra.
    def rotate(degrees)
      angle_var, = affine_vars
      fixed = Value.fixed_number(degrees)
      if fixed
        record(Build.set(angle_var, Build.int(fixed % 360)))
      else
        angle.set(degrees)
        wrap_angle
      end
      apply_affine
      self
    end

    # Draw the background bigger or smaller as a whole, about the middle of the screen —
    # the affine counterpart to a sprite's `scale`. 1.0 is the size it was drawn at, 2.0
    # twice as big, 0.5 half — a title screen that zooms in, a warp that zooms out. With
    # no argument it hands back the size as a {Value} you can read, compare and ease
    # (`world.scale.approach 1.0, 0.05`). Needs `screen :rotozoom`.
    def scale(size = nil)
      affine_vars # ensure the size variable exists even if only read below
      return affine_scale_value if size.nil?

      if size.is_a?(Numeric) && size <= 0
        raise ArgumentError,
              "a background's size must be more than 0. You gave #{size.inspect}. " \
              "1.0 is the size it was drawn at, 0.5 is half."
      end
      affine_scale_value.set(size)
      apply_affine
      self
    end

    # The background's heading as a {Value}, degrees clockwise from upright, 0..359.
    # Reading it needs `screen :rotozoom`, same as {#rotate}.
    def angle
      angle_var, = affine_vars
      Value.new(@builder, Build.var_ref(angle_var), name: angle_var)
    end

    private

    # A plain scroll moves a `screen :tiled` layer's own pan registers, which a rotozoom
    # (`screen :rotozoom`) layer doesn't have — it pans by moving its whole matrix instead
    # (see #rotate / #scale). Friendly error rather than a register write that does
    # nothing on real hardware.
    # On `screen :bitmap` a background is stamped into the one picture where it is
    # declared and nothing draws it again, so there is no cell left to change — the
    # pixels are simply part of the picture now. Drawing over them is what a `blit`
    # already does, so that is what the message says.
    def refuse_on_a_bitmap_screen!
      return unless @bitmap

      raise ArgumentError,
            "background :#{@name} was declared under `screen :bitmap`, where a background is " \
            "painted into the picture once — so there is no cell left for set_tile to change. " \
            "Draw over the spot with `blit`, or use `screen :tiled`."
    end

    def unknown_tile_message(tile)
      known = @tile_index.keys.first(8).map(&:inspect).join(", ")
      "background :#{@name} has no tile #{tile.inspect}, so set_tile cannot put one there. Its " \
        "tiles are #{known}#{@tile_index.size > 8 ? ', and more' : ''} — the ones its tileset names."
    end

    def ensure_not_affine!(verb)
      return unless @affine

      raise ArgumentError,
            "#{@name}.#{verb} scrolls a `screen :tiled` background. This one is `screen :rotozoom`, " \
            "which turns and resizes instead of scrolling straight. Use #{@name}.rotate or " \
            "#{@name}.scale here."
    end

    # Allocate (once) and cache this background's angle/scale variables. A friendly
    # error if the screen can't turn or resize a background at all (see
    # Builder::Tiled#make_background_affine).
    def affine_vars
      @affine_vars ||= @builder.make_background_affine(@name)
    end

    # The size variable as a fraction-carrying handle, the same way a sprite's does.
    def affine_scale_value
      _, scale_var = affine_vars
      Value.new(@builder, Build.var_ref(scale_var), name: scale_var,
                          fraction_bits: Fraction::DEFAULT_BITS)
    end

    # A turn past 359 or below 0 wraps around, same as a sprite's #face_angle — see
    # HardwareSprite#wrap_angle, whose exact steps this mirrors.
    def wrap_angle
      a = angle
      a.set(a - (a / 360 * 360))
      (angle < 0).then { angle.add(360) }
    end

    # Write this frame's angle/scale to the display — recorded at the call site, like
    # #apply for a scroll, and moved to the frame boundary at finalize (see
    # Builder#finalize_background_affine) so the console never shows a half-turned frame.
    def apply_affine
      angle_var, scale_var = affine_vars
      node = record(Build.affine_background(@name, angle: Build.var_ref(angle_var), scale: Build.var_ref(scale_var)))
      @builder.record_inline_affine_node(node)
    end

    # The variable the row number is put in before the block's offset is worked out —
    # one per background, so two bending backgrounds cannot tread on each other.
    def row_var
      :"__bg_#{@name}_row"
    end

    # Show the background at its current offset.
    #
    # Moving the view means writing the display's scroll position, and the display
    # reads that position again for every line it draws — so writing it while the
    # picture is being drawn moves only the lines below that point, and the screen
    # tears in half. The safe moment is the gap between frames.
    #
    # Rather than ask a game to know that, the write is made once a frame, in the
    # gap, together with the sprites (see Builder#emit_frame_boundary). Scrolling
    # can then be computed anywhere in a frame, however long the frame's work runs,
    # and it can never tear. The node is still recorded here as well; the builder
    # drops these once it knows the program has a frame boundary to move them to.
    def apply
      node = record(Build.scroll_background(@name, x: Build.var_ref(@scroll_x), y: Build.var_ref(@scroll_y)))
      @builder.scroll_each_frame(@name, @scroll_x, @scroll_y, node)
      self
    end

    def record(node)
      @builder.record_statement(node)
    end
  end
end
