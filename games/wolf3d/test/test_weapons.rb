# frozen_string_literal: true

require_relative "test_helper"

# The four weapons: the picture of the one in your hands, the cycle it runs when you fire, the
# two shoulder buttons that walk between them, and the two that lie on the floor of a level.
class TestWeapons < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Weapons = Wolf3D::Weapons
  Atlas = Wolf3D::WeaponAtlas
  Guards = Wolf3D::Guards
  Scenery = Wolf3D::Scenery
  Pickups = Wolf3D::Pickups
  Release = Wolf3D::Fixture::Release

  SIDE = 16
  FLOOR = Release::FIRST_FLOOR
  WALL = Release::WALL

  # Where the level lays them down, as Wolfenstein numbers the things standing in a room.
  MACHINE_GUN = 27
  CHAIN_GUN = 28
  CLIP = Scenery::CLIP

  # --- the pictures ------------------------------------------------------------------

  def test_the_weapons_are_the_last_twenty_sprites_of_the_file
    assert_equal 4 * 5, Atlas::COUNT, "four weapons, five pictures each"
    assert_equal vswap.sprite_count - Atlas::COUNT, Atlas.first_sprite(vswap)
    assert Atlas.in?(vswap), "every release holds them"
  end

  # A GUN HANGS OFF THE BOTTOM of its square in every frame, so the top of the square is empty in
  # all twenty — and the picture ships the rows that have art in them and no others. That is what
  # keeps it out of the cartridge and out of the walk down the screen.
  def test_the_picture_holds_only_the_rows_that_have_art_in_them
    assert_operator atlas.top_row, :>, 0, "the top of a weapon's square is empty"
    assert_equal Atlas::SIDE - 1, atlas.bottom_row, "and its art reaches the bottom edge"
    assert_equal atlas.bottom_row - atlas.top_row + 1, atlas.height
    assert_equal Atlas::COUNT * Atlas::SIDE, atlas.width, "twenty frames side by side"
    assert_equal atlas.width * atlas.height, atlas.pixels.length
  end

  # --- the gun on the screen ---------------------------------------------------------

  # THE PISTOL IS THERE WHEN THE GAME STARTS, at the bottom middle of the view and nowhere near
  # the top of it. The fixture paints every picture one flat colour of its own, so the colour on
  # the screen says which of the twenty was drawn.
  def test_the_gun_is_drawn_at_the_bottom_middle_of_the_view
    run = Reference.new.run(program(drawing: true), frames: 3, max_steps: 8_000_000)

    assert_equal frame_colour(Weapons::PISTOL, 0), run.screen.pixel(*where_the_gun_is),
                 "the pistol at rest, in your hands"
    refute_equal frame_colour(Weapons::PISTOL, 0), run.screen.pixel(FP::ACROSS / 2, 10),
                 "and nothing of it up by the ceiling"
  end

  # THE FOUR STAGES, in the picture: a press raises the gun, fires it, follows through and lowers
  # it, six passes each, and then the at-rest picture is back.
  def test_the_picture_walks_the_four_stages_and_comes_back_to_rest
    inside_each_stage = (0...Weapons::STAGES).map { |stage| (stage * Weapons::STAGE_PASSES) + 4 }

    assert_equal [1, 2, 3, 4], inside_each_stage.map { |passes| gun_frame_after(passes) },
                 "one picture a stage, in order"
    assert_equal 0, gun_frame_after(Weapons::CYCLE + 4), "and back to rest when it is over"
  end

  # A ROUND LEAVES ON THE SECOND STAGE, not on the press — which is the original's timing and is
  # what makes tapping the trigger faster than the gun cycles do nothing at all.
  def test_a_round_leaves_a_dozen_passes_after_the_press
    fires_on = Weapons::STAGE_PASSES * 2

    assert_equal FP::START_AMMO, tap_once(passes: fires_on - 2)[:ammo], "still coming up"
    assert_equal FP::START_AMMO - 1, tap_once(passes: fires_on + 2)[:ammo], "and now it has gone"
  end

  def test_holding_the_trigger_down_fires_a_pistol_once
    held = Reference.new.input_each_frame { [:b] }
                   .run(program, frames: Weapons::CYCLE * 4, max_steps: 20_000_000)

    assert_equal FP::START_AMMO - 1, held[:ammo],
                 "a pistol is one press one round, however long you lean on it"
  end

  # --- changing weapon ---------------------------------------------------------------

  # THE SHOULDER BUTTONS WALK THE LIST, and it wraps between the knife and the best you have.
  # Carrying only a pistol, that list is two long.
  def test_the_shoulder_buttons_walk_between_the_weapons_you_have
    assert_equal Weapons::KNIFE, pressing([:r])[:weapon], "forward off the pistol is the knife"
    assert_equal Weapons::PISTOL, pressing([:r], [:r])[:weapon], "...and round again"
    assert_equal Weapons::KNIFE, pressing([:l])[:weapon], "back off the pistol is the knife too"
  end

  def test_the_weapon_you_changed_to_is_the_one_on_the_screen
    run = pressing([:r], drawing: true)

    assert_equal frame_colour(Weapons::KNIFE, 0), run.screen.pixel(*where_the_gun_is)
  end

  # WITH NOTHING TO FIRE YOU CANNOT CHANGE, which is the original's own first line — an empty
  # player is stuck holding the knife until they find a clip. And the CHOICE is remembered, which
  # is why there are two numbers here and not one.
  def test_running_out_puts_the_knife_in_your_hands_without_forgetting_what_you_chose
    empty = empty_the_pistol(then_walking: false)

    assert_equal 0, empty[:ammo], "the pistol should be empty by now"
    assert_equal Weapons::KNIFE, empty[:weapon], "which puts the knife in your hands"
    assert_equal Weapons::PISTOL, empty[:weapon_chosen], "without forgetting what you chose"
  end

  # ...AND A CLIP GIVES THE GUN BACK ON ITS OWN, so nobody ever picks their pistol up by hand.
  def test_a_clip_puts_the_gun_you_chose_back_in_your_hands
    took = empty_the_pistol(then_walking: true)

    assert_operator took[:ammo], :>, 0, "the clip is in"
    assert_equal Weapons::PISTOL, took[:weapon], "and the pistol is back"
  end

  # --- the two guns on the floor -----------------------------------------------------

  def test_a_gun_off_the_floor_gives_six_rounds_and_itself
    took = walk_over([MACHINE_GUN])

    assert_equal FP::START_AMMO + Pickups::WEAPON_ROUNDS, took[:ammo]
    assert_equal Weapons::MACHINE_GUN, took[:weapon], "and it is in your hands"
    assert_equal Weapons::MACHINE_GUN, took[:weapon_best]
  end

  # A BETTER GUN BEATS THE ONE YOU HAVE AND A WORSE ONE DOES NOT, so walking on over a machine
  # gun holding a chain gun does not put you a step backwards. The rounds are taken either way.
  def test_a_worse_gun_off_the_floor_does_not_replace_a_better_one
    took = walk_over([CHAIN_GUN, MACHINE_GUN])

    assert_equal Weapons::CHAIN_GUN, took[:weapon]
    assert_equal FP::START_AMMO + (Pickups::WEAPON_ROUNDS * 2), took[:ammo],
                 "both were picked up, so both gave their rounds"
  end

  # --- what the automatics do --------------------------------------------------------

  # THE MACHINE GUN REPEATS WHILE THE BUTTON IS HELD, where a pistol fires once and stops. That
  # is one line of the original's table: the third stage goes back to the second.
  def test_the_machine_gun_keeps_firing_while_the_button_is_held
    assert_operator rounds_holding_the_trigger(MACHINE_GUN), :>, 1,
                    "a machine gun does not stop after one"
  end

  # ...AND THE CHAIN GUN AT TWICE THE RATE, which is the whole difference between the two: its
  # repeating stage fires on the way past. The first round is the same one for both — it is the
  # ones after it that come twice as fast.
  def test_the_chain_gun_fires_twice_as_fast_as_the_machine_gun
    machine = rounds_holding_the_trigger(MACHINE_GUN)
    chain = rounds_holding_the_trigger(CHAIN_GUN)

    assert_equal (machine - 1) * 2, chain - 1,
                 "the chain gun put out #{chain} where the machine gun put out #{machine}"
  end

  # --- what a knife does -------------------------------------------------------------

  # A KNIFE IS NOT A GUN AT ZERO RANGE: it reaches about a cell and a half, and past that the
  # swing meets nothing at all. The guard here is five cells off — in the sights, in the open,
  # and well within a pistol's reach, which is what makes the knife's answer worth reading.
  def test_a_knife_does_not_reach_a_guard_across_the_room
    assert_operator attack_a_guard(with_knife: false), :<, Guards::HIT_POINTS,
                    "a pistol reaches him"
    assert_equal Guards::HIT_POINTS, attack_a_guard(with_knife: true),
                 "and a knife does not touch him"
  end

  def test_a_knife_costs_no_ammunition
    swung = Reference.new.input_each_frame { |f| swinging(f, with_knife: true) }
                    .run(program, frames: Weapons::CYCLE * 3, max_steps: 20_000_000)

    assert_equal Weapons::KNIFE, swung[:weapon]
    assert_equal FP::START_AMMO, swung[:ammo], "a knife spends nothing"
  end

  # --- and on the console ------------------------------------------------------------

  # THE CARTRIDGE DRAWS THE GUN THE ORACLE DRAWS, pixel for pixel over the rows it hangs in.
  def test_the_console_draws_the_gun_the_interpreter_draws
    built = program(drawing: true)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(built), title: "WEAPON", code: "ZWPN", maker: "01")

    interp = Reference.new.run(built, frames: 3, max_steps: 8_000_000)
    gba = RubyGBA::Verifier.new(rom, frames: 8)

    across = (Weapons::LEFT...(Weapons::LEFT + FP::VIEW_H)).step(4).to_a
    down = ((atlas.top_row * Weapons::SCALE)...FP::VIEW_H).step(4).to_a
    differ = across.product(down).reject do |x, y|
      (interp.screen.pixel(x, y) || 0) == gba.pixel_gba(x, y)
    end

    assert_empty differ.first(8), "these pixels of the gun differ between the two"
  end

  private

  def fixture = @fixture ||= Release.new
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game
  def atlas = @atlas ||= Atlas.new(vswap, palette)

  # The flat colour the fixture gave one of the twenty pictures: which weapon, and which of its
  # five — nought at rest, then one for each stage of an attack.
  def frame_colour(weapon, pose)
    palette[Release::SPRITE_INK + Atlas.first_sprite(vswap) + (weapon * Atlas::FRAMES) + pose]
  end

  # Where in the view the gun's art lands: the middle of the band the fixture paints it in.
  def where_the_gun_is
    [FP::ACROSS / 2, (atlas.top_row * Weapons::SCALE) + atlas.height]
  end

  # Which of the pistol's five pictures is on the screen after that many passes, or nil for none
  # of them.
  def gun_frame_after(passes)
    on_screen = tap_once(passes: passes, drawing: true).screen.pixel(*where_the_gun_is)
    (0...Atlas::FRAMES).find { |pose| frame_colour(Weapons::PISTOL, pose) == on_screen }
  end

  # ONE TAP, on the second pass, and then nothing — everything about the cycle is read off this.
  # The second rather than the first because a press is an edge, and the first pass has no pass
  # before it for the button to have been up on.
  def tap_once(passes:, drawing: false)
    Reference.new.input_each_frame { |f| f == 1 ? [:b] : [] }
             .run(program(drawing: drawing), frames: passes + 2, max_steps: 20_000_000)
  end

  # Press each of these in turn, a pass apart, with the button up between them so every one is
  # read as a press of its own.
  def pressing(*presses, drawing: false)
    Reference.new.input_each_frame { |f| f.odd? ? (presses[f / 2] || []) : [] }
             .run(program(drawing: drawing), frames: (presses.length * 2) + 4,
                  max_steps: 20_000_000)
  end

  # Fire until the pistol is empty, and then — if asked — walk on to the clip lying ahead.
  def empty_the_pistol(then_walking:)
    emptying = Weapons::CYCLE * (FP::START_AMMO + 1)
    walking = then_walking ? passes_to_cross(2) : 0
    Reference.new.input_each_frame { |f| f < emptying ? (f.even? ? [:b] : []) : [:up] }
             .run(program(ahead: [CLIP]), frames: emptying + walking, max_steps: 60_000_000)
  end

  # Walk east over whatever is laid out in front of you, far enough to cross all of it.
  def walk_over(ahead)
    Reference.new.input_each_frame { [:up] }
             .run(program(ahead: ahead), frames: passes_to_cross(ahead.length + 1),
                  max_steps: 40_000_000)
  end

  # Take the gun lying in front of you, then lean on the trigger and count what it puts out.
  def rounds_holding_the_trigger(gun)
    walked = passes_to_cross(2)
    holding = Weapons::CYCLE * 2
    run = Reference.new.input_each_frame { |f| f < walked ? [:up] : [:b] }
                  .run(program(ahead: [gun]), frames: walked + holding, max_steps: 60_000_000)

    FP::START_AMMO + Pickups::WEAPON_ROUNDS - run[:ammo]
  end

  # Attack the guard standing across the room, with the knife or with the pistol, and read what
  # he has left afterwards.
  def attack_a_guard(with_knife:)
    run = Reference.new.input_each_frame { |f| swinging(f, with_knife: with_knife) }
                  .run(program(guards: [[9, 8, :west]]), frames: Weapons::CYCLE * 4,
                       max_steps: 60_000_000)
    run.instance_variable_get(:@lists)[:__pool_guard_hp].get(0)
  end

  # Change to the knife first if that is what is being asked about, and then tap the trigger as
  # fast as the weapon will take it.
  def swinging(pass, with_knife:)
    return with_knife ? [:r] : [] if pass == 1
    return [] if pass < 4

    pass.even? ? [:b] : []
  end

  # How many passes it takes to walk that many cells, with a little over.
  def passes_to_cross(cells) = ((cells / FP::WALK) * 1.2).ceil

  # A WALLED FIELD with the player on the left of the middle row facing east, and whatever you
  # name laid out on the cells in front of them.
  def arena(ahead: [], guards: [])
    cells = Array.new(SIDE * SIDE, FLOOR)
    standing = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        cells[(y * SIDE) + x] = WALL if x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
      end
    end
    row = SIDE / 2
    standing[(row * SIDE) + 4] = Wolf3D::Level::FACINGS.key(:east)
    ahead.each_with_index { |piece, n| standing[(row * SIDE) + 5 + n] = Scenery::FIRST_CODE + piece }
    guards.each { |x, y, way| standing[(y * SIDE) + x] = Guards::STANDING + Guards::FACINGS.index(way) }

    Wolf3D::Level.new(name: "Weapons", width: SIDE, height: SIDE, walls: cells, things: standing)
  end

  # Built once for each shape of level, since building one takes far longer than running it.
  # +drawing+ off is the whole view skipped, which every test that reads a variable rather than a
  # pixel can have for nothing.
  def program(ahead: [], guards: [], drawing: false)
    @programs ||= {}
    @programs[[ahead, guards, drawing]] ||= build(arena(ahead: ahead, guards: guards), drawing)
  end

  def build(level, drawing)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    scenery = Scenery.new(level)
    walls = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette,
                                    (guards.pictures + scenery.pictures +
                                     Pickups.pictures(guards)).uniq.sort)
    guns = atlas

    RubyGBA.game("WEAPON", code: "ZWPN", maker: "01") do
      screen :bitmap, tear_free: true
      view = FP.new(build: self, level: level, atlas: walls, doors: doors, pushwalls: pushwalls,
                    guards: guards, things: things, scenery: scenery, gun_art: guns)
      game_loop { drawing ? view.update : view.play }
    end.program
  end
end
