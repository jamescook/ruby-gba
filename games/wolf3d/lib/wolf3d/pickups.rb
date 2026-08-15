# frozen_string_literal: true

module Wolf3D
  # THINGS ON THE FLOOR YOU PICK UP BY WALKING OVER THEM: ammunition, food, first aid, treasure,
  # and the keys.
  #
  # It is the other half of the scenery. The same list that says which pieces stop you says which
  # are worth taking, and about a third of it is — so this adds nothing to the floor. What it adds
  # is what happens when you stand on one.
  #
  # WHY IT MATTERS MORE THAN IT SOUNDS. Without it the game hands you eight bullets and nothing
  # else ever, so it is a game you can run out of and never recover from. Ammunition on the floor
  # is what makes a floor playable at all — and the loop the whole game runs on is that a guard
  # you kill LEAVES a clip where he fell, so shooting one pays for shooting the next.
  #
  # A FULL PLAYER LEAVES IT WHERE IT IS, which is easy to get wrong and very noticeable: walk over
  # a first aid box at a hundred of health and it is still there when you come back needing it.
  # That is the original's behaviour and it is why every kind below has a "unless you are already
  # full" of its own rather than one shared test.
  #
  # WHAT IS STILL ON THE FLOOR LIVES HERE, not with the drawing, and that is deliberate: whether a
  # thing has been taken is a fact about the game, and the drawing asks about it (see
  # Billboards#look_at_a_piece) rather than owning it. A floor drawn by nobody still has things to
  # pick up, which is what the tests of the doors and their keys rely on.
  class Pickups
    # THE KINDS, as numbers a table can hold. Everything about a pickup that the game reads as it
    # runs is one of these plus an amount.
    NOTHING = 0
    AMMUNITION = 1
    HEALTH = 2
    TREASURE = 3
    KEY = 4
    SCRAPS = 5
    EXTRA_LIFE = 6

    KINDS = { ammunition: AMMUNITION, health: HEALTH, treasure: TREASURE,
              key: KEY, scraps: SCRAPS, extra_life: EXTRA_LIFE }.freeze

    # The caps, which are the original's. Ninety-nine rounds and a hundred of health.
    MOST_AMMO = 99
    FULL_HEALTH = FirstPerson::START_HEALTH

    # ...and the two odd ones. What is left of somebody heals one, and only when you are down to
    # this much — above it you cannot bring yourself to take it. The one-up heals ninety-nine,
    # which from any health a living player has is the same as filling it, and hands you a go.
    NEARLY_DEAD = 10
    ONE_UP_HEAL = 99

    # WHAT A GUARD'S BODY IS WORTH: half a clip, which is what the original places when one falls.
    # Half rather than whole is the whole economy of the game — killing pays for itself and does
    # not pay for more than itself.
    DROPPED_ROUNDS = 4

    # THE PICTURES A FLOOR NEEDS FOR WHAT IS PICKED UP, over and above the ones it ships itself:
    # the clip a guard leaves behind, which a floor may hold none of its own. A floor with nobody
    # on it needs none, and asks for none.
    def self.pictures(guards) = guards.nil? || guards.empty? ? [] : [Scenery.clip_picture]

    # +player+ is what a pickup changes, as the view keeps it: { x:, y:, health:, ammo:, score:,
    # keys: }. +lives+ is what hands out another go, or nil on a game that does not count them.
    # +pool+ is the guards, which is where a dropped clip is kept — see #a_guard_fell. +scenery+
    # may be left out, and then the floor is read for itself: a game with no drawing still has
    # things lying on it.
    def initialize(build:, level:, player:, lives: nil, scenery: nil, pool: nil)
      @b = build
      @level = level
      @player = player
      @lives = lives
      @scenery = scenery || Scenery.new(level)
      @pool = pool
      declare
    end

    # Is this piece of the floor still lying there? What reads it is the drawing, which must stop
    # drawing a thing the moment it is picked up.
    def still_there(piece) = @taken[piece] == 0

    # ...and everything back on the floor, for a floor being started again. The clips guards
    # dropped need nothing said about them here: each is a field of the guard who left it, and
    # putting the guards back puts it back with him.
    def put_them_all_back
      @b.repeat(@scenery.count) { |piece| @taken[piece] = 0 }
    end

    # ONE PASS OF THE GAME LOOP: what am I standing on, and what does it give me.
    #
    # A ROUTINE RATHER THAN CODE IN THE LOOP, and this one is not close. What it does on nearly
    # every pass is one table read and one test, but what it has to BE is an arm for every kind of
    # thing a floor can hold — and written straight into the game loop that measured as one and
    # three quarter K of the console's 32, which was enough to push the routine that draws the
    # guards out of the quick memory and make everything it does two and a half times dearer.
    def update
      @b.call :pick_things_up
    end
    # A GUARD HAS FALLEN, and a clip of ammunition is left in the cell he fell in. The original
    # does this in its killing code rather than in its map, which is why it is here and not in the
    # floor's own list of things.
    #
    # THE CLIP IS A FIELD OF THE GUARD, which is the whole trick and is worth its lines. Where it
    # lies is where he lies, because a body never moves again — so there is nothing to remember
    # but that he has one, and where he is answers where it is. That saves a row of places written
    # as the game runs, and it saves the walk over that row: everything that has to find a dropped
    # clip is already walking the guards.
    #
    # It also means starting the floor again needs nothing said about clips at all. A guard who is
    # standing up again has this field put back with the rest of him.
    # +slot+ is which guard, as the shooting knows him — a number rather than a row handle,
    # because that is what the piece that works out who was hit is holding.
    def a_guard_fell(slot) = @pool.field_ref(:dropped, slot).set(1)

    # --- what the drawing asks -------------------------------------------------------

    # Is this guard still lying beside the clip he left? What asks is the drawing, which walks the
    # guards row by row and so hands one over rather than a number: a clip on the floor is a thing
    # to look at like any other, and the piece that knows how to draw one is Billboards.
    def still_dropped(guard) = guard.dropped == 1
    def dropped_picture = Scenery.clip_picture

    private

    # ONE TABLE READ AND ONE TEST is nearly all of it, on nearly every pass. The floor is asked
    # what lies on the cell under the player's feet rather than every thing on the floor being
    # asked where it is — a real floor holds a few hundred pieces, and walking that list every
    # frame to find the one you are standing on would be most of what the game does.
    def what_am_i_standing_on
      @here.set((@player[:y].to_i * @level.width) + @player[:x].to_i)
      @piece.set(@lying_at[@here])
      (@piece > 0).then do
        # Counted from one in the table so that nought can mean an empty cell.
        @piece.sub 1
        still_there(@piece).then { take_it }
      end
      take_what_a_guard_left
    end

    def declare
      b = @b
      pieces = @scenery.pieces

      # WHAT LIES ON EACH CELL, counted from one, and nought for a cell with nothing to take on
      # it. Only the pieces worth taking are named here — walk onto a lamp and this reads nought,
      # which is the same answer as bare floor and costs the same.
      @lying_at = b.table :lying_at, cells_with_something_on_them(pieces), width: :half

      # ...and what each of them gives. By the piece's own number, so the two tables above and
      # below meet at the one index the drawing uses as well.
      #
      # A table must hold something and a floor need hold nothing, so an empty floor gets one
      # entry that nothing ever reads — the table above names no piece for it to be reached by.
      @gives_kind = b.table :gives_kind, at_least_one(pieces.map { |p| kind_of(p) }), width: :byte
      @gives_amount = b.table :gives_amount, at_least_one(pieces.map { |p| amount_of(p) }),
                              width: :half

      # WHAT HAS BEEN TAKEN, which is the only thing about a floor's things that ever changes.
      @taken = b.list :thing_gone, capacity: [@scenery.count, 1].max
      [@scenery.count, 1].max.times { @taken << 0 }

      declare_the_scratch

      b.func(:pick_things_up, fast: false) { what_am_i_standing_on }
    end

    def declare_the_scratch
      @here, @piece, @kind, @amount, @took =
        %i[here piece kind amount took].map { |name| @b.var(:"_pick_#{name}", 0) }
    end

    # WHAT THE PIECE UNDER YOUR FEET GIVES, one arm per kind. Each arm decides for itself whether
    # you can hold what it offers, and only an arm that gave something says so — that is what
    # leaves a first aid box on the floor of a player who does not need it yet.
    def take_it
      @kind.set(@gives_kind[@piece])
      @amount.set(@gives_amount[@piece])
      @took.set 0

      (@kind == AMMUNITION).then { give_ammunition(@amount) }
      (@kind == HEALTH).then { give_health(@amount) }
      (@kind == TREASURE).then { @player[:score].add @amount; @took.set 1 }
      (@kind == KEY).then { @player[:keys].add @amount; @took.set 1 }
      (@kind == SCRAPS).then do
        (@player[:health] <= NEARLY_DEAD).then { give_health(@amount) }
      end
      (@kind == EXTRA_LIFE).then { give_another_go }

      (@took == 1).then { @taken[@piece] = 1 }
    end

    def give_ammunition(rounds)
      (@player[:ammo] < MOST_AMMO).then do
        @player[:ammo].add rounds
        @player[:ammo].clamp 0, MOST_AMMO
        @took.set 1
      end
    end

    def give_health(points)
      (@player[:health] < FULL_HEALTH).then do
        @player[:health].add points
        @player[:health].clamp 0, FULL_HEALTH
        @took.set 1
      end
    end

    # The one-up, which is taken whatever state you are in: it fills the health of a player who
    # was already full, and there is always room for another go.
    def give_another_go
      @player[:health].add ONE_UP_HEAL
      @player[:health].clamp 0, FULL_HEALTH
      @lives&.give_one
      @took.set 1
    end

    # THE CLIPS GUARDS LEFT, walked over rather than looked up, and this is the one that has to
    # be: the cartridge's map is built in and cannot say where something the game put down is.
    #
    # WHAT IS WALKED IS THE GUARDS, and the outer test is what nearly every one of them pays — a
    # comparison, on a walk the frame is making anyway for other reasons. Only a guard who is
    # lying beside a clip goes on to work out which cell he is in.
    def take_what_a_guard_left
      return unless @pool

      @pool.each do |guard|
        still_dropped(guard).then do
          (((guard.y.to_i * @level.width) + guard.x.to_i) == @here).then do
            @took.set 0
            give_ammunition(DROPPED_ROUNDS)
            (@took == 1).then { guard.dropped.set 0 }
          end
        end
      end
    end

    # --- the tables, worked out while the cartridge is built --------------------------

    def cells_with_something_on_them(pieces)
      cells = Array.new(@level.width * @level.height, 0)
      pieces.each_with_index do |piece, at|
        cells[(piece.y * @level.width) + piece.x] = at + 1 if piece.bonus
      end
      cells
    end

    def at_least_one(values) = values.empty? ? [0] : values

    def kind_of(piece) = piece.bonus ? KINDS.fetch(piece.bonus.first) : NOTHING

    # How much of it, which for a key is the bit that key sets — the same one number a locked door
    # asks about, so nothing has to be converted where the two meet.
    def amount_of(piece)
      return 0 unless piece.bonus

      kind, amount = piece.bonus
      kind == :key ? FirstPerson::KEY_BITS.fetch(amount) : amount
    end
  end
end
