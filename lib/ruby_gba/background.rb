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
    def initialize(builder, name:, scroll_x:, scroll_y:, walls: [])
      @builder = builder
      @name = name
      @scroll_x = scroll_x
      @scroll_y = scroll_y
      @walls = walls
    end

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
      record(Build.add(@scroll_x, Value.node_for(dx)))
      record(Build.add(@scroll_y, Value.node_for(dy)))
      apply
    end

    # Put the view's top-left corner at an exact (+x+, +y+) on the map — for snapping
    # the camera to a spot. x/y may be numbers or {Value} expressions.
    def scroll_to(x, y)
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

    private

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
