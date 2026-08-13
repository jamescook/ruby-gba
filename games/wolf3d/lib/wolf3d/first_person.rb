# frozen_string_literal: true

module Wolf3D
  # The view down the corridor.
  #
  # For each strip across the screen a ray goes out from the player until it meets a wall. How
  # far it got becomes a height — near walls tall, far walls short — and a column of that wall's
  # picture is stretched to it. Do that across the screen and a flat grid of cells looks like
  # rooms you can walk through.
  class FirstPerson
    # These are the view the game should have, not the view that happens to fit a frame. What
    # they cost is measured and reported rather than tuned away: the cost model prices this
    # build at more than the 228 scanlines a frame has, so the console does not finish it in
    # one, and on a single-buffered screen an unfinished frame is a picture drawn part way
    # across — which is exactly the tearing `tear_free:` exists to remove.
    #
    # Correctness is separate and settled: drawn few enough strips that the console finishes,
    # the two backends agree on every one of the 38,400 pixels. What is missing is somewhere to
    # draw it that does not show a half-finished frame.
    COLUMNS = 80          # strips across the screen...
    COLUMN_W = 3          # ...three pixels each
    TURN = 512            # angle units in a full turn
    QUARTER = TURN / 4
    SPREAD = 2            # angle units between one strip and the next
    STEPS = 40            # how far a ray looks before giving up...
    PER_CELL = 8          # ...an eighth of a cell at a time, so five cells of sight
    HORIZON = 76          # the eye line
    WALL_SCALE = 70.0     # how tall a wall one cell away stands
    SOFTEN = 0.3
    MIN_H = 2
    MAX_H = 200
    WALK = 0.07
    TURN_SPEED = 6

    CEILING = RubyGBA::Color.rgb(7, 7, 9)
    FLOOR_COLOR = RubyGBA::Color.rgb(12, 11, 10)

    def initialize(build, level, atlas)
      @b = build
      @level = level
      @atlas = atlas
      declare
    end

    # One frame: the room, then a wall column per strip.
    def update
      @b.dma_fill_rect 0, 0, 240, HORIZON, CEILING
      @b.dma_fill_rect 0, HORIZON, 240, 160 - HORIZON, FLOOR_COLOR
      walk
      @b.repeat(COLUMNS) { |col| cast(col) }
    end

    private

    def declare
      b = @b
      @sin = b.table :sin, (0...TURN).map { |a| Math.sin(a * 2 * Math::PI / TURN) }

      # The map as one flat table: which of the atlas's walls stands in each cell, counting
      # from one, and 0 for open floor.
      @world = b.table :world, @level.each_cell.map { |x, y|
        @level.solid?(x, y) ? (@atlas.codes.index(@level.wall_code(x, y)) || 0) + 1 : 0
      }, width: :byte

      b.image :walls, width: @atlas.width, height: @atlas.height, data: @atlas.pixels

      start = @level.start
      @px = b.var :px, start.x + 0.5
      @py = b.var :py, start.y + 0.5
      @view = b.var :view, facing_angle(start.facing)

      @ang = b.var :_ang, 0
      @hit = b.var :_hit, 0
      @wall = b.var :_wall, 0
      @cell = b.var :_cell, 0
      @colh = b.var :_colh, 0
      @top = b.var :_top, 0
      @offx = b.var :_offx, 0
      @offy = b.var :_offy, 0
      %i[_dx _dy _rx _ry _dist _seen _nx _ny _stepx _stepy].each do |name|
        instance_variable_set(:"@#{name.to_s.delete_prefix('_')}", b.var(name, 0.0))
      end
    end

    # Plane 1 says which way the player starts; the angle table runs clockwise from east.
    def facing_angle(facing)
      { east: 0, south: QUARTER, west: QUARTER * 2, north: QUARTER * 3 }.fetch(facing)
    end

    def walk
      b = @b
      b.held(:left).then { @view.sub TURN_SPEED }
      b.held(:right).then { @view.add TURN_SPEED }

      @stepx.set(@sin[@view + QUARTER] * WALK)
      @stepy.set(@sin[@view] * WALK)
      b.held(:down).then { @stepx.flip }
      b.held(:down).then { @stepy.flip }

      (b.held(:up) | b.held(:down)).then do
        # Each direction is tried on its own, so a player pressed against a wall slides along
        # it instead of stopping dead — one of the two moves still lands.
        @nx.set @px
        @nx.add @stepx
        (@world[(@py.to_i * @level.width) + @nx.to_i] == 0).then { @px.set @nx }

        @ny.set @py
        @ny.add @stepy
        (@world[(@ny.to_i * @level.width) + @px.to_i] == 0).then { @py.set @ny }
      end
    end

    # One strip: march a ray, then stretch a column of whatever it met.
    def cast(col)
      b = @b
      width = @level.width

      @ang.set @view
      @ang.add(col * SPREAD)
      @ang.sub((COLUMNS - 1) * SPREAD / 2)

      @dx.set(@sin[@ang + QUARTER] * (1.0 / PER_CELL))
      @dy.set(@sin[@ang] * (1.0 / PER_CELL))
      @rx.set @px
      @ry.set @py
      @hit.set 0
      @wall.set 0
      @dist.set(STEPS.to_f / PER_CELL)

      # Stop at the first wall. Every step after that is spent proving nothing, which is what
      # `stop_when` is for — a ray meets a wall well before its fortieth step.
      b.repeat(STEPS, stop_when: @hit == 1) do |step|
        @rx.add @dx
        @ry.add @dy
        @cell.set(@world[(@ry.to_i * width) + @rx.to_i])
        (@cell > 0).then do
          @hit.set 1
          @wall.set @cell
          @dist.set(step * (1.0 / PER_CELL))
        end
      end

      # Correct for the fan: a ray angled away from centre travels further to reach the same
      # flat wall, and without this a straight wall bows outward at the edges of the view.
      @seen.set(@dist * @sin[(col * SPREAD) + QUARTER - ((COLUMNS - 1) * SPREAD / 2)])

      # The perspective divide, which is the whole trick: a wall twice as far away covers half
      # as much of the screen.
      @colh.set((WALL_SCALE / (@seen + SOFTEN)).to_i)
      @colh.clamp MIN_H, MAX_H
      @top.set HORIZON
      @top.sub(@colh / 2)

      draw_strip(col)
    end

    # WHICH WAY THE WALL FACES decides two things, and getting it wrong is what makes a wall
    # look like torn paper: which coordinate says where along the face the ray landed, and
    # which of the wall's two pictures to use.
    #
    # A ray that crossed mostly sideways met a face running north-south, and how far DOWN that
    # face it landed is its y; one that crossed mostly up or down met an east-west face, and
    # the answer is its x. Telling them apart is asking which coordinate moved further into
    # the cell it stopped in.
    def draw_strip(col)
      x = (col * COLUMN_W)

      # How far into its cell each coordinate ended up, measured from the middle, in the same
      # 64ths the picture is 64 columns of. Whichever moved further is the one that crossed a
      # face, and the other one says where along that face the ray landed.
      @offx.set(((@rx * 64).to_i % 64) - 32)
      @offx.abs
      @offy.set(((@ry * 64).to_i % 64) - 32)
      @offy.abs

      # Each wall keeps two pictures side by side, the lit one then the darker one, so the
      # face's direction picks between them for nothing — which is where the whole game gets
      # its sense of light.
      (@offx > @offy).then do
        strip(x, ((@wall - 1) * 128) + ((@ry * 64).to_i % 64))
      end.else do
        strip(x, ((@wall - 1) * 128) + 64 + ((@rx * 64).to_i % 64))
      end
    end

    def strip(x, slice)
      COLUMN_W.times do |dx|
        (@hit == 1).then do
          @b.draw_column_at :walls, slice: slice, x: x + dx, top: @top, height: @colh
        end
      end
    end
  end
end
