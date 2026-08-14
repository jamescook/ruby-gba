# frozen_string_literal: true

module Wolf3D
  # EVERYTHING THAT STANDS IN THE LEVEL, and how it gets on the screen: the guards, and the
  # lamps and barrels and bones they stand among.
  #
  # None of it is a wall, and all of it is drawn the same way. A thing standing in the world is
  # a flat picture always turned to face you — a billboard — and putting one on the screen is
  # two numbers: how far in front of the eye it is, which decides its size, and how far to the
  # side of the line you are looking down, which decides where it lands across the screen. Then
  # it is drawn as strips of a stretched picture exactly as a wall is.
  #
  # WHY IT IS NOT A HARDWARE SPRITE, which the console would draw for free: the console composes
  # sprites over the picture and knows nothing about what the picture means, so a guard standing
  # behind a pillar would be drawn in front of it. Depth is the whole problem here, and only the
  # thing that drew the walls knows how far away each strip of them ended up.
  #
  # WHAT LIVES HERE AND WHAT DOES NOT: this puts things on the screen. Where a guard is going
  # and what he is thinking about is the mind's business, and the view's own business is walls.
  class Billboards
    # HOW FAR FORWARD A STANDING THING IS NUDGED before its distance is used. A guard stands in
    # the middle of his cell, so half of him is in the cell behind — which can be a wall, and
    # then the wall would be drawn over his front. Moving him a quarter of a cell toward the eye
    # settles it, and it is what the original does.
    NUDGE = 0.25

    # ...and scenery is nudged half as far, which is also the original's number. A lamp is a
    # thinner thing than a man, and it stands where it was put rather than walking up to a wall.
    SCENERY_NUDGE = 0.125

    # How near a thing can get before it is not drawn at all. The height is one over the
    # distance, so a thing at arm's length is thousands of pixels tall and one at nothing at all
    # does not fit in a number.
    NEAREST = 0.34

    # HOW FAR AWAY EACH STRIP OF THE SCREEN ENDED UP, kept as the HEIGHT the strip was drawn at
    # rather than as a distance. The two say the same thing — a wall twice as far away is half
    # as tall — but the height is the number the drawing already worked out, so a guard is put
    # behind a wall by comparing two numbers that both exist rather than by working out a second
    # distance. Taller means nearer.
    #
    # It is also what puts one thing in front of another: a thing that draws writes its own
    # height here, so a further one arriving later is turned away by the nearer one and nothing
    # has to be sorted. That is why the scenery and the guards can be drawn in either order.
    attr_reader :depth

    # +eye+ is where the player is and which way they are pointing, as the view keeps them:
    # { x:, y:, cos:, sin:, angle: }.
    def initialize(build:, things:, eye:, scenery: nil, guards: nil, pool: nil, mind: nil)
      @b = build
      @things = things
      @eye = eye
      @scenery = scenery
      @guards = guards
      @pool = pool
      @mind = mind
      declare
    end

    # Is there anything standing in this level at all? A floor with none of either needs none of
    # what follows, and paying for none of it is worth the question.
    def self.needed?(scenery:, guards:)
      !(scenery.nil? || scenery.empty?) || !(guards.nil? || guards.empty?)
    end

    # Everything standing in the level, after the walls it has to stand behind.
    def draw
      draw_the_scenery
      # Which way the eye is pointing was worked out once for the frame already, before the
      # guards thought — the shot needed it too.
      @pool&.each { |guard| draw_a_guard(guard) }
    end

    # Stop drawing one piece of scenery, which is what picking a thing up amounts to. A floor
    # with no scenery on it has nothing to take, and says so by doing nothing.
    def take(piece) = @taken && (@taken[piece] = 1)

    private

    FP = FirstPerson

    def declare
      b = @b
      declare_the_scratch
      b.image :things, width: @things.width, height: @things.height,
                       data: @things.pixels, transparent: true

      @depth = b.list :seen_at, capacity: FP::COLUMNS
      FP::COLUMNS.times { @depth << 0 }

      # WHICH COLUMNS OF EACH PICTURE hold anything, read by where the picture sits in the row
      # rather than by what is wearing it — a shooting guard is a different shape from a walking
      # one, a lamp is thinner than either, and all three are asked the same question.
      @first_column = b.table :thing_first, @things.sprites.map { |p| @things.first_column(p) },
                              width: :byte
      @last_column = b.table :thing_last, @things.sprites.map { |p| @things.last_column(p) },
                             width: :byte
      @first_row = b.table :thing_top, @things.sprites.map { |p| @things.first_row(p) },
                           width: :byte
      @last_row = b.table :thing_bottom, @things.sprites.map { |p| @things.last_row(p) },
                          width: :byte

      declare_the_scenery
      declare_the_guards

      # DRAWING ONE OF THEM IS A ROUTINE, and it has to be. It is by far the biggest piece of
      # code here, and a guard and a lamp want every word of it — so written straight it lands
      # in the frame twice over. That is not just waste: the framework keeps the code a frame
      # spends its time in inside the console's quick memory, there is 32K of it, and a second
      # copy of this was enough to push the whole game loop out. Everything then runs from the
      # cartridge instead, which costs about two and a half times as much — a frame that was
      # slow becomes a frame that crawls, and none of it shows up as the scenery's fault.
      b.func(:draw_a_standing_thing) do
        read_the_shape
        any_of_it_on_screen.then { draw_the_strips }
      end
    end

    # WORKING ROOM: where a thing is relative to the eye, and what that comes to on screen — a
    # picture, a size, and the strips it covers.
    #
    # Declared here rather than with the view's own, and only when a floor has something
    # standing in it. Not tidiness: the quick memory a variable lives in is the same quick
    # memory the framework keeps the busiest routines in, so twenty variables a floor never
    # reads are twenty variables' worth of room the ray walk does not get. It measured as a
    # frame's worth of difference on a floor with nothing standing in it.
    def declare_the_scratch
      @rx, @ry, @fwd, @sideways = fraction(:rx, :ry, :fwd, :sideways)
      @scale, @tex, @tstep = fraction(:scale, :tex, :tstep)
      @pose, @pfirst, @plast, @shape, @tcol = whole(:pose, :pfirst, :plast, :shape, :tcol)
      @cx, @theight, @ttop = whole(:cx, :theight, :ttop)
      @ptop, @pbottom, @band_top, @band_bottom = whole(:ptop, :pbottom, :bandtop, :bandbot)
      @lstrip, @s0, @s1, @tstrip = whole(:lstrip, :s0, :s1, :tstrip)
    end

    def whole(*names) = names.map { |name| @b.var(:"_#{name}", 0) }
    def fraction(*names) = names.map { |name| @b.var(:"_#{name}", 0.0) }

    # THE SCENERY, and every word of it is fixed while the cartridge is built: a piece stands in
    # the middle of its cell and stays there for the whole floor. So it is kept in tables, which
    # live in the cartridge, rather than in the game's own memory — a real floor holds a few
    # hundred pieces and none of them needs a place to change in.
    #
    # The one thing that does change is whether a piece is still THERE, because the things you
    # pick up are scenery too and a key you have taken must stop being drawn.
    def declare_the_scenery
      return if @scenery.nil? || @scenery.empty?

      b = @b
      pieces = @scenery.pieces
      @piece_x = b.table :thing_x, pieces.map { |p| p.x + 0.5 }
      @piece_y = b.table :thing_y, pieces.map { |p| p.y + 0.5 }
      @piece_shape = b.table :thing_shape, pieces.map { |p| @things.position_of(p.picture) },
                             width: :half
      @taken = b.list :thing_gone, capacity: @scenery.count
      @scenery.count.times { @taken << 0 }
    end

    def declare_the_guards
      return if @pool.nil?

      # WHICH WAY A GUARD IS POINTING, as this view counts angles. The original numbers its
      # directions counter-clockwise from east and this view runs its angles clockwise, because
      # its y grows down the screen — so the two run opposite ways and this is where they meet.
      @dir_angle = @b.table :guard_angle,
                            (0..Guards::NOWHERE).map { |n| (-n * (FP::TURN / Guards::POSES)) % FP::TURN }
    end

    # --- putting one on the screen ---------------------------------------------------

    # A THING IN THE WORLD, TURNED INTO A PLACE ON THE SCREEN, and the first half of it: how far
    # in front of the eye it is, measured along the way the player is looking. That is what
    # decides its size — the same perspective divide the walls do, against the same distance the
    # walls are measured by, which is why it sits among them properly.
    def place(x, y, nudge)
      @rx.set(x - @eye[:x])
      @ry.set(y - @eye[:y])
      @fwd.set(@rx * @eye[:cos])
      @fwd.add(@ry * @eye[:sin])
      @fwd.sub nudge
    end

    # ...and the second half, once something is known to be in front of you: how far to the SIDE
    # of the line you are looking down it is, divided by that same distance, is where it lands
    # across the screen. A standing thing is as wide as it is tall, so one size does for both.
    def size_it_up
      @sideways.set(@ry * @eye[:cos])
      @sideways.sub(@rx * @eye[:sin])

      @scale.set(FP::WALL_SCALE / @fwd)
      @theight.set((@scale + 0.5).to_i)
      @cx.set((@sideways * @scale).to_i + (FP::ACROSS / 2))
      @ttop.set(FP::HORIZON - (@theight / 2))
    end

    # Where a picture starts and stops holding anything, both ways, and where its columns begin
    # in the row of them.
    def read_the_shape
      @pfirst.set(@first_column[@shape])
      @plast.set(@last_column[@shape])
      @ptop.set(@first_row[@shape])
      @pbottom.set(@last_row[@shape])
      @shape.set(@shape * FP::TEX)
    end

    # IS ANY OF IT ON THE SCREEN AT ALL, asked of the art rather than of the square it sits in.
    #
    # A thing that lies on the floor is a picture of a clip in the bottom sixth of a square of
    # nothing, and the square is drawn centred on the eye line — so walk up to a clip and the
    # square grows until the clip itself is below the bottom edge. Without this the drawing
    # walks every strip of that square, down the whole height of the screen, and finds nothing:
    # the clip is invisible AND it costs about what the whole room costs. This is one
    # multiplication and two comparisons, once for the thing rather than once for each strip.
    def any_of_it_on_screen
      @band_top.set(@ttop + ((@theight * @ptop) / FP::TEX))
      @band_bottom.set(@ttop + ((@theight * (@pbottom + 1)) / FP::TEX))
      (@band_top < 160) & (@band_bottom > 0)
    end

    # --- the scenery -----------------------------------------------------------------

    # EVERY PIECE OF SCENERY ON THE FLOOR, once a frame. Almost all of them are behind you or
    # off to one side, and what they pay for that is the one comparison below: whether the piece
    # is in front of the eye at all. Everything dearer than that happens only for the ones that
    # can be seen.
    def draw_the_scenery
      return if @piece_x.nil?

      @b.repeat(@scenery.count) { |piece| draw_a_piece(piece) }
    end

    # One piece of scenery: the same billboard a guard is, with nothing to decide. Its picture
    # was settled while the cartridge was built, so there is no pose to work out.
    def draw_a_piece(piece)
      place(@piece_x[piece], @piece_y[piece], SCENERY_NUDGE)
      (@fwd > NEAREST).then do
        # Asked here rather than first: a piece you have picked up is one of a few hundred, and
        # this way only the ones you could see pay for the question at all.
        (@taken[piece] == 0).then do
          size_it_up
          @shape.set(@piece_shape[piece])
          @b.call :draw_a_standing_thing
        end
      end
    end

    # --- the guards ------------------------------------------------------------------

    def draw_a_guard(guard)
      place(guard.x, guard.y, NUDGE)

      # WHETHER HE CAN SEE YOU LOOKING AT HIM, which is not vanity: a guard you have your eye on
      # misses more often, because you could be dodging. The original halves the falloff of his
      # hit chance for a guard who is off screen, and this is where that is known.
      guard.shown.set 0

      # Behind the eye, or all but touching it. Everything below costs something, and this one
      # comparison is what a guard on the far side of the floor pays.
      (@fwd > NEAREST).then do
        guard.shown.set 1
        size_it_up
        pick_a_pose(guard)
        @b.call :draw_a_standing_thing
      end
    end

    # WHICH OF THE EIGHT PICTURES SHOWS: the angle between the way the guard is facing and the
    # way the player is standing from him, dropped into one of eight buckets.
    #
    # The angle from the player to the guard is not worked out again. The strips of this view
    # are one angle unit apart, so where the guard landed across the screen IS that angle, and
    # turning it half way round gives the angle from the guard back to the player. Half a bucket
    # is added first so that a boundary falls between two poses rather than on one, and a guard
    # looking straight at you does not flicker between two pictures as you sidestep.
    # A guard who is firing, or hurt, or falling over has ONE picture rather than eight — he is
    # doing something you see the same way from wherever you stand — so the state says whether
    # the answer above counts for anything at all.
    def pick_a_pose(guard)
      @pose.set(@dir_angle[guard.dir] - @eye[:angle])
      @pose.sub((@cx - (FP::ACROSS / 2)) / FP::COLUMN_W)
      @pose.add((FP::TURN / 2) + (FP::TURN / (Guards::POSES * 2)))
      @pose.set(@pose % FP::TURN)
      @pose.set(@pose / (FP::TURN / Guards::POSES))

      @shape.set(@mind.picture_of[guard.state] + (@pose * @mind.turns_of[guard.state]))
    end

    # --- drawing it ------------------------------------------------------------------

    # A STANDING THING IS A SQUARE the same size as a wall at its distance, so its width on
    # screen is its height, and it is drawn as strips of a picture exactly as a wall is.
    #
    # Only the strips that show are walked. A guard you are nearly standing on is hundreds of
    # pixels across and eighty of them at most are on screen, and one at the edge of the view is
    # mostly past it.
    def draw_the_strips
      b = @b
      @lstrip.set((@cx - (@theight / 2)) / FP::COLUMN_W)
      @s0.set @lstrip
      @s0.clamp 0, FP::COLUMNS
      @s1.set(@lstrip + (@theight / FP::COLUMN_W))
      @s1.clamp 0, FP::COLUMNS

      (@s1 > @s0).then do
        # How far along the picture one strip carries, and where the first strip that shows
        # starts. One divide for the whole thing rather than one per strip.
        @tstep.set((FP::TEX * FP::COLUMN_W).to_f / @theight.to_f)
        @tex.set((@s0 - @lstrip).to_f * @tstep)

        b.repeat(@s1 - @s0) do |step|
          @tstrip.set(@s0 + step)
          @tcol.set(@tex.to_i)
          @tex.add @tstep
          draw_a_strip
        end
      end
    end

    # One strip, if there is anything of the picture in it and nothing nearer in the way.
    #
    # THE EMPTY STRIPS ARE SKIPPED BY NAME. A guard fills about a third of the width of his
    # square, a lamp far less, and the rest is room showing through. Drawing those strips would
    # cost the walk down the screen for nothing — and worse, each would claim its part of the
    # screen in the depth record, rubbing out anything standing behind it.
    def draw_a_strip
      (@tcol >= @pfirst).then do
        (@tcol <= @plast).then do
          (@theight > @depth[@tstrip]).then do
            @depth[@tstrip] = @theight
            @b.draw_column_at :things, slice: @shape + @tcol, x: @tstrip * FP::COLUMN_W,
                                       top: @ttop, height: @theight, width: FP::COLUMN_W
          end
        end
      end
    end
  end
end
