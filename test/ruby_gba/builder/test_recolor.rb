# frozen_string_literal: true

require "test_helper"
require "differential"

# A LIST OF SPRITE COLOURS THAT HOLDS OTHER COLOURS while the game runs. A sprite told to
# draw with a list is drawn in whatever that list holds now, so one list can dress a
# goblin in one room and a bat in the next: the list is a slot, and `recolor` says what
# is in it.
class TestRecolor < Minitest::Test
  include Differential

  OWN = [:transparent, :red, :green].freeze
  SLOT = [:transparent, :blue, :white].freeze
  WARM = [:transparent, :yellow, :orange].freeze
  COLD = [:transparent, :gray, :black].freeze

  # An 8x8 ship, left half the first colour of its list and right half the second, so a
  # swapped colour shows at a known place.
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  # More sets of colours than the console has groups for sprites.
  SETS = 20

  # Set number +n+: two colours no other set has.
  def self.set(n) = [:transparent, RubyGBA::Graphics::Color.rgb(n, 31 - n, 5), RubyGBA::Graphics::Color.rgb(31 - n, n, 9)]

  # The ship's picture and the lists, then whatever the block declares.
  def built(&body)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :slot, SLOT
      colors :warm, WARM
      colors :cold, COLD
      instance_eval(&body)
    end
    builder.finalize_program
    builder.program
  end

  # A ship drawn with the list :slot, and a loop that does what the block says. +before+
  # runs once, above the loop.
  def program(before: nil, &game)
    built do
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      instance_exec(&before) if before
      game_loop { instance_exec(ship, &game) }
    end
  end

  # The ship's two halves, as the interpreter draws them after +frames+.
  def halves(program, frames: 3)
    i = Reference.new.run(program, frames: frames)
    [i.screen.pixel(41, 41), i.screen.pixel(45, 41)]
  end

  def colors_of(*names) = names.map { |name| Color.resolve(name) }

  def test_a_list_nothing_recolors_holds_the_colors_it_was_declared_with
    assert_equal colors_of(:blue, :white), halves(program { |_ship| nil })
  end

  def test_a_sprite_drawn_with_a_list_shows_the_colors_the_list_holds_now
    assert_equal colors_of(:yellow, :orange), halves(program { |_ship| recolor :slot, :warm })
  end

  # One of several, by a number the game works out: the ship's column counts up, so the
  # number is 2 by the third frame.
  def counting_through_the_sets
    program do |ship|
      ship.x.add! 1
      recolor :slot, [:slot, :warm, :cold], showing: ship.x - 40
    end
  end

  def test_a_number_the_game_works_out_picks_which_colors_the_list_holds
    i = Reference.new.run(counting_through_the_sets, frames: 3)

    assert_equal colors_of(:gray, :black), [i.screen.pixel(43, 41), i.screen.pixel(47, 41)]
  end

  # A number that names none of them is the colors the list was declared with, so a counter
  # that has run off the end looks right.
  def test_a_number_outside_the_set_is_the_colors_it_was_declared_with
    assert_equal colors_of(:blue, :white), halves(program { |ship| recolor :slot, [:warm, :cold], showing: ship.x })
  end

  def test_own_puts_back_the_colors_it_was_declared_with
    back = program do |ship|
      ship.x.add! 1
      recolor :slot, :warm
      (ship.x > 41).then { recolor :slot, :own }
    end
    i = Reference.new.run(back, frames: 4)

    assert_equal colors_of(:blue, :white), [i.screen.pixel(44, 41), i.screen.pixel(48, 41)]
  end

  # `draw_with` and `recolor` can come in either order: a list is one that changes because
  # something somewhere recolors it, however late that is written.
  def test_a_sprite_told_to_draw_with_the_list_after_it_is_recolored_shows_them_too
    late = built do
      recolor :slot, :warm
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :slot }
    end

    assert_equal colors_of(:yellow, :orange), halves(late)
  end

  # --- the console ---

  # The console's own pixels, read off the cartridge rather than compared with the
  # interpreter's, so the two cannot agree on showing nothing.
  def test_the_console_shows_the_colors_the_list_holds_now
    recolored = program { |_ship| recolor :slot, :warm }
    v = assert_emulator_loads_rom(assemble_rom(recolored, name: "RECOLOR"), frames: 6)

    assert v.pixel_is?(41, 41, :yellow), "the left half is #{v.pixel_gba(41, 41)}"
    assert v.pixel_is?(45, 41, :orange), "the right half is #{v.pixel_gba(45, 41)}"
    assert_backends_agree(recolored, frames: 3)
  end

  def test_the_console_picks_by_a_number_too
    (2..5).each { |frames| assert_backends_agree(counting_through_the_sets, frames: frames) }
  end

  # --- the point of it: one group of sprite colors, however many sets ---

  # A ship that walks through twenty sets of colors, a new one each frame: by recoloring the
  # one list it is drawn with, or else by being told to draw with each of the twenty.
  def many_sets(through_one_list:)
    klass = self.class
    built do
      names = (0...SETS).map { |n| colors :"set#{n}", klass.set(n) }
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot if through_one_list
      game_loop do
        ship.x.add! 1
        if through_one_list
          recolor :slot, names, showing: ship.x - 41
        else
          ship.draw_with names, showing: ship.x - 41
        end
      end
    end
  end

  def test_twenty_lists_a_sprite_draws_with_do_not_fit_the_console
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(many_sets(through_one_list: false)) }

    assert_match(/16 groups/, error.message)
  end

  def test_twenty_sets_through_one_list_take_one_group
    walking = many_sets(through_one_list: true)
    # A sprite is drawn in the gap before the next frame, so the picture after thirteen
    # frames is where the twelfth pass put the ship, in the set that pass named.
    i = Reference.new.run(walking, frames: 13)

    assert_equal self.class.set(11).drop(1), [i.screen.pixel(53, 41), i.screen.pixel(57, 41)], "set 11"
    [3, 13, 22].each { |frames| assert_backends_agree(walking, frames: frames) }
  end

  # --- with a tint or a fade in force ---

  # A list's colors go into the console's table, and a tint moves every color in that table.
  # So they go in through the tint in force, rather than at full brightness on a red screen.
  def test_colors_go_in_through_a_tint_in_force
    tinted = program(before: -> { tint :red, 50 }) { |_ship| recolor :slot, :warm }

    assert_backends_agree(tinted, frames: 4)
  end

  # ...and a tint that moves afterwards moves the colors the list holds, not the ones it was
  # declared with.
  def test_a_tint_that_moves_keeps_the_colors_the_list_holds
    moving = program do |ship|
      ship.x.add! 1
      recolor :slot, :warm
      tint :red, (ship.x - 40) * 10
    end

    (2..5).each { |frames| assert_backends_agree(moving, frames: frames) }
  end

  # A fade takes the tint's place, which puts the table back as it was drawn: the list still
  # holds what it was told.
  def test_a_fade_that_lifts_a_tint_keeps_the_colors_the_list_holds
    lifted = program do |ship|
      ship.x.add! 1
      recolor :slot, :warm
      (ship.x < 43).then { tint :red, 50 }.else { fade :black, 50 }
    end

    # The fade is the display's own blend, which the emulator rounds a step off (see
    # Differential::EMULATOR_BLEND_SLACK): a list put back in the wrong colors is far outside it.
    [2, 4, 6].each { |frames| assert_backends_agree(lifted, frames: frames, blended: true) }
  end

  # --- pools ---

  def guards_drawn_with_the_list
    built do
      guards = pool :guard, x: 0, y: 0, capacity: 4, image: :ship
      guards.spawn x: 40, y: 40
      guards.spawn x: 80, y: 40
      game_loop do
        guards.each { |g| g.draw_with :slot }
        recolor :slot, :warm
      end
    end
  end

  def test_every_instance_of_a_pool_drawn_with_the_list_shows_its_colors
    i = Reference.new.run(guards_drawn_with_the_list, frames: 4)

    assert_equal colors_of(:yellow, :yellow), [i.screen.pixel(41, 41), i.screen.pixel(81, 41)]
    assert_backends_agree(guards_drawn_with_the_list, frames: 4)
  end

  # THE SHAPE THIS IS FOR: a room's things stand on one pool, each drawn with one of a few
  # lists that are slots, and walking into the next room fills every slot from that room's
  # row of sets on the same frame. Four slots declared alike, so each has to have a group of
  # its own; room 0 wears sets 0 to 3 and room 1, from the third pass, sets 4 to 7.
  def room_of_things
    klass = self.class
    built do
      sets = (0...SETS).map { |n| colors :"set#{n}", klass.set(n) }
      slots = (0...4).map { |n| colors :"slot#{n}", SLOT }
      things = pool :thing, x: 0, y: 0, slot: 0, capacity: 4, image: :ship
      4.times { |n| things.spawn x: 40 + (n * 20), y: 40, slot: n }
      room = var :room, 0
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 3).then { room.set! 1 }
        things.each { |thing| thing.draw_with slots, showing: thing.slot }
        slots.each_with_index { |slot, n| recolor slot, sets, showing: (room * 4) + n }
      end
    end
  end

  # The left half of each of the four things, as the interpreter draws them after +frames+.
  def things_drawn(frames)
    i = Reference.new.run(room_of_things, frames: frames)
    (0...4).map { |n| i.screen.pixel(41 + (n * 20), 41) }
  end

  def test_a_rooms_things_wear_the_sets_their_slots_were_filled_with
    assert_equal (0...4).map { |n| self.class.set(n)[1] }, things_drawn(3), "the first room"
    assert_equal (4...8).map { |n| self.class.set(n)[1] }, things_drawn(6), "the second room"
    [3, 4, 5, 6].each { |frames| assert_backends_agree(room_of_things, frames: frames) }
  end

  # --- friendly errors ---

  def refused(&body) = assert_raises(ArgumentError) { built(&body) }.message

  def test_recoloring_a_name_that_is_not_a_list_says_so
    assert_match(/:ghost, which is not a list of colors/, refused { recolor :ghost, :warm })
  end

  def test_recoloring_with_a_name_that_is_not_a_list_says_so
    message = refused { recolor :slot, :ghost }

    assert_match(/list of colors :slot/, message)
    assert_match(/:ghost, which is not a list of colors/, message)
  end

  # A sprite drawn with the list was checked against the places the list has, so a set with
  # fewer would leave some of the sprite's pixels with no color to show.
  def test_a_set_with_fewer_colors_than_the_list_says_so
    message = refused do
      colors :thin, [:transparent, :red]
      recolor :slot, :thin
    end

    assert_match(/:thin, which has 2 colors/, message)
    assert_match(/3 colors or more/, message)
  end

  def test_several_sets_and_nothing_to_pick_between_them_says_so
    assert_match(/nothing to pick\s+between them/, refused { recolor :slot, [:warm, :cold] })
  end

  def test_one_set_and_showing_says_so
    assert_match(/names one list/, refused { recolor :slot, :warm, showing: 1 })
  end

  # A list nothing is drawn with shows nothing whatever it holds: a name spelled two ways.
  def test_recoloring_a_list_no_sprite_draws_with_says_so
    message = refused do
      sprite :ship, at: [40, 40]
      game_loop { recolor :slot, :warm }
    end

    assert_match(/list of colors :slot/, message)
    assert_match(/no sprite or pool draws with it/, message)
  end

  # A picture given as colors records no places. Where its own list has one color at two
  # places and a set gives those places different colors, half its pixels would be drawn
  # wrong — refused for a set a list holds as it is for a list the sprite names itself.
  def test_a_set_that_would_recolor_a_picture_wrongly_says_so
    message = refused do
      image :twin, width: 8, height: 8, data: Array.new(64, :red), colors: [:transparent, :red, :red]
      colors :pair, [:transparent, :blue, :blue]
      twin = sprite :twin, at: [40, 40]
      twin.draw_with :pair
      game_loop { recolor :pair, :warm }
    end

    assert_match(/draws with :pair, which was told to hold :warm/, message)
    assert_match(/place 1 and place 2/, message)
  end

  # A background takes a list's colors as declared, into a group of its own that `recolor`
  # never writes, so it would go on showing the declared ones with nothing to say why.
  def test_a_background_drawn_with_a_list_that_changes_says_so
    message = refused do
      tiles :hull, "#" => :ship
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      plates = background :plates, tiles: :hull, map: ["####"]
      plates.draw_with :slot
      game_loop { recolor :slot, :warm }
    end

    assert_match(/background :plates draws with :slot/, message)
    assert_match(/sprites only/, message)
  end
end
