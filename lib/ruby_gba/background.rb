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
    def initialize(builder, name:, scroll_x:, scroll_y:)
      @builder = builder
      @name = name
      @scroll_x = scroll_x
      @scroll_y = scroll_y
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

    private

    # Show the background at its current offset. Recorded where scroll is called (right
    # after wait_vblank, in the safe window), so the view moves this frame.
    def apply
      @builder.note_background_scrolled
      record(Build.scroll_background(@name, x: Build.var_ref(@scroll_x), y: Build.var_ref(@scroll_y)))
      self
    end

    def record(node)
      @builder.record_statement(node)
    end
  end
end
