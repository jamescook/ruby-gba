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
  # which is injected right after each `wait_vblank` in your game loop. The repaint
  # goes in two passes over all the sprites — every one is erased from where it was,
  # then every one is drawn where it is now — so sprites can pass over or touch each
  # other (a hero picking up a coin) without smearing, because each captures clean
  # background and never a neighbour that hasn't been erased yet. Moving a sprite is
  # therefore just changing its position — `hero.x`/`hero.y` are the usual {Value}
  # handles, so the whole add/sub/clamp/set vocabulary drives them — and the move
  # shows up on the next frame.
  #
  # `hide` restores the pixels under the sprite and stops repainting it, so it
  # vanishes with no trace; `show` brings it back at its current position. That
  # save-underneath is exactly what lets it leave cleanly.
  #
  # A sprite clips at the screen edges (it can slide half off a side rather than
  # wrap or vanish). What software save-underneath still can't do is keep two sprites
  # stably STACKED — held one on top of the other with a set priority; that's the
  # hardware-sprite feature. Passing, touching, and colliding are fine.
  class Sprite
    include Bounds       # gains overlaps? from left / top / right / bottom (its collision box)
    include PixelBounds  # ...and makes that overlaps? shape-accurate (per-pixel) by default

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
    # @param hitbox [Array(Integer,Integer,Integer,Integer)] the collision box [x, y, w, h]
    #   relative to the sprite's top-left (by default the box around its visible pixels)
    # @param pixel_perfect [Boolean] collide on the drawn pixels (true) or just the box (false,
    #   set when the sprite was given an explicit hitbox:)
    def initialize(builder, x:, y:, old_x:, old_y:, active:, buffer:, hitbox:, pixel_perfect: true,
                   image: nil, poses: nil, facing_var: nil, facing_dirs: nil,
                   frame_var: nil, frames_per_dir: 1,
                   clips: nil, clip_off_var: nil, clip_len_var: nil)
      @builder = builder
      @image = image             # a plain sprite draws this one image
      @poses = poses             # a faceted sprite draws poses[pose index] instead
      @pixel_perfect = pixel_perfect
      @facing_var = facing_var   # the variable holding the facing (or the single pose selector)
      @facing_dirs = facing_dirs # direction -> facing index, for face / auto-facing move
      @frame_var = frame_var     # a directional-animation OR named-clip frame variable; nil otherwise
      @frames_per_dir = frames_per_dir # frames per direction (1 unless a directional animation)
      @clips = clips             # named animations from an Aseprite sheet (name -> {off, len}); nil otherwise
      @clip_off_var = clip_off_var # the current clip's start offset (a named-clip sprite)
      @clip_len_var = clip_len_var # the current clip's length
      @x_var = x
      @y_var = y
      @old_x = old_x
      @old_y = old_y
      @active = active
      @buffer = buffer
      @hit_x, @hit_y, @hit_w, @hit_h = hitbox # collision box, offset from the sprite's top-left
    end

    # What per-pixel collision (see {PixelBounds}) reads off this sprite: the build to
    # record into, its picture set, the pose it's showing now, and whether it collides
    # on its drawn pixels at all.
    def pixel_perfect? = @pixel_perfect
    def collision_builder = @builder
    def collision_poses = @poses || [@image]
    def collision_pose = pose_index_node

    # Which pose to show right now, as a value node. A plain sprite is pose 0. A facing
    # or frames sprite is its selector. A directional animation composes the two, so the
    # frame animates within whichever direction the sprite faces (facing *
    # frames_per_direction + frame). A named-clip sprite (from Aseprite) is the current
    # clip's start offset plus the frame within it.
    def pose_index_node
      return Build.binop(:+, Build.var_ref(@clip_off_var), Build.var_ref(@frame_var)) if @clip_off_var
      return Build.int(0) unless @facing_var
      return Build.var_ref(@facing_var) unless @frame_var

      Build.binop(:+, Build.binop(:*, Build.var_ref(@facing_var), Build.int(@frames_per_dir)),
                  Build.var_ref(@frame_var))
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

    # The sprite's collision-box edges, as {Value}s — its position plus its hitbox (by
    # default the box hugging its visible pixels). These are what make `overlaps?` work
    # on a sprite with no box of its own: `hero.overlaps?(coin)`.
    def left
      x + @hit_x
    end

    def top
      y + @hit_y
    end

    def right
      x + @hit_x + @hit_w
    end

    def bottom
      y + @hit_y + @hit_h
    end

    # Move the sprite. Two ways, whichever reads better where you are:
    #
    #   hero.move :left            # a step left (from the player's point of view)
    #   hero.move :left, by: 2     # ... two pixels at a time
    #   hero.move :up_right, by: 3 # diagonals too
    #   hero.move 2, -1            # or a raw (dx, dy) nudge, for velocity/physics
    #
    # The named form turns a direction into the x/y arithmetic for you, so pressing
    # left just says "move left" — see {Direction}. `by:` is the speed (1 by
    # default). The raw form takes a dx and dy directly.
    def move(direction_or_dx, dy = nil, by: 1)
      if direction_or_dx.is_a?(Symbol)
        step_x, step_y = Direction.unit(direction_or_dx)
        x.add(step_x * by) unless step_x.zero?
        y.add(step_y * by) unless step_y.zero?
        # A sprite with poses turns to face the way it moves — press left, move AND
        # face left in one call. (Only for a direction it actually has a pose for.)
        face(direction_or_dx) if faceted? && @facing_dirs.key?(direction_or_dx)
      else
        x.add(direction_or_dx)
        y.add(dy) if dy && dy != 0
      end
      self
    end

    # Jump the sprite to an exact spot — sugar for x.set / y.set.
    def move_to(px, py)
      x.set(px)
      y.set(py)
      self
    end

    # Keep the sprite fully on the screen: pin its position so its box never crosses
    # an edge, worked out from the sprite's own size — no coordinate literals. The
    # counterpart to the off-screen tests ({Bounds#off_screen?} and friends): call it
    # after a move to pen a player inside the play field. Clamps x/y in place, returns
    # self. (It keeps the sprite's collision box on screen; a transparent margin around
    # the art may still slide off, which is what you want.)
    def clamp_to_screen
      x.clamp(-@hit_x, IR::Screen::WIDTH - @hit_x - @hit_w)
      y.clamp(-@hit_y, IR::Screen::HEIGHT - @hit_y - @hit_h)
      self
    end
    alias stay_on_screen clamp_to_screen

    # Turn the sprite to face a direction, swapping to that pose in place (no move).
    # Only for a sprite given `facing:` poses, and only a direction it has a pose
    # for — anything else is a friendly error. The pose shows on the next frame,
    # like any other change.
    def face(direction)
      unless faceted?
        raise ArgumentError,
              "this sprite has no poses to face with — give it `facing: { left: :img_l, right: :img_r, ... }`"
      end
      index = @facing_dirs[direction] or
        raise ArgumentError, "this sprite cannot face #{direction.inspect} — it faces #{@facing_dirs.keys.join(', ')}"

      record(Build.set(@facing_var, Build.int(index)))
      self
    end

    # Play a named animation from the sprite's Aseprite sheet (a frameTag). It runs from
    # its first frame and loops until you play another one. Only for a sprite made with
    # `from_aseprite:`, and only a name the sheet defines — anything else is a friendly
    # error. Switching is instant; the new animation shows from the next frame.
    def play(clip)
      raise ArgumentError, "this sprite has no named animations to play — make it with `sprite ..., from_aseprite: \"file.json\"`" unless @clips

      info = @clips[clip] or
        raise ArgumentError, "this sprite has no animation #{clip.inspect} — it has #{@clips.keys.join(', ')}"

      record(Build.set(@clip_off_var, Build.int(info[:off])))
      record(Build.set(@clip_len_var, Build.int(info[:len])))
      record(Build.set(@frame_var, Build.int(0)))
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

    # The per-frame repaint runs in two passes across every sprite (see
    # Builder#wait_vblank): first each sprite is erased from where it was, then each
    # is drawn where it is now. Splitting it this way is what lets sprites overlap
    # cleanly — every sprite is gone before any capture happens, so one never grabs
    # another's pixels (which would smear when it later moves off). These two nodes
    # are the two passes.

    # Pass one: erase this sprite from where it was last drawn, restoring what it
    # covered. A no-op while the sprite is hidden.
    def erase_node
      Build.if_(active_is(1), Build.restore_region(@buffer, ref(@old_x), ref(@old_y)))
    end

    # Pass two: draw this sprite where it is now, remembering what's freshly under it
    # so the next frame's erase can put it back. A no-op while hidden.
    def draw_node
      Build.if_(active_is(1), *draw_at_current)
    end

    # Draw the sprite for the first time at its start (used by the sprite verb when
    # the sprite begins shown): capture what's under it and draw it there.
    def draw_initial
      draw_at_current.each { |node| record(node) }
      self
    end

    private

    def faceted?
      !@poses.nil?
    end

    # Capture what's under the current spot, draw the sprite there, and record that
    # spot as where it was last drawn (so the next erase targets it).
    def draw_at_current
      [Build.save_region(@buffer, ref(@x_var), ref(@y_var)),
       blit_op(ref(@x_var), ref(@y_var)),
       Build.copy(@old_x, @x_var),
       Build.copy(@old_y, @y_var)]
    end

    # The draw op for the sprite's image: a plain blit, or — if it has poses — a
    # blit of whichever pose it's currently facing.
    def blit_op(x_node, y_node)
      if faceted?
        Build.blit_pose(@poses, pose_index_node, x_node, y_node)
      else
        Build.blit(@image, x_node, y_node)
      end
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
