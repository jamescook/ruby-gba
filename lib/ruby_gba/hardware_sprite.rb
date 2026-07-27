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
    include Bounds # gains overlaps? from x / y / right / bottom (its image size)

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
    # @param width [Integer] the sprite's pixel width (its image's), for collision bounds
    # @param height [Integer] the sprite's pixel height, for collision bounds
    # @param facing_var [Symbol, nil] the variable holding which pose is showing (faceted only)
    # @param facing_dirs [Hash{Symbol=>Integer}, nil] direction -> pose index (faceted only)
    def initialize(builder, object_name:, x:, y:, active:, width:, height:,
                   facing_var: nil, facing_dirs: nil)
      @builder = builder
      @object_name = object_name
      @x_var = x
      @y_var = y
      @active = active
      @width = width
      @height = height
      @facing_var = facing_var   # the variable the object's pose selector reads
      @facing_dirs = facing_dirs # direction -> pose index, for face / auto-facing move
    end

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

    # The sprite's far edges, as {Value}s — its position plus its image size. These
    # are what make `overlaps?` work on a sprite with no box: `hero.overlaps?(coin)`.
    def right
      x + @width
    end

    def bottom
      y + @height
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
        x.add(step_x * by) unless step_x.zero?
        y.add(step_y * by) unless step_y.zero?
        # A sprite with poses turns to face the way it moves — press left, move AND
        # face left in one call (only for a direction it has a pose for).
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

    def faceted?
      !@facing_var.nil?
    end

    def record(node)
      @builder.record_statement(node)
    end
  end
end
