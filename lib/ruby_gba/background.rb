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
    # @param map_names [Array<Object>] the maps this background was declared with, in
    #   order — what `show_map` names. One entry (the background's own name) for a
    #   background declared with a single map, which can never be handed another.
    def initialize(builder, name:, scroll_x:, scroll_y:, walls: [], affine: false,
                   cells: [0, 0], tile_index: {}, bitmap: false, map_names: nil,
                   solid_cells: [], tile_size: [8, 8])
      @builder = builder
      @name = name
      @scroll_x = scroll_x
      @scroll_y = scroll_y
      @walls = walls
      @solid_cells = solid_cells
      @tile_size = tile_size
      @affine = affine
      @cells = cells
      @tile_index = tile_index
      @bitmap = bitmap
      @map_names = map_names || [name]
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
      refuse_on_a_bitmap_screen!("set_tile", instead: "Draw over the spot with `blit`")
      index = @tile_index[tile]
      raise ArgumentError, unknown_tile_message(tile) if index.nil?

      record(Build.set_tile(@name, Value.node_for(col), Value.node_for(row), index))
      self
    end

    # HAND THE BACKGROUND A WHOLE DIFFERENT MAP, while the game runs.
    #
    #   rooms = background :rooms, tiles: :dungeon, map: { hall: HALL, cave: CAVE }
    #   rooms.show_map :cave       # the whole room is the cave now
    #   rooms.show_map where       # ...or whichever map a number the game holds says
    #
    # This is what walking through a door is in a game with a lot of rooms: a room is a
    # map, and going into one is naming it. Written with `set_tile` instead, the same
    # thing is a cell at a time — hundreds of them, one frame, and a picture showing half
    # of each room while they go in.
    #
    # +which+ is one of the names the background was declared with, or a number counting
    # from 0 in that order — and the number may be something the game works out, which is
    # what a game with hundreds of rooms wants (the room number IS the map number).
    #
    # It says which map is showing rather than doing a copy where you call it, so saying
    # the one already showing costs nothing, and the copy itself happens between frames,
    # when the display is not reading. The picture never shows half of each.
    #
    # THE MAP COMES BACK EXACTLY AS DECLARED. A cell you had changed with `set_tile` — a
    # door you opened — is shut again when you come back to that map. A game that
    # remembers such things opens them again on the way in, which is where it wants that
    # decision anyway.
    def show_map(which)
      refuse_on_a_bitmap_screen!("show_map", instead: "Draw the new picture with `blit`")
      refuse_with_one_map!
      @builder.set(shown_map_var, Value.node_for(number_of_map(which)))
      # Recorded here as well as remembered, the same way a scroll is: a program with no
      # game loop has no gap between frames to hold the copy for, and then the copy simply
      # happens where it was asked for. The builder drops these once it knows there is a
      # frame boundary to move the work to (Builder#finalize_background_maps).
      node = record(Build.show_map(@name, which: Build.var_ref(shown_map_var)))
      @builder.swap_maps_each_frame(@name, shown_map_var, live_map_var, node)
      self
    end

    # Which of this background's maps is showing, as a {Value} — 0 for the first declared.
    # Compare it against {#map_number} to ask which room the game is in.
    def showing
      refuse_with_one_map!
      Value.new(@builder, Build.var_ref(shown_map_var), name: shown_map_var)
    end

    # The number of a map named at declaration — what {#showing} reads back and what
    # {#show_map} is given. A build-time Integer, so it can be compared and counted with.
    def map_number(named)
      at = @map_names.index(named)
      raise ArgumentError, unknown_map_message(named) if at.nil?

      at
    end

    # How many maps this background was declared with. 1 for the ordinary kind.
    def map_count = @map_names.length

    # How many cells across and down this background's map is — what a game needs to
    # walk it, and what `set_tile` holds a coordinate against.
    def cols = @cells[0]
    def rows = @cells[1]

    # The background's walls as {Box}es a sprite can be tested against — the merged
    # solid-tile rectangles of its FIRST map. Empty if nothing is solid. Introspection
    # now rather than the way a mover is stopped: a mover asks the grid (see
    # #solid_lookup), which is what lets the walls follow the map showing.
    def solid_boxes
      @solid_boxes ||= @walls.map { |x, y, w, h| @builder.box(x, y, w, h) }
    end

    # WHERE THE WALLS ARE, as something a mover can ASK rather than something it has to
    # test against piece by piece.
    #
    # A room's walls make some number of rectangles — a bordered room four, a maze of
    # pillars a hundred — and testing a mover's box against each is work that grows with
    # what the room is made of, and is emitted afresh at every place that moves. The same
    # walls as a grid answer "is this cell a wall" in one read, for any room.
    #
    # A BACKGROUND WITH SEVERAL MAPS KEEPS ONE GRID PER MAP, laid end to end, and the
    # mover reads the one that is really in the cells. That is what makes walking through
    # a door work: a room is a map, so the walls in front of you are the walls of the map
    # showing, and a cell that is a wall in the hall can be open floor in the cave. The
    # map to read is worked out once per check rather than once per cell, so a room with
    # several maps costs the same nine reads a room with one does.
    #
    # It reads the map really IN THE CELLS rather than the one the game last asked for.
    # `show_map` copies between frames, so for the one frame in between those differ — and
    # a player can feel being stopped by a wall that is not on screen, where they cannot
    # feel a frame of lag. The walls always agree with the picture.
    #
    # The grid ships as a byte per cell per map of read-only data (a 30x20 room is 600
    # bytes) and is built once however many movers consult it. nil when the tileset marked
    # nothing solid, which is the same thing #solid_boxes says with an empty list.
    def solid_lookup
      return nil if @solid_cells.compact.empty?

      @solid_lookup ||= SolidCells.new(table: @builder.table(:"__solid_#{@name}", flat_walls, width: :byte),
                                       cols: cols, rows: rows,
                                       tile_w: @tile_size[0], tile_h: @tile_size[1],
                                       name: @name, maps: @solid_cells.length,
                                       # length, not one? — a background whose maps mostly have
                                       # no walls still needs the offset, and `one?` counts the
                                       # grids that are THERE rather than the maps.
                                       map_var: @solid_cells.length == 1 ? nil : live_map_var)
    end

    # A background's walls as a grid: the table itself, how big the grid is, how big a
    # cell is, and — for a background with several maps — how many maps are in the table
    # and which variable says which one is live. Everything a mover needs to turn a pixel
    # position into "wall or not". +map_var+ is nil for the ordinary one-map background,
    # whose reads need no map offset at all.
    SolidCells = Data.define(:table, :cols, :rows, :tile_w, :tile_h, :name, :maps, :map_var) do
      def initialize(maps: 1, map_var: nil, **rest) = super

      # Where a map's grid starts in the table.
      def cells_per_map = cols * rows
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
    def refuse_on_a_bitmap_screen!(verb, instead:)
      return unless @bitmap

      raise ArgumentError,
            "background :#{@name} was declared under `screen :bitmap`, where a background is " \
            "painted into the picture once — so there is no cell left for #{verb} to change. " \
            "#{instead}, or use `screen :tiled`."
    end

    # Every map's walls, one grid after another, a byte a cell. A map with no walls of its
    # own contributes a grid of zeros rather than being left out, so finding a map's walls
    # stays arithmetic on where the first one starts — the same bargain the maps themselves
    # make (see Builder#finalize_background_maps).
    def flat_walls
      @solid_cells.flat_map do |grid|
        (0...rows).flat_map { |r| (0...cols).map { |c| grid&.dig(r, c) ? 1 : 0 } }
      end
    end

    # A background with one map is the ordinary kind and can never be handed another —
    # there is only the one. Say what to write to get the other kind.
    def refuse_with_one_map!
      return unless @map_names.one?

      raise ArgumentError,
            "background :#{@name} was declared with one map, so there is no other map to show. " \
            "Declare it with several — `background :#{@name}, tiles: ..., map: { hall: HALL, " \
            "cave: CAVE }` — and then `#{@name}.show_map :cave` hands it one of them."
    end

    # Which map +which+ means: a name it was declared with, or a number counting from 0 in
    # that order. A number the game works out is passed straight through — nothing at build
    # time can say which map it will land on, and a value outside the range is held to it
    # when the swap happens.
    def number_of_map(which)
      return which unless which.is_a?(Symbol) || which.is_a?(String)

      map_number(which)
    end

    # Which map the game SAYS is showing (written by show_map), and which one is really in
    # the background's cells (written by the copy at the frame boundary). Two rather than
    # one because that is what makes the copy happen exactly when the answer changes.
    def shown_map_var = :"__bg_#{@name}_map"
    def live_map_var = :"__bg_#{@name}_live"

    def unknown_map_message(named)
      "background :#{@name} has no map #{named.inspect}. Its maps are " \
        "#{@map_names.map(&:inspect).join(', ')}."
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
