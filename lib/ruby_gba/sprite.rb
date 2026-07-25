# frozen_string_literal: true

module RubyGBA
  # A handle to a sprite: a named image with a position it owns, that moves around
  # the screen leaving no trail. `sprite :heart, at: [x, y]` hands one back.
  #
  #   hero = sprite :heart, at: [100, 60]
  #   game_loop do
  #     wait_vblank
  #     held(:left).then  { hero.x.sub 2 }   # steer with the ordinary expression DSL
  #     held(:right).then { hero.x.add 2 }
  #     # no draw call — the framework repaints the sprite for you (see below)
  #   end
  #
  # What makes a sprite different from a plain `blit` is that it *remembers the
  # pixels underneath itself*. Before it's drawn at a spot it saves what was there;
  # when it moves, it paints those pixels back before drawing at the new spot. So it
  # works over any background — scenery, a flat field, another sprite — and never
  # smears a trail, and you never clear and redraw the whole screen (which is what
  # tears once there's enough on screen).
  #
  # You don't call a draw verb. The framework repaints every visible sprite once per
  # frame, during the vertical blank (the brief safe window to change the screen),
  # which is injected right after each `wait_vblank` in your game loop. Moving a
  # sprite is therefore just changing its position — `hero.x`/`hero.y` are the usual
  # {Value} handles, so the whole add/sub/clamp/set vocabulary drives them — and the
  # move shows up on the next frame.
  #
  # `hide` restores the pixels under the sprite and stops repainting it, so it
  # vanishes with no trace; `show` brings it back at its current position. That
  # save-underneath is exactly what lets it leave cleanly.
  #
  # A sprite clips at the screen edges (it can slide half off a side rather than
  # wrap or vanish). Overlapping sprites can smear each other — software
  # save-underneath has no true layering — so v1 is for a handful of non-overlapping
  # movers (the ball, the player, the food); stacked, prioritized sprites are the
  # hardware-sprite feature.
  class Sprite
    Build = IR::Build

    # Built by Builder#sprite, which allocates the hidden variables and the backing
    # store and wires the boot-time draw. All the names it passes are hidden state
    # the player never sees; the position pair is what `x`/`y` expose.
    #
    # @param builder [Builder] the build these operations record into
    # @param image [Symbol] the defined image drawn for this sprite
    # @param x [Symbol] the variable holding the sprite's current x (exposed as #x)
    # @param y [Symbol] the variable holding its current y (exposed as #y)
    # @param old_x [Symbol] where it was last drawn, so a move can erase there first
    # @param old_y [Symbol] the y half of the last-drawn position
    # @param active [Symbol] 1 while shown, 0 while hidden (guards the repaint)
    # @param buffer [Symbol] the backing store holding the pixels under the sprite
    def initialize(builder, image:, x:, y:, old_x:, old_y:, active:, buffer:)
      @builder = builder
      @image = image
      @x_var = x
      @y_var = y
      @old_x = old_x
      @old_y = old_y
      @active = active
      @buffer = buffer
    end

    # The sprite's position, as {Value} handles — steer them with the expression
    # DSL (`hero.x.add 2`, `hero.y.clamp 0, 150`). The framework reads them each
    # frame to know where to draw.
    def x
      Value.new(@builder, Build.var_ref(@x_var), name: @x_var)
    end

    def y
      Value.new(@builder, Build.var_ref(@y_var), name: @y_var)
    end

    # Nudge the sprite by (dx, dy) this frame — sugar for x.add / y.add.
    def move(dx, dy)
      x.add(dx)
      y.add(dy)
      self
    end

    # Jump the sprite to an exact spot — sugar for x.set / y.set.
    def move_to(px, py)
      x.set(px)
      y.set(py)
      self
    end

    # Make the sprite vanish cleanly: put back the pixels it was covering and stop
    # repainting it. Guarded so hiding an already-hidden sprite does nothing.
    def hide
      record(Build.if_(active_is(1),
                       Build.restore_region(@buffer, ref(@old_x), ref(@old_y)),
                       Build.set(@active, Build.int(0))))
      self
    end

    # Bring a hidden sprite back at its current position: re-capture the pixels
    # there and draw it, then let the per-frame repaint resume. Guarded so showing
    # an already-visible sprite does nothing.
    def show
      record(Build.if_(active_is(0),
                       Build.set(@active, Build.int(1)),
                       *draw_at_current))
      self
    end

    # The per-frame repaint, injected after each wait_vblank (see Builder#wait_vblank).
    # While shown: erase the sprite from where it was (restore what it covered), then
    # draw it where it is now (remembering what's newly under it). A no-op frame when
    # it hasn't moved just re-draws it in place.
    def repaint_node
      Build.if_(active_is(1),
                Build.restore_region(@buffer, ref(@old_x), ref(@old_y)),
                *draw_at_current)
    end

    private

    # Capture what's under the current spot, draw the sprite there, and record that
    # spot as where it was last drawn (so the next erase targets it).
    def draw_at_current
      [Build.save_region(@buffer, ref(@x_var), ref(@y_var)),
       Build.blit(@image, ref(@x_var), ref(@y_var)),
       Build.copy(@old_x, @x_var),
       Build.copy(@old_y, @y_var)]
    end

    def record(node)
      @builder.record_statement(node)
    end

    def ref(name)
      Build.var_ref(name)
    end

    def active_is(value)
      Build.binop(:==, ref(@active), Build.int(value))
    end
  end
end
