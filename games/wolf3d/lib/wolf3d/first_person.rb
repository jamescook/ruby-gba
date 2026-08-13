# frozen_string_literal: true

module Wolf3D
  # The view down the corridor.
  #
  # For each strip across the screen a ray goes out from the player until it meets a wall. How
  # far it got becomes a height — near walls tall, far walls short — and a column of that wall's
  # picture is stretched to it. Do that across the screen and a flat grid of cells looks like
  # rooms you can walk through.
  class FirstPerson
    # These are the view the game should have, not the view that happens to fit a frame.
    COLUMNS = 80          # strips across the screen...
    COLUMN_W = 3          # ...three pixels each
    TURN = 512            # angle units in a full turn
    QUARTER = TURN / 4
    CROSSINGS = 48        # grid lines a ray may cross before it gives up — about 24 cells

    # HOW WIDE THE VIEW IS, which is one angle unit per strip — about 56 degrees across, near
    # the 60 the original uses.
    #
    # It was two units, and that made a view of 111 degrees. A wide view is not a neutral
    # choice: perspective genuinely stretches whatever is at the edge of it, and at 111
    # degrees the strip at the edge covers three times the world the strip in the middle does,
    # where at 60 degrees it covers one and a third. That stretch is what reads as a bend when
    # you look along a wall rather than at it.
    SPREAD = 1

    # The furthest one crossing can be worth. A ray running almost along an axis meets that
    # axis's lines almost never, and one over almost-nothing is too big to hold — so it is
    # held here, at a distance longer than any crossing on a map this size.
    FAR = 128.0

    TEX = WallAtlas::SIDE # a wall picture is this many columns across...
    PAIR = TEX * 2        # ...and each wall keeps two of them, lit then dark
    HORIZON = 76          # the eye line
    ACROSS = 240          # pixels across the screen

    # HOW TALL A WALL ONE CELL AWAY STANDS, and it is not a free choice. It is the distance
    # from the eye to the screen measured in pixels, and that follows from how wide the view
    # is: a narrower view is a longer lens, and a longer lens makes everything bigger. Pick it
    # independently of SPREAD and the picture is stretched one way or the other — walls too
    # squat for the width of the view, or too tall for it.
    HALF_VIEW = (COLUMNS - 1) * SPREAD / 2.0 # angle units from the middle of the view to its edge
    WALL_SCALE = (ACROSS / 2) / Math.tan(HALF_VIEW * 2 * Math::PI / TURN)

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

      # One over the sine, which is what the walk below needs: how far along a ray it is from
      # one grid line to the next. Worked out here once for every angle rather than divided
      # for every strip of every frame — dividing two numbers that hold a fraction is the
      # dearest arithmetic there is, and reading a table is a fraction of it.
      #
      # INVERTED FROM THE SINE THE GAME WILL ACTUALLY READ, not from the true one. A table
      # holds a number to a fixed number of places, so the sine the walk uses is a hair off
      # the real sine — and if this were the true reciprocal the two would not quite cancel,
      # which shows up as a flat wall whose top edge wanders by a pixel.
      @reach = b.table :reach, (0...TURN).map { |a|
        toward = held(Math.sin(a * 2 * Math::PI / TURN)).abs
        toward > (1.0 / FAR) ? 1.0 / toward : FAR
      }

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

      # Whole numbers: which cell the ray is in, which way it is walking through the grid,
      # which kind of grid line it last crossed, and what came of all that.
      %i[_ang _hit _wall _cell _colh _top _mapx _mapy _stepmx _stepmy _side].each do |name|
        instance_variable_set(:"@#{name.to_s.delete_prefix('_')}", b.var(name, 0))
      end
      # ...and the ones that hold a fraction: where the ray points, how far to each kind of
      # line, how far it has got, and where along the wall it landed.
      %i[_dx _dy _deltax _deltay _sidex _sidey _dist _seen _wallx _nx _ny _stepx _stepy].each do |name|
        instance_variable_set(:"@#{name.to_s.delete_prefix('_')}", b.var(name, 0.0))
      end
    end

    # A number as a table will really hold it, to the places a variable with a fraction keeps.
    def held(number) = RubyGBA::Fraction.scale(number, RubyGBA::Fraction::DEFAULT_BITS) /
                       (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

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

    # One strip: walk a ray out to the wall it meets, then stretch a column of that wall's
    # picture to the height its distance earns.
    #
    # THE WALK GOES FROM GRID LINE TO GRID LINE, and that is the whole idea. A wall stands ON
    # a grid line, so stepping to the next line lands exactly on the surface — which gives
    # the true distance and the true place along the face. Walking in steps of a fixed size
    # instead stops somewhere INSIDE the wall, and has to make do with both: the distance
    # comes out in lumps, and dividing by it turns a lump into a jump of several pixels, so a
    # flat wall arrives as a staircase and its bricks slide about. It is also fewer steps —
    # about two a cell crossed, against eight.
    def cast(col)
      b = @b
      width = @level.width

      @ang.set @view
      @ang.add(col * SPREAD)
      @ang.sub((COLUMNS - 1) * SPREAD / 2)

      # Which way the ray points, and how far along it from one grid line to the next — one
      # answer for the lines running one way, one for the lines running the other.
      @dx.set(@sin[@ang + QUARTER])
      @dy.set(@sin[@ang])
      @deltax.set(@reach[@ang + QUARTER])
      @deltay.set(@reach[@ang])

      @mapx.set @px.to_i
      @mapy.set @py.to_i
      @hit.set 0
      @wall.set 0
      @side.set 0

      # How far to the FIRST line of each kind, which depends on which way the ray leans:
      # leaning back it is what has already been crossed of this cell, leaning forward it is
      # what is left of it.
      (@dx < 0).then do
        @stepmx.set(-1)
        @sidex.set((@px - @mapx.to_f) * @deltax)
      end.else do
        @stepmx.set(1)
        @sidex.set((@mapx.to_f + 1 - @px) * @deltax)
      end
      (@dy < 0).then do
        @stepmy.set(-1)
        @sidey.set((@py - @mapy.to_f) * @deltay)
      end.else do
        @stepmy.set(1)
        @sidey.set((@mapy.to_f + 1 - @py) * @deltay)
      end

      # Take whichever line is nearer, every time. That is all there is to it — and it stops
      # the moment it meets a wall, which is well before the last crossing it is allowed.
      b.repeat(CROSSINGS, stop_when: @hit == 1) do
        (@sidex < @sidey).then do
          @sidex.add @deltax
          @mapx.add @stepmx
          @side.set 0
        end.else do
          @sidey.add @deltay
          @mapy.add @stepmy
          @side.set 1
        end
        @cell.set(@world[(@mapy * width) + @mapx])
        (@cell > 0).then do
          @hit.set 1
          @wall.set @cell
        end
      end

      # The crossing that landed on the wall counted a whole line's worth too far — take that
      # back and what is left reaches the surface itself.
      (@side == 0).then { @dist.set(@sidex - @deltax) }.else { @dist.set(@sidey - @deltay) }

      # Correct for the fan: a ray angled away from centre travels further to reach the same
      # flat wall, and without this a straight wall bows outward at the edges of the view.
      @seen.set(@dist * @sin[(col * SPREAD) + QUARTER - ((COLUMNS - 1) * SPREAD / 2)])

      # The perspective divide, which is the whole trick: a wall twice as far away covers half
      # as much of the screen.
      #
      # NOTHING IS ADDED TO THE DISTANCE AND NOTHING CAPS THE HEIGHT. Both used to be here,
      # and both were lies about perspective that showed at exactly the moment the player
      # could see them best: adding to the distance holds a near wall short, by nearly half at
      # half a cell away, and capping the height stops the wall growing at all in the last
      # stretch before you touch it. They were there because a tall column used to cost every
      # row it had, on screen or not. It costs what shows now, so the height can be what
      # perspective actually says — and a wall you are nose-to-nose with fills the screen with
      # a few enormous bricks, which is right.
      # Rounded to the nearest whole pixel rather than always down. A wall square-on stands at
      # ONE height, and dropping the fraction puts every strip whose height lands exactly on a
      # whole number at the mercy of the last bit — half of them fall to the pixel below and
      # the top edge of a flat wall wanders.
      @colh.set((WALL_SCALE / @seen + 0.5).to_i)
      @top.set HORIZON
      @top.sub(@colh / 2)

      draw_strip(col)
    end

    # WHICH WAY THE FACE TURNS decides two things, and the walk has already answered it: a ray
    # that stepped across a line running one way met a face running that way, and where along
    # that face it landed is the OTHER coordinate of the point it stopped at.
    #
    # Each wall keeps two pictures side by side, the lit one then the darker one, so the same
    # answer picks between them for nothing — which is where the whole game gets its sense of
    # light.
    def draw_strip(col)
      x = (col * COLUMN_W)

      (@side == 0).then do
        @wallx.set(@py + (@dist * @dy))
        strip(x, ((@wall - 1) * PAIR) + texture_column)
      end.else do
        @wallx.set(@px + (@dist * @dx))
        strip(x, ((@wall - 1) * PAIR) + TEX + texture_column)
      end
    end

    # Where along the face the ray landed, as one of the picture's columns: the part of the
    # crossing point that is past the grid line the wall stands on.
    def texture_column = (@wallx * TEX).to_i % TEX

    # The whole strip is one walk down the screen. Its pixels all show the same column of the
    # same picture at the same height, so asking for them one at a time worked the same answer
    # out three times over.
    def strip(x, slice)
      (@hit == 1).then do
        @b.draw_column_at :walls, slice: slice, x: x, top: @top, height: @colh, width: COLUMN_W
      end
    end
  end
end
