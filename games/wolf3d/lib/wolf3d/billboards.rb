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

    # HOW MANY STANDING THINGS ONE FRAME CAN DRAW. Everything that will actually show goes on the
    # queue, and the queue has to end somewhere. The original keeps fifty and stops adding there.
    #
    # IT IS PAID FOR IN THE CONSOLE'S QUICK MEMORY, which is the same 32K the framework keeps the
    # game loop in — so every slot here is a slot the loop does not get, and a queue long enough
    # to be comfortable is a queue that pushes the whole frame out to the cartridge and costs two
    # and a half times more than it saves.
    #
    # SO THE NUMBER IS MEASURED RATHER THAN CHOSEN. Standing in open cells of all sixty floors of
    # the real game in turn and looking sixteen ways from each: at most 42 things could be seen
    # at once anywhere in the game. This is half again as many.
    MOST_AT_ONCE = 64

    # HOW FAR AWAY EACH STRIP OF THE SCREEN ENDED UP, kept as the HEIGHT the wall was drawn at
    # rather than as a distance. The two say the same thing — a wall twice as far away is half
    # as tall — but the height is the number the drawing already worked out, so a guard is put
    # behind a wall by comparing two numbers that both exist rather than by working out a second
    # distance. Taller means nearer, and a strip where the ray met nothing holds nought.
    #
    # IT IS ABOUT WALLS AND ONLY WALLS. A wall fills its strip from the ceiling to the floor, so
    # anything further off in that strip is behind all of it and nothing of that thing shows —
    # one number an answer. A standing thing is a picture with holes in it and settles nothing of
    # the kind, which is why the things sort themselves out among each other instead.
    attr_reader :depth

    # +eye+ is where the player is and which way they are pointing, as the view keeps them:
    # { x:, y:, cos:, sin:, angle: }.
    def initialize(build:, things:, eye:, scenery: nil, guards: nil, pool: nil, mind: nil,
                   pickups: nil)
      @b = build
      @things = things
      @eye = eye
      @scenery = scenery
      @guards = guards
      @pool = pool
      @mind = mind
      @pickups = pickups  # what is still lying on the floor, and where a guard dropped one
      declare
    end

    # Is there anything standing in this level at all? A floor with none of either needs none of
    # what follows, and paying for none of it is worth the question.
    def self.needed?(scenery:, guards:)
      !(scenery.nil? || scenery.empty?) || !(guards.nil? || guards.empty?)
    end

    # EVERYTHING STANDING IN THE LEVEL, after the walls it has to stand behind. Look at all of
    # it first and draw it afterwards, FURTHEST FIRST — so a nearer thing paints over a further
    # one, and where the nearer one is see-through the further one is simply left showing.
    #
    # That order is the whole of putting one standing thing in front of another, and it is the
    # original's own answer. Nothing else works: a thing cannot claim the strips it covers the
    # way a wall does, because a lamp is its picture at the top of its square and its light at
    # the bottom with a hole between, and a guard standing in that hole is looked at THROUGH it.
    def draw
      @seen.set 0
      look_at_the_scenery
      # Which way the eye is pointing was worked out once for the frame already, before the
      # guards thought — the shot needed it too.
      @pool&.each { |guard| look_at_a_guard(guard) }
      @b.call :draw_what_is_on_screen
    end

    private

    FP = FirstPerson

    def declare
      b = @b
      declare_the_scratch
      b.image :things, width: @things.width, height: @things.height,
                       data: @things.pixels, transparent: true

      @depth = b.list :seen_at, capacity: FP::COLUMNS
      FP::COLUMNS.times { @depth << 0 }

      # WHAT IS ON SCREEN THIS FRAME, and it is a queue rather than a record of the screen: the
      # picture each thing wears, where it lands across the screen, and how tall it stands. Kept
      # furthest first, which is the order they are drawn in.
      @seen_shape = slots(:seen_shape)
      @seen_across = slots(:seen_across)
      @seen_height = slots(:seen_height)

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
      declare_what_guards_leave
      declare_the_guards

      # DRAWING ONE OF THEM IS A ROUTINE, and it has to be. It is by far the biggest piece of
      # code here, and a guard and a lamp want every word of it — so written straight it lands
      # in the frame twice over. That is not just waste: the framework keeps the code a frame
      # spends its time in inside the console's quick memory, there is 32K of it, and a second
      # copy of this was enough to push the whole game loop out. Everything then runs from the
      # cartridge instead, which costs about two and a half times as much — a frame that was
      # slow becomes a frame that crawls, and none of it shows up as the scenery's fault.
      # IT CARRIES ITS OWN EDGES, and that is not belt and braces. The view wraps its drawing in
      # the rows it owns so that a thing too tall for them is cut off rather than painted over
      # the status bar — but a routine's body is built where it is DECLARED, not where it is
      # called, and this one is declared out here. So the view's edges never reached it: walk
      # into a thing standing on the floor and it is drawn far taller than the view, straight
      # down through the bar. Saying the edges again here is what puts them back.
      b.func(:draw_a_standing_thing) do
        b.inside 0, 0, FP::ACROSS, FP::VIEW_H do
          read_the_shape
          any_of_it_on_screen.then { draw_the_strips }
        end
      end

      # ...and so is putting one on the queue, for the same reason and not for tidiness. It is
      # written once and wanted by a lamp and a guard alike, so inline it lands in the frame
      # twice — and the game loop had two thousand bytes of that quick memory to spare, which
      # two copies of this were enough to spend. Nothing about the game changes when that
      # happens except that all of it runs from the cartridge, at about two and a half times
      # the price.
      b.func(:remember_a_standing_thing) { remember_a_standing_thing }
      b.func(:draw_what_is_on_screen) { draw_the_queue }
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
      @seen, @at, @shows = whole(:seen, :at, :shows)
    end

    def whole(*names) = names.map { |name| @b.var(:"_#{name}", 0) }
    def fraction(*names) = names.map { |name| @b.var(:"_#{name}", 0.0) }

    # A list used as a row of slots rather than as something that grows: made full at boot and
    # written by index from then on, so the start of a frame is one number set to nought rather
    # than a list emptied an item at a time.
    def slots(name)
      list = @b.list name, capacity: MOST_AT_ONCE
      MOST_AT_ONCE.times { list << 0 }
      list
    end

    # THE SCENERY, and every word of it is fixed while the cartridge is built: a piece stands in
    # the middle of its cell and stays there for the whole floor. So it is kept in tables, which
    # live in the cartridge, rather than in the game's own memory — a real floor holds a few
    # hundred pieces and none of them needs a place to change in.
    #
    # The one thing that does change is whether a piece is still THERE, because the things you
    # pick up are scenery too and a key you have taken must stop being drawn. That one fact is
    # kept by Pickups rather than here: it is a fact about the game, and this only asks.
    def declare_the_scenery
      return if @scenery.nil? || @scenery.empty?

      b = @b
      pieces = @scenery.pieces
      @piece_x = b.table :thing_x, pieces.map { |p| p.x + 0.5 }
      @piece_y = b.table :thing_y, pieces.map { |p| p.y + 0.5 }
      @piece_shape = b.table :thing_shape, pieces.map { |p| @things.position_of(p.picture) },
                             width: :half
    end

    # THE CLIP A GUARD LEAVES WHERE HE FALLS is a billboard like any other — one picture standing
    # in the middle of a cell — and the only thing about it that is not like a piece of scenery is
    # that the cartridge cannot know it is there. So its place is read from Pickups, which is
    # where the game puts it, and everything after that is the same road every other thing takes.
    #
    # A FLOOR WHOSE PICTURES DO NOT INCLUDE A CLIP DRAWS NONE, which is how a test that ships only
    # the guards' own pictures stays honest: the ammunition still works, there is simply nothing
    # to draw. A built game asks for the picture (see Pickups.pictures).
    # WHERE THE CLIP A GUARD LEFT IS DRAWN FROM. A floor whose pictures do not include a clip
    # draws none, which is how a test that ships only the guards' own pictures stays honest: the
    # ammunition still works, there is simply nothing to draw. A built game asks for the picture
    # (see Pickups.pictures).
    def declare_what_guards_leave
      return if @pickups.nil? || @pool.nil?

      @drop_shape = @things.position_of(@pickups.dropped_picture)
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
    def size_it_on_screen
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
    def look_at_the_scenery
      return if @piece_x.nil?

      @b.repeat(@scenery.count) { |piece| look_at_a_piece(piece) }
    end

    # One piece of scenery: the same billboard a guard is, with nothing to decide. Its picture
    # was settled while the cartridge was built, so there is no pose to work out.
    def look_at_a_piece(piece)
      place(@piece_x[piece], @piece_y[piece], SCENERY_NUDGE)
      (@fwd > NEAREST).then do
        # Asked here rather than first: a piece you have picked up is one of a few hundred, and
        # this way only the ones you could see pay for the question at all.
        @pickups.still_there(piece).then do
          size_it_on_screen
          @shape.set(@piece_shape[piece])
          @b.call :remember_a_standing_thing
        end
      end
    end

    # --- the guards ------------------------------------------------------------------

    def look_at_a_guard(guard)
      place(guard.x, guard.y, NUDGE)

      # WHETHER HE CAN SEE YOU LOOKING AT HIM, which is not vanity: a guard you have your eye on
      # misses more often, because you could be dodging. The original halves the falloff of his
      # hit chance for a guard who is off screen, and this is where that is known.
      guard.shown.set 0

      # Behind the eye, or all but touching it. Everything below costs something, and this one
      # comparison is what a guard on the far side of the floor pays.
      (@fwd > NEAREST).then do
        guard.shown.set 1
        size_it_on_screen
        pick_a_pose(guard)
        @b.call :remember_a_standing_thing
        # ...AND THE CLIP HE LEFT, if he is lying beside one, which costs almost nothing to put
        # here: a body never moves again, so the clip stands exactly where he does and the place
        # and the size are both worked out already. Only its picture differs.
        leave_his_clip_on_the_floor(guard)
      end
    end

    def leave_his_clip_on_the_floor(guard)
      return if @drop_shape.nil?

      @pickups.still_dropped(guard).then do
        @shape.set @drop_shape
        @b.call :remember_a_standing_thing
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

    # --- what is on screen, furthest first -------------------------------------------

    # WHETHER TO QUEUE ONE AT ALL, in two questions of rising price: does any of its square fall
    # across the screen, and is any of that in front of the walls. Only what passes both is drawn
    # this frame, and only what is drawn takes a place in the queue.
    def remember_a_standing_thing
      b = @b
      covers_any_strips.then do
        in_front_of_the_walls.then do
          add_it_to_the_queue
        end
      end
    end

    # IS ANY OF IT IN FRONT OF THE WALLS? Walk the strips it covers until one is found where it
    # stands taller than the wall there, and give up at the first one that does.
    #
    # THIS IS WHAT KEEPS THE QUEUE SHORT, and the queue is short or the game loop leaves the
    # console's quick memory. Being in front of the eye and across the screen is a weak test: a
    # floor of the real game puts up to 327 things through it at once, because it says nothing
    # about walls, and a floor is mostly walls. Asking the walls as well takes that to 42 — the
    # rest are in rooms you cannot see into.
    #
    # It costs nothing in pixels: a thing that fails this draws nothing anywhere, because every
    # strip of it would meet the same test again on the way down. That only holds because the
    # things themselves no longer write that record — a wall wrote every number in it, and no
    # wall moves between here and the drawing.
    def in_front_of_the_walls
      @shows.set 0
      @b.repeat(@s1 - @s0, stop_when: @shows == 1, estimate: { usually: 2 }) do |step|
        (@theight > @depth[@s0 + step]).then { @shows.set 1 }
      end
      @shows == 1
    end

    # ...and where it goes, which is what makes the drawing come out in order: the things
    # themselves turn up in whatever order the level lists them, so its place is found by moving
    # the nearer ones along one and dropping this one into the hole. That is dearer the longer
    # the queue gets, which is the other reason the two tests above are worth their price.
    #
    # A FULL QUEUE TURNS THE NEXT ONE AWAY, which is what the original does too.
    def add_it_to_the_queue
      b = @b
      (@seen < MOST_AT_ONCE).then do
        @at.set(@seen - 1)
        b.repeat(@seen, stop_when: @seen_height[@at] <= @theight,
                        estimate: { usually: 2 }) do
          @seen_height[@at + 1] = @seen_height[@at]
          @seen_across[@at + 1] = @seen_across[@at]
          @seen_shape[@at + 1] = @seen_shape[@at]
          @at.sub 1
        end

        @seen_height[@at + 1] = @theight
        @seen_across[@at + 1] = @cx
        @seen_shape[@at + 1] = @shape
        @seen.add 1
      end
    end

    # ...and then draw them, in that order. Where a thing lands and how tall it is were both
    # worked out while it was being looked at, so nothing is measured twice; where it starts up
    # the screen follows from its height, which is cheaper to work out again than to carry.
    def draw_the_queue
      @b.repeat(@seen) do |n|
        @theight.set @seen_height[n]
        @cx.set @seen_across[n]
        @shape.set @seen_shape[n]
        @ttop.set(FP::HORIZON - (@theight / 2))
        @b.call :draw_a_standing_thing
      end
    end

    # --- drawing it ------------------------------------------------------------------

    # A STANDING THING IS A SQUARE the same size as a wall at its distance, so its width on
    # screen is its height, and it is drawn as strips of a picture exactly as a wall is.
    #
    # Only the strips that show are walked. A guard you are nearly standing on is hundreds of
    # pixels across and eighty of them at most are on screen, and one at the edge of the view is
    # mostly past it.
    # WHICH STRIPS OF THE SCREEN ITS SQUARE FALLS ACROSS, held to the ones that exist. If none
    # are left there is nothing to draw, and that is the test a thing off to the side of the view
    # is thrown out by before it ever reaches the queue.
    def covers_any_strips
      @lstrip.set((@cx - (@theight / 2)) / FP::COLUMN_W)
      @s0.set @lstrip
      @s0.clamp 0, FP::COLUMNS
      @s1.set(@lstrip + (@theight / FP::COLUMN_W))
      @s1.clamp 0, FP::COLUMNS
      @s1 > @s0
    end

    def draw_the_strips
      b = @b
      covers_any_strips.then do
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

    # One strip, if there is anything of the picture in it and no wall nearer in the way.
    #
    # THE EMPTY STRIPS ARE SKIPPED BY NAME. A guard fills about a third of the width of his
    # square, a lamp far less, and the rest is room showing through. Drawing those strips would
    # cost the walk down the screen for nothing at all.
    #
    # The wall's height is read and never written. What is drawn here is a picture with holes in
    # it, so it settles nothing about the strip for whatever comes next — and nothing needs it
    # to, because whatever comes next is nearer and paints over.
    def draw_a_strip
      (@tcol >= @pfirst).then do
        (@tcol <= @plast).then do
          (@theight > @depth[@tstrip]).then do
            @b.draw_column_at :things, slice: @shape + @tcol, x: @tstrip * FP::COLUMN_W,
                                       top: @ttop, height: @theight, width: FP::COLUMN_W
          end
        end
      end
    end
  end
end
