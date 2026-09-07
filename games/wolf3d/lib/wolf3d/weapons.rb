# frozen_string_literal: true

module Wolf3D
  # THE GUN IN YOUR HANDS: which one it is, what it does when you pull the trigger, and the
  # picture of it at the bottom of the screen.
  #
  # Wolfenstein has four and which one you are holding is most of how the game feels — the same
  # corridor is a different room with a chain gun in it. All four run the SAME four stages at
  # six units of time each: raise, fire, follow through, lower. What makes them different is one
  # thing, and it is what the third stage does:
  #
  #   knife         the second stage cuts                    no ammunition, and you must be
  #                                                          near enough to touch
  #   pistol        the second stage fires one round         and then it stops
  #   machine gun   ...and the third goes BACK to the        so it repeats while you hold the
  #                 second                                   button
  #   chain gun     ...and the third FIRES as it goes back   so it repeats twice as fast
  #
  # In the original that last line is not a second rate but a missing `break`: the chain gun's
  # arm falls through into the firing one. Two weapons out of one table entry.
  #
  # THE DAMAGE IS THE SAME WHICHEVER GUN IT IS. What a shot takes off a man is decided by how
  # far away he is and not by what fired it (see GuardMind) — so a chain gun is not a
  # harder-hitting pistol, it is more pistol shots. The knife is the one exception, and what
  # makes it different is a REACH rather than a falloff.
  #
  # TWO NUMBERS FOR ONE QUESTION, and this is the detail worth copying rather than tidying away:
  # what is IN YOUR HANDS and what you CHOSE are kept apart. Running a gun dry drops you to the
  # knife without forgetting the choice, so the moment a clip puts a round back the gun you
  # chose returns on its own and nobody ever picks their machine gun back up by hand.
  #
  # THERE IS NO KICK AND NO FISTS, which is the thing everyone half remembers. The knife IS the
  # melee, and it is weapon one. Doom has the fists.
  class Weapons
    KNIFE = 0
    PISTOL = 1
    MACHINE_GUN = 2
    CHAIN_GUN = 3

    # Which number a name means, for the two that lie on the floor of a level.
    NUMBERS = WeaponAtlas::WEAPONS.each_with_index.to_h.freeze

    # What a game starts with, which is the original's: a knife you never lose and a pistol with
    # eight rounds in it.
    STARTING = PISTOL

    # THE FOUR STAGES OF AN ATTACK, and where the two interesting ones are.
    STAGES = 4
    AT_REST = -1
    FIRES = 1      # the stage the weapon does its one thing at the end of...
    REPEATS = 2    # ...and the one the two automatics go back to it from

    # HOW LONG A STAGE LASTS, in passes of the game loop. The original counts six of its own
    # seventieths of a second, and a pass of this game is worth about one of those — the same
    # finding the guards' clock is built on, taken from how far the player walks and turns in a
    # pass rather than from a frame rate. So six is six.
    #
    # WHAT IT COSTS IS THAT YOU CANNOT TAP FASTER THAN THE GUN CYCLES, which is the original's
    # behaviour and was not this game's: it used to fire on every press, so a pistol went as
    # fast as your thumb. Four stages is one round every twenty-four passes however hard you
    # press, and the way to fire faster is to find a better gun.
    STAGE_PASSES = 6

    # ...so this is how long one shot takes from the press to the trigger coming live again.
    CYCLE = STAGES * STAGE_PASSES

    # How far a knife reaches, in cells — near enough to touch. The original's own number, and
    # it is a hard edge rather than a falloff: inside it the knife does what it does, outside it
    # the swing simply misses.
    KNIFE_REACH = 1.5

    SQUARE = WeaponAtlas::SIDE

    # HOW BIG THE GUN IS DRAWN, and it is not a matter of taste: the original scales the
    # weapon's square to the height of the view and centres it across the screen, so the square
    # is as wide as the view is tall and every frame lands in the same place.
    #
    # A TEXTURE COLUMN IS THIS MANY PIXELS ACROSS, which here comes to two, and that is also the
    # width of a strip — so every column of the picture is drawn and none is skipped. The walls
    # are drawn four pixels to a strip and sample every other column, which is right for
    # something a corridor away and wrong for the one thing the player is looking straight at.
    # It costs nothing to do it properly: the pixels are the same either way, and only the
    # number of strips differs.
    SCALE = FirstPerson::VIEW_H / SQUARE
    LEFT = (FirstPerson::ACROSS - (SQUARE * SCALE)) / 2

    # +atlas+ is the pictures, or nil on a build with no copy of the game to read them from —
    # and then everything below still works and simply draws nothing. +sounds+ is the recorded
    # sounds, or nil where there are none. +ammo+ is what the guns spend, as the view keeps it.
    def initialize(build:, ammo:, atlas: nil, sounds: nil)
      @b = build
      @ammo = ammo
      @atlas = atlas
      @sounds = sounds
      declare
    end

    # WHICH WEAPON IS IN YOUR HANDS, which the shot reads to know whether it is a knife.
    attr_reader :in_hand

    # DID THE WEAPON ACT ON THIS PASS? True on the one pass a round leaves the barrel or the
    # knife goes in, which is what the view hangs the shot itself off — so what a weapon does to
    # a MAN stays with the men, and what it does to the player's hands stays here.
    def acted = @acted == 1

    # ONE PASS OF THE GAME LOOP: change weapon or start an attack, or carry on the one that is
    # already running.
    #
    # IT IS HERE RATHER THAN ON THE CLOCK because every button it reads is read on its EDGE —
    # the trigger and the two that change weapon alike. A routine run again for each frame that
    # a late pass answered for would fire a bullet for every one of them, and would walk two
    # weapons along on one press. See FirstPerson::PACING.
    def update
      @acted.set 0
      (@stage < 0).then { standing_ready }.else { carry_the_attack_on }
    end

    # THE PICTURE, over the view, once the room behind it has been drawn.
    def draw
      return if @atlas.nil?

      @b.call :draw_the_gun
    end

    # A WEAPON OFF THE FLOOR. The original hands you six rounds and then the gun, and only
    # switches you to it when it beats what you were already carrying — so walking back over a
    # machine gun while holding a chain gun does not put you a step backwards.
    def give(which)
      (@best < which).then do
        @best.set which
        @chosen.set which
        @in_hand.set which
      end
    end

    # ...and a floor started again puts the pistol back in your hands.
    #
    # THE ORIGINAL DOES THIS WHEN YOU DIE and not when a floor starts — but this game already
    # puts the health and the ammunition back on both, so the weapon goes with them rather than
    # being the one thing that survives a lift.
    def start_again
      @in_hand.set STARTING
      @chosen.set STARTING
      @best.set STARTING
      @stage.set AT_REST
      @wait.set 0
    end

    private

    FP = FirstPerson

    def declare
      b = @b
      # WHAT IS IN YOUR HANDS, WHAT YOU CHOSE, AND THE BEST YOU HAVE FOUND. Three numbers where
      # one looks like enough — see the note at the top of this file for why the middle one is
      # the one that matters.
      @in_hand = b.var :weapon, STARTING
      @chosen = b.var :weapon_chosen, STARTING
      @best = b.var :weapon_best, STARTING

      # WHERE THE ATTACK HAS GOT TO, and how long this stage has left. At rest is a stage of
      # minus one rather than a flag of its own, so "am I attacking" is one comparison.
      @stage = b.var :weapon_stage, AT_REST
      @wait = b.var :weapon_wait, 0
      # ...and which stage comes next, worked out before the stage acts so that an automatic can
      # send itself back a step from inside its own arm.
      @next = b.var :_weapon_next, 0
      @acted = b.var :_weapon_acted, 0

      declare_the_picture
    end

    def declare_the_picture
      return if @atlas.nil?

      b = @b
      b.image :weapons, width: @atlas.width, height: @atlas.height,
                        data: @atlas.pixels, transparent: true

      # WHICH COLUMNS OF EACH FRAME HOLD ANYTHING. A knife at rest is ten columns of its
      # sixty-four and the rest is room showing through, so walking those columns would be the
      # whole depth of the picture paid for nothing at all — the same saving the guards make.
      @first_column = b.table :gun_first, @atlas.first_columns, width: :byte
      @last_column = b.table :gun_last, @atlas.last_columns, width: :byte

      @shape, @column, @wide, @at =
        %i[shape column wide at].map { |name| b.var(:"_gun_#{name}", 0) }

      # A ROUTINE, for the reason everything else that draws in this game is one: written into
      # the game loop it is another block of code competing for the console's quick memory with
      # the rays the frame really goes into.
      #
      # IT CARRIES ITS OWN EDGES, like the standing things, because a routine's body is built
      # where it is DECLARED and not where it is called — so the view's own clip cannot reach in
      # here. Nothing the gun draws can leave the view, but saying so costs nothing and the
      # alternative is a rule that only holds while nobody moves the numbers.
      b.func(:draw_the_gun) do
        b.inside 0, 0, FP::ACROSS, FP::VIEW_H do
          which_picture
          draw_the_strips
        end
      end
    end

    # WHICH OF THE TWENTY PICTURES: the weapon's own five, and then at rest or one of the four
    # it attacks with.
    def which_picture
      @shape.set(@in_hand * WeaponAtlas::FRAMES)
      (@stage >= 0).then { @shape.add(@stage + 1) }
    end

    def draw_the_strips
      b = @b
      @column.set(@first_column[@shape])
      @wide.set(@last_column[@shape] - @column + 1)
      # ...and where this frame's columns begin in the row of all twenty.
      @shape.set(@shape * SQUARE)

      b.repeat(@wide, estimate: { usually: @atlas.usual_columns,
                                  most: @atlas.most_columns }) do |step|
        @at.set(@column + step)
        # THE WHOLE SQUARE, from the top of the view to the bottom of it, which is what the
        # original scales a weapon to. Every row of it is walked in the writing and hardly any
        # in the running: the framework ships where each COLUMN of a see-through picture holds
        # pixels and walks those stretches alone, so the empty sky above the gun costs the
        # column that has none nothing at all. See WeaponAtlas for what happens when it cannot.
        b.draw_column_at :weapons, slice: @shape + @at, x: LEFT + (@at * SCALE),
                                   top: 0, height: FP::VIEW_H, width: SCALE
      end
    end

    # NOT ATTACKING, which is where the trigger is read and where a weapon can be changed. Both
    # are here rather than in every pass because that is where the original reads them — a
    # player in the middle of a shot is in a different state, and neither button reaches it.
    # That is why leaning on the trigger of a chain gun locks you into the chain gun.
    def standing_ready
      put_back_what_you_chose
      change_the_weapon
      start_an_attack
    end

    # A gun that ran dry put the knife in your hands and left your CHOICE alone, so the moment a
    # clip puts a round back the gun you chose comes back on its own. Asked of the knife first,
    # which is false on nearly every pass of the game — so a player holding a gun pays one
    # comparison for it.
    def put_back_what_you_chose
      (@in_hand == KNIFE).then do
        ((@chosen != KNIFE) & (@ammo > 0)).then { @in_hand.set @chosen }
      end
    end

    # THE SHOULDER BUTTONS WALK THE LIST, which is what is left once the original's four number
    # keys have nowhere to go — it carries next and previous for a joystick, and this is that.
    # Both wrap, between the knife and the best you have found, and the half people get wrong is
    # going back off the first one: that lands on the best.
    #
    # WITH NOTHING TO FIRE YOU CANNOT CHANGE, which is the original's own first line: an empty
    # player is stuck holding the knife until they find a clip.
    #
    # IT STEPS FROM WHAT IS IN YOUR HANDS rather than from what you chose, which are the same
    # number whenever this can be reached at all — the one thing that parts them is running out,
    # and running out is what the line above turns away.
    def change_the_weapon
      (@ammo > 0).then do
        @b.pressed(:r).then { take_the_next_one }
        @b.pressed(:l).then { take_the_one_before }
      end
    end

    def take_the_next_one
      @chosen.set(@in_hand + 1)
      (@chosen > @best).then { @chosen.set KNIFE }
      @in_hand.set @chosen
    end

    def take_the_one_before
      @chosen.set(@in_hand - 1)
      (@chosen < KNIFE).then { @chosen.set @best }
      @in_hand.set @chosen
    end

    # THE TRIGGER, read on its edge, so holding it down does not start a second attack — the two
    # automatics repeat from inside the attack itself rather than from another press.
    def start_an_attack
      @b.pressed(:b).then do
        @stage.set 0
        @wait.set STAGE_PASSES
      end
    end

    # ...and once one has started it runs itself. A stage acts as it ENDS, which is the
    # original's own arrangement and is what lets a stage send the attack backwards: the arm
    # that acts is also the arm that says where to go next.
    def carry_the_attack_on
      @wait.sub 1
      (@wait <= 0).then do
        @wait.set STAGE_PASSES
        @next.set(@stage + 1)
        (@stage == FIRES).then { the_weapon_acts }
        (@stage == REPEATS).then { the_automatics_carry_on }
        @stage.set @next
        (@stage >= STAGES).then { finish_the_attack }
      end
    end

    # The weapon does its one thing: the knife goes in, and everything else fires a round.
    def the_weapon_acts
      (@in_hand == KNIFE).then { @acted.set 1 }.else { fire_a_round }
    end

    # A ROUND LEAVES THE BARREL, and the gun goes quiet if that was the last one — a player with
    # nothing left is holding the knife, and the choice they made is remembered for the clip
    # they are about to go looking for.
    def fire_a_round
      (@ammo > 0).then do
        @ammo.sub 1
        @acted.set 1
        the_gun_is_heard
        (@ammo == 0).then { @in_hand.set KNIFE }
      end
    end

    # THE ONE LINE THAT SEPARATES THE TWO AUTOMATICS. Both go back to the firing stage while the
    # button is held; the chain gun fires on the way past as well, so it puts out two rounds in
    # the time the machine gun puts out one.
    def the_automatics_carry_on
      (@in_hand == CHAIN_GUN).then { fire_a_round }
      ((@in_hand >= MACHINE_GUN) & (@ammo > 0) & @b.held(:b)).then { @next.set FIRES }
    end

    def finish_the_attack
      @stage.set AT_REST
      (@ammo > 0).then { @in_hand.set @chosen }
    end

    # Each gun has its own recording, which is the one place a machine gun and a chain gun
    # differ to the ear. The knife's is an ADLIB effect and no copy of the game holds a
    # recording of it, so the knife goes in quietly.
    def the_gun_is_heard
      return if @sounds.nil? || !@sounds.any?

      (@in_hand == PISTOL).then { @sounds.pistol }
      (@in_hand == MACHINE_GUN).then { @sounds.machine_gun }
      (@in_hand == CHAIN_GUN).then { @sounds.chain_gun }
    end
  end
end
