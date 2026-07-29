# frozen_string_literal: true

module RubyGBA
  # A handle to a hardware sprite: a moving picture the console composites over the
  # background for you. You get one from `sprite :hero, at: [x, y]` when the screen
  # is a `screen :tiled` — and it behaves, from the game's side, exactly like the
  # software {Sprite} you get in `screen :bitmap`. Same handle, same code:
  #
  #   screen :tiled
  #   background :room, tiles: :dungeon, map: ...   # the scene behind the sprite
  #   hero = sprite :hero, at: [100, 60]
  #   game_loop do
  #     wait_vblank
  #     held(:right).then { hero.x.add 2 }          # steer with the expression DSL
  #     # no draw call — the framework draws the sprite for you each frame
  #   end
  #
  # The difference from a software sprite is under the hood and in your favor. A
  # software sprite has to remember and repaint the pixels underneath itself so it
  # leaves no trail; a hardware sprite doesn't, because the console redraws the
  # whole picture — background and sprites — every frame from scratch. That means it
  # costs no per-pixel work to move, and (in a later slice) sprites can stack over
  # each other with a set order, which software save-under can't do. The trade is
  # that it only exists on a `screen :tiled`, drawn from tiles.
  #
  # You don't call a draw verb. Builder#wait_vblank draws every hardware sprite once
  # per frame, during the vertical blank — the brief safe window to change the
  # screen — so moving one is just changing `x`/`y`, and it shows on the next frame.
  class HardwareSprite
    include Bounds       # gains overlaps? from left / top / right / bottom (its collision box)
    include PixelBounds  # ...and makes that overlaps? shape-accurate (per-pixel) by default

    Build = IR::Build

    # Built by Builder#hardware_sprite, which reserves the object name, boots the
    # position/visibility variables, and records the object declaration. The names
    # passed here are hidden state the player never sees; `x`/`y` expose the position.
    #
    # @param builder [Builder] the build these operations record into
    # @param object_name [Symbol] the declared object this handle steers
    # @param x [Symbol] the variable holding the sprite's current x (exposed as #x)
    # @param y [Symbol] the variable holding its current y (exposed as #y)
    # @param active [Symbol] 1 while shown, 0 while hidden
    # @param hitbox [Array(Integer,Integer,Integer,Integer)] the collision box [x, y, w, h]
    #   relative to the sprite's top-left (by default the box around its visible pixels)
    # @param poses [Array<Symbol>] the sprite's picture(s), for the per-pixel collision test
    # @param pixel_perfect [Boolean] collide on the drawn pixels (true) or just the box (false,
    #   set when the sprite was given an explicit hitbox:)
    # @param facing_var [Symbol, nil] the variable holding which pose is showing (faceted only)
    # @param facing_dirs [Hash{Symbol=>Integer}, nil] direction -> pose index (faceted only)
    def initialize(builder, object_name:, x:, y:, active:, hitbox:, poses:, pixel_perfect:,
                   facing_var: nil, facing_dirs: nil)
      @builder = builder
      @object_name = object_name
      @x_var = x
      @y_var = y
      @active = active
      @hit_x, @hit_y, @hit_w, @hit_h = hitbox # collision box, offset from the sprite's top-left
      @poses = poses             # the picture(s) the per-pixel collision test reads
      @pixel_perfect = pixel_perfect
      @facing_var = facing_var   # the variable the object's pose selector reads
      @facing_dirs = facing_dirs # direction -> pose index, for face / auto-facing move
      @walls = nil               # solid-tile Boxes this sprite is blocked by (nil until blocked_by)
    end

    # What per-pixel collision (see {PixelBounds}) reads off this sprite: the build to
    # record into, its picture set, the pose it's showing now, and whether it collides
    # on its drawn pixels at all.
    def pixel_perfect? = @pixel_perfect
    def collision_builder = @builder
    def collision_poses = @poses
    def collision_pose = @facing_var ? Build.var_ref(@facing_var) : Build.int(0)

    # The object this handle drives — Builder#wait_vblank lists it for the per-frame
    # draw.
    attr_reader :object_name

    # The sprite's position, as {Value} handles — steer them with the expression DSL
    # (`hero.x.add 2`, `hero.y.clamp 0, 150`). The framework reads them each frame to
    # know where to draw.
    def x
      Value.new(@builder, Build.var_ref(@x_var), name: @x_var)
    end

    def y
      Value.new(@builder, Build.var_ref(@y_var), name: @y_var)
    end

    # The sprite's collision-box edges, as {Value}s — its position plus its hitbox
    # (by default the box hugging its visible pixels). These are what make `overlaps?`
    # work on a sprite with no box of its own: `hero.overlaps?(coin)`.
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

    # Move the sprite, the same two ways a software {Sprite} moves: a named direction
    # (turned into x/y arithmetic for you, with `by:` the speed), or a raw (dx, dy)
    # nudge for velocity/physics.
    #
    #   hero.move :left            # a step left
    #   hero.move :up_right, by: 3 # diagonals, three pixels at a time
    #   hero.move 2, -1            # or a raw (dx, dy)
    def move(direction_or_dx, dy = nil, by: 1)
      if direction_or_dx.is_a?(Symbol)
        step_x, step_y = Direction.unit(direction_or_dx)
        step(:x, step_x * by) unless step_x.zero?
        step(:y, step_y * by) unless step_y.zero?
        # A sprite with poses turns to face the way it moves — press left, move AND
        # face left in one call (only for a direction it has a pose for).
        face(direction_or_dx) if faceted? && @facing_dirs.key?(direction_or_dx)
      else
        step(:x, direction_or_dx) if direction_or_dx != 0
        step(:y, dy) if dy && dy != 0
      end
      self
    end

    # Stop this sprite from moving through +background+'s wall tiles — the ones its
    # tileset marked `solid:`. After this, `move` is checked automatically: a step that
    # would put the sprite into a wall simply doesn't happen, so it slides along walls
    # and stops at them with no collision code of your own.
    #
    #   world = background :maze, tiles: :bricks, map: MAZE   # bricks marked solid:
    #   hero  = sprite :hero, at: [24, 24]
    #   hero.blocked_by world
    #   game_loop do
    #     wait_vblank
    #     held(:right).then { hero.move :right }   # walks until a wall, then stops
    #   end
    #
    # You keep full manual control too: `can_move?` asks before moving so you can do
    # your own thing when blocked, and the raw position ops (`move_to`, `x`/`y`) are
    # never checked — an escape hatch for teleports and scripted moves.
    def blocked_by(background)
      @walls = background.solid_boxes
      self
    end

    # Whether this sprite could step +by+ pixels in +direction+ without hitting a wall
    # — a {Condition} to branch on, for taking collision into your own hands:
    #
    #   hero.can_move?(:left).then { hero.move :left }   # or do something else if not
    #
    # Needs `blocked_by` to have named the walls first.
    def can_move?(direction, by: 1)
      raise ArgumentError, "call blocked_by(background) before can_move? — it needs to know the walls" if @walls.nil?

      step_x, step_y = Direction.unit(direction)
      clear_of_walls(x + (step_x * by), y + (step_y * by))
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
    # Only for a sprite given `facing:` poses, and only a direction it has a pose for
    # — anything else is a friendly error. On hardware this swaps which uploaded
    # picture the console draws; the change shows on the next frame.
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

    # Hide the sprite: it stops being drawn (its table slot is marked unused) and
    # vanishes on the next frame, its spot in the layering held for when it returns.
    # `show` brings it back at its current position. Setting the flag is all it takes
    # — the per-frame draw reads it — so hiding an already-hidden sprite is harmless.
    def hide
      record(Build.set(@active, Build.int(0)))
      self
    end

    def show
      record(Build.set(@active, Build.int(1)))
      self
    end

    private

    # Move +delta+ pixels along one axis. With no walls it's a plain nudge; blocked, it
    # happens only if the sprite's box at the destination is clear of every wall (each
    # axis checked on its own, so the sprite can still slide along a wall it's pressed
    # against).
    def step(axis, delta)
      var = axis == :x ? x : y
      return var.add(delta) if @walls.nil? || @walls.empty?

      target_x = axis == :x ? x + delta : x
      target_y = axis == :y ? y + delta : y
      clear_of_walls(target_x, target_y).then { var.add(delta) }
    end

    # A {Condition} true when the sprite's box, placed at (target_x, target_y), doesn't
    # overlap any wall. "Doesn't overlap" is separated on some axis — the destination
    # ends at or before a wall begins, or begins at or after it ends — so a sprite can
    # rest flush against a wall (touching isn't overlapping) yet never cross into one.
    def clear_of_walls(target_x, target_y)
      left = target_x + @hit_x
      top = target_y + @hit_y
      right = left + @hit_w
      bottom = top + @hit_h
      @walls.map do |wall|
        (right <= wall.x) | (wall.right <= left) | (bottom <= wall.y) | (wall.bottom <= top)
      end.reduce(:&)
    end

    def faceted?
      !@facing_var.nil?
    end

    def record(node)
      @builder.record_statement(node)
    end
  end
end
