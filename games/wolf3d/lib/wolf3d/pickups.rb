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
    WEAPON = 7

    KINDS = { ammunition: AMMUNITION, health: HEALTH, treasure: TREASURE,
              key: KEY, scraps: SCRAPS, extra_life: EXTRA_LIFE, weapon: WEAPON }.freeze

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

    # ...and what a gun lying on the floor comes loaded with. The original hands you the rounds
    # FIRST and the gun after, which is why a player who already has that gun still takes them.
    WEAPON_ROUNDS = 6

    # THE PICTURES A FLOOR NEEDS FOR WHAT IS PICKED UP, over and above the ones it ships itself:
    # what the enemies on it leave when they fall, which a floor may hold none of its own. A
    # floor with nobody on it needs none, and asks for none — and one with nothing but dogs needs
    # none either, since a dog carries nothing.
    def self.pictures(guards)
      return [] if guards.nil? || guards.empty?

      guards.kinds.filter_map { |name| Enemy[name].leaves }.uniq
            .map { |left| left == :machine_gun ? Scenery.machine_gun_picture : Scenery.clip_picture }
    end

    # +player+ is what a pickup changes, as the view keeps it: { x:, y:, health:, ammo:, score:,
    # keys: }. +lives+ is what hands out another go, or nil on a game that does not count them.
    # +pool+ is the guards, which is where a dropped clip is kept — see #a_guard_fell. +scenery+
    # may be left out, and then the floor is read for itself: a game with no drawing still has
    # things lying on it.
    # +floors+ is every floor the cartridge holds; a game with one may hand over its `level:` and
    # `scenery:` loose instead, which is what the tests do. +bases+ is where this floor's slice of
    # each table begins, as the view keeps it: { map:, piece: } — left out on a one-floor game,
    # where every slice begins at nothing.
    # +weapons+ is what the two guns on the floor are handed to, or nil on a game with no
    # weapons to hold — and then they give their rounds and nothing else, which is what this
    # did before there was a gun to pick up.
    def initialize(build:, player:, level: nil, lives: nil, scenery: nil, pool: nil,
                   floors: nil, bases: {}, weapons: nil)
      @b = build
      @weapons = weapons
      @floors = floors || Floors.of(level: level, doors: Doors.new(level, nil),
                                    pushwalls: Pushwalls.new(level),
                                    scenery: scenery || Scenery.new(level))
      @level = @floors.first_floor.level
      @player = player
      @lives = lives
      # A FLOOR WITH NO SCENERY IS READ FOR ITSELF, which is what the note above means and what
      # the tests of the locked doors rely on: a game that draws nothing standing in the rooms
      # still has a key lying on the floor, or its locked door could never be opened.
      @scenery_of = @floors.to_h { |floor| [floor.index, floor.scenery || Scenery.new(floor.level)] }
      @scenery = scenery_of(@floors.first_floor)
      @bases = bases
      @pool = pool
      declare
    end

    # Is this piece of the floor still lying there? What reads it is the drawing, which must stop
    # drawing a thing the moment it is picked up.
    def still_there(piece) = @taken[piece] == 0

    # HOW MANY TREASURES THIS FLOOR HOLDS, which is what a hundred per cent means at the end of
    # it. Settled while building, because it is a fact about the map.
    #
    # THE ONE-UP IS ONE OF THEM. It looks like a life rather than a treasure and the original
    # counts it as a treasure, in the same arm as the cross, the chalice, the bible and the
    # crown — so a floor holding one cannot be finished at a hundred per cent without taking it.
    COUNTS_AS_TREASURE = [TREASURE, EXTRA_LIFE].freeze

    # Per floor, because a share of a floor is what it means. The view asks for the one being
    # played; a one-floor game has one number.
    def treasure_total(floor = 0)
      scenery_of(@floors[floor])
        .pieces.count { |piece| COUNTS_AS_TREASURE.include?(kind_of(piece)) }
    end

    # ...and everything back on the floor, for a floor being started again. The clips guards
    # dropped need nothing said about them here: each is a field of the guard who left it, and
    # putting the guards back puts it back with him.
    def put_them_all_back
      @b.repeat(most_pieces) { |piece| @taken[piece] = 0 }
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
    # +leaving+ is WHAT he left, as Enemy::LEAVES numbers it — half a clip from most of them, a
    # machine gun from an SS, and nothing at all from a dog, which carried none.
    def a_guard_fell(slot, leaving:)
      left = @pool.field_ref(:dropped, slot)
      left.set(leaving)
      # A GUN YOU ALREADY HAVE IS A CLIP INSTEAD, which is the original's own line and the reason
      # an SS is worth killing twice: the first one arms you and every one after it feeds the gun.
      return if @weapons.nil?

      (left == MACHINE_GUN_LEFT).then do
        @weapons.already_has(Weapons::MACHINE_GUN).then { left.set CLIP_LEFT }
      end
    end

    # --- what the drawing asks -------------------------------------------------------

    # Is this guard still lying beside what he left? What asks is the drawing, which walks the
    # guards row by row and so hands one over rather than a number: a clip on the floor is a thing
    # to look at like any other, and the piece that knows how to draw one is Billboards.
    def still_dropped(guard) = guard.dropped > NOTHING_LEFT

    # WHAT CAN BE LEFT LYING, in the order Enemy::LEAVES numbers them, so a table indexed by what
    # a guard dropped hands back a picture. Nought is nothing and gets a picture nothing reads.
    NOTHING_LEFT = Enemy::LEAVES.fetch(nil)
    CLIP_LEFT = Enemy::LEAVES.fetch(:clip)
    MACHINE_GUN_LEFT = Enemy::LEAVES.fetch(:machine_gun)
    GOLD_KEY_LEFT = Enemy::LEAVES.fetch(:gold_key)

    # The pictures the things that can be left lying need, in that same order.
    def self.dropped_pictures
      [Scenery.clip_picture, Scenery.clip_picture, Scenery.machine_gun_picture,
       Scenery.gold_key_picture]
    end

    def dropped_pictures = self.class.dropped_pictures

    private

    # ONE TABLE READ AND ONE TEST is nearly all of it, on nearly every pass. The floor is asked
    # what lies on the cell under the player's feet rather than every thing on the floor being
    # asked where it is — a real floor holds a few hundred pieces, and walking that list every
    # frame to find the one you are standing on would be most of what the game does.
    def what_am_i_standing_on
      @here.set((@player[:y].to_i * @level.width) + @player[:x].to_i)
      @here.add(@bases[:map]) if @bases[:map]
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

      # WHAT LIES ON EACH CELL, counted from one, and nought for a cell with nothing to take on
      # it. Only the pieces worth taking are named here — walk onto a lamp and this reads nought,
      # which is the same answer as bare floor and costs the same.
      #
      # EVERY FLOOR'S CELLS END TO END, like the map, and the number in a cell is the piece's own
      # number WITHIN ITS FLOOR — because what it reaches is whether that piece has been taken,
      # which is state a floor is played with and is sized for one floor.
      @lying_at = b.table :lying_at,
                          @floors.flat_map { |floor| cells_with_something_on_them(floor) },
                          width: :half

      # ...and what each of them gives. Every floor's pieces end to end, reached by adding where
      # this floor's begin — settled things rather than played-with ones, so they go the other
      # way from the numbers above.
      #
      # A table must hold something and a floor need hold nothing, so an empty game gets one
      # entry that nothing ever reads — the table above names no piece for it to be reached by.
      everything = @floors.flat_map { |floor| scenery_of(floor).pieces }
      @gives_kind = b.table :gives_kind, at_least_one(everything.map { |p| kind_of(p) }), width: :byte
      @gives_amount = b.table :gives_amount, at_least_one(everything.map { |p| amount_of(p) }),
                              width: :half

      # WHAT HAS BEEN TAKEN, which is the only thing about a floor's things that ever changes.
      # One floor's worth, since only one is ever being played.
      room = most_pieces
      @taken = b.list :thing_gone, capacity: room
      room.times { @taken << 0 }

      declare_the_scratch

      b.func(:pick_things_up, fast: false) { what_am_i_standing_on }
    end

    def declare_the_scratch
      # +slot+ is the piece's place in the tables of every floor's pieces, which is its own number
      # plus where this floor's begin. Kept apart from +piece+, which stays this floor's own
      # number because that is what says whether it has been taken.
      @here, @piece, @slot, @kind, @amount, @took =
        %i[here piece slot kind amount took].map { |name| @b.var(:"_pick_#{name}", 0) }
    end

    # WHAT THE PIECE UNDER YOUR FEET GIVES, one arm per kind. Each arm decides for itself whether
    # you can hold what it offers, and only an arm that gave something says so — that is what
    # leaves a first aid box on the floor of a player who does not need it yet.
    def take_it
      @slot.set(@piece)
      @slot.add(@bases[:piece]) if @bases[:piece]
      @kind.set(@gives_kind[@slot])
      @amount.set(@gives_amount[@slot])
      @took.set 0

      (@kind == AMMUNITION).then { give_ammunition(@amount) }
      (@kind == HEALTH).then { give_health(@amount) }
      (@kind == TREASURE).then do
        @player[:score].add @amount
        @player[:treasures]&.add(1)
        @took.set 1
      end
      # A KEY SETS ITS OWN BIT rather than being added on, which is the original's own `|=` and
      # matters the moment two of the same key can be had: a floor's key and the one a boss
      # leaves are both gold, and adding the gold bit twice would read as the silver one.
      (@kind == KEY).then { @player[:keys].set(@player[:keys] | @amount); @took.set 1 }
      (@kind == SCRAPS).then do
        (@player[:health] <= NEARLY_DEAD).then { give_health(@amount) }
      end
      (@kind == EXTRA_LIFE).then { give_another_go }
      (@kind == WEAPON).then { give_a_weapon }

      (@took == 1).then { @taken[@piece] = 1 }
    end

    # A GUN ON THE FLOOR: six rounds and then the gun itself, in that order and always taken —
    # unlike a clip, which a player with ninety-nine rounds leaves where it is. You take the gun
    # whether or not you can carry another round for it, so the piece always goes.
    def give_a_weapon
      give_ammunition(WEAPON_ROUNDS)
      return if @weapons.nil?

      @weapons.give(@amount)
      @took.set 1
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
    #
    # IT COUNTS AS TREASURE, which is not obvious and is the original's own accounting: the
    # one-up sits in the same arm of GetBonus as the cross, the chalice, the bible and the crown,
    # so a floor that holds one needs it taken for a hundred per cent. Miss this and a player who
    # collected everything is told they found four fifths of it.
    def give_another_go
      @player[:health].add ONE_UP_HEAL
      @player[:health].clamp 0, FULL_HEALTH
      @lives&.give_one
      @player[:treasures]&.add(1)
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

      # The cell a guard fell in, counted the same way as the one under the player's feet — which
      # on a cartridge holding more than one floor means this floor's slice of the map, not the
      # first floor's. Compare them as different numbers and a clip is never found.
      @pool.each do |guard|
        still_dropped(guard).then do
          (guard_cell(guard) == @here).then { take_what_he_left(guard) }
        end
      end
    end

    # HALF A CLIP, OR A MACHINE GUN AND SIX ROUNDS, and which is what he was carrying. A cartridge
    # with no SS on any floor emits only the first arm and pays nothing for the second.
    def take_what_he_left(guard)
      @took.set 0
      unless (@weapons && leaves_a_gun?) || leaves_a_key?
        give_ammunition(DROPPED_ROUNDS)
        return (@took == 1).then { guard.dropped.set NOTHING_LEFT }
      end

      (guard.dropped == CLIP_LEFT).then { give_ammunition(DROPPED_ROUNDS) }
      if @weapons && leaves_a_gun?
        (guard.dropped == MACHINE_GUN_LEFT).then do
          # A gun off the floor is always taken, rounds or no rounds — the same rule as one the
          # level put there.
          give_ammunition(WEAPON_ROUNDS)
          @weapons.give(Weapons::MACHINE_GUN)
          @took.set 1
        end
      end
      # THE GOLD KEY OFF A BOSS, which is always taken — a key is the one thing you can never be
      # too full of, and it is the way out of the floor he was standing in.
      if leaves_a_key?
        (guard.dropped == GOLD_KEY_LEFT).then do
          @player[:keys].set(@player[:keys] | FirstPerson::KEY_BITS.fetch(:gold))
          @took.set 1
        end
      end
      (@took == 1).then { guard.dropped.set NOTHING_LEFT }
    end

    # Does anything on this cartridge leave a gun behind at all?
    def leaves_a_gun?
      @floors.any? { |floor| floor.guards&.kinds&.any? { |name| Enemy[name].leaves == :machine_gun } }
    end

    # ...and does anything leave a key? Only a boss does, so a cartridge with no boss floor on it
    # emits none of the arm above and pays nothing for it.
    def leaves_a_key?
      @floors.any? { |floor| floor.guards&.kinds&.any? { |name| Enemy[name].leaves == :gold_key } }
    end

    def scenery_of(floor) = @scenery_of.fetch(floor.index)

    # How many pieces the busiest floor holds, which is what the list of what has been taken is
    # sized for. Read off the scenery this asked for rather than the floor's own, since a floor
    # that was handed none is read for itself.
    def most_pieces = [@floors.map { |floor| scenery_of(floor).count }.max, 1].max

    def guard_cell(guard)
      cell = (guard.y.to_i * @level.width) + guard.x.to_i
      @bases[:map] ? cell + @bases[:map] : cell
    end

    # --- the tables, worked out while the cartridge is built --------------------------

    def cells_with_something_on_them(floor)
      level = floor.level
      cells = Array.new(level.width * level.height, 0)
      scenery_of(floor).pieces.each_with_index do |piece, at|
        cells[(piece.y * level.width) + piece.x] = at + 1 if piece.bonus
      end
      cells
    end

    def at_least_one(values) = values.empty? ? [0] : values

    def kind_of(piece) = piece.bonus ? KINDS.fetch(piece.bonus.first) : NOTHING

    # How much of it, which for a key is the bit that key sets — the same one number a locked door
    # asks about, so nothing has to be converted where the two meet — and for a gun is which gun.
    def amount_of(piece)
      return 0 unless piece.bonus

      kind, amount = piece.bonus
      case kind
      when :key then FirstPerson::KEY_BITS.fetch(amount)
      when :weapon then Weapons::NUMBERS.fetch(amount)
      else amount
      end
    end
  end
end
