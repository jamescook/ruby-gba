# frozen_string_literal: true

require "test_helper"
require "differential"

# THE CONSOLE LENDS ITS GROUPS OF SPRITE COLOURS to the lists things on screen are wearing.
# A game whose things between them wear more lists than the console has groups still fits,
# so long as no more are worn at once than the groups left over: a list is given a group the
# frame something on screen first wears it, and the group goes back once nothing does. Only
# the console has groups to run short of, so every other build is the answer key here.
class TestSpriteBorrowedColors < Minitest::Test
  include Differential

  OWN = [:transparent, :red, :green].freeze

  # An 8x8 thing, left half the first colour of its list and right half the second.
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  # More kinds than the console has groups for sprites, each wearing a list of its own.
  KINDS = 20
  KIND_LISTS = (0...KINDS).map { |n| :"kind#{n}" }.freeze

  # Kind +n+'s list: two colours no other kind has.
  def self.colors_of_kind(n) = [:transparent, RubyGBA::Graphics::Color.rgb(n, 31 - n, 5), RubyGBA::Graphics::Color.rgb(31 - n, n, 9)]

  private def built(&body)
    klass = self.class
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      (0...KINDS).each { |n| colors :"kind#{n}", klass.colors_of_kind(n) }
      instance_eval(&body)
    end
    builder.finalize_program
    builder.program
  end

  # Things of every kind in turn: one made every third pass, each standing at a place of
  # its kind's own and gone nine passes later, so three or four are on screen at a time and
  # every spare group has been lent out by the fiftieth pass. +before+ declares more above
  # the loop; +each_pass+ runs in it, handed the pass number.
  private def things_coming_and_going(before: nil, &each_pass)
    built do
      instance_exec(&before) if before
      things = pool :thing, x: 0, y: 0, kind: 0, age: 0, capacity: 4, image: :ship
      made = var :made, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick % 3 == 1).then do
          things.spawn x: ((made % 10) * 20) + 10, y: ((made / 10) % 2 * 20) + 40, kind: made % KINDS
          made.add! 1
        end
        things.each do |thing|
          thing.age.add! 1
          (thing.age > 9).then { thing.remove }
          thing.draw_with KIND_LISTS, showing: thing.kind
        end
        instance_exec(tick, &each_pass) if each_pass
      end
    end
  end

  def test_twenty_kinds_a_few_at_a_time_fit_the_console
    GBA.new.lower(things_coming_and_going)
  end

  def test_each_thing_wears_its_own_colors
    [4, 11, 25, 40, 66].each { |frames| assert_backends_agree(things_coming_and_going, frames: frames) }
  end

  # Read off the console's own table rather than compared with the interpreter: every thing
  # on screen wears the list of the kind its place says it is, frame after frame, as things
  # of new kinds keep arriving.
  def test_the_console_lends_each_thing_its_kinds_colors
    v = assert_emulator_loads_rom(assemble_rom(things_coming_and_going, name: "LENT"), frames: 10)
    seen = 0
    12.times do
      v.step(5)
      v.sprites(:thing).each do |row|
        kind = (((row.y - 40) / 20) * 10) + ((row.x - 10) / 20)
        assert_equal self.class.colors_of_kind(kind)[1, 2], row.colors[1, 2], "kind #{kind} at #{row.x}, #{row.y}"
        seen += 1
      end
    end
    assert_operator seen, :>, 30
  end

  # A list's colours go in through the tint in force, as any list's do.
  def test_lent_colors_go_in_through_a_tint
    tinted = things_coming_and_going { |_tick| tint :red, 40 }

    [4, 25].each { |frames| assert_backends_agree(tinted, frames: frames) }
  end

  # A sprite that never moves, drawn with one list the whole game, keeps that list's group
  # while every other group is lent and lent again around it.
  def test_a_sprite_that_never_moves_keeps_its_group
    still = things_coming_and_going(before: -> { sprite(:ship, at: [200, 120]).draw_with :kind5 })

    [50, 70].each { |frames| assert_backends_agree(still, frames: frames) }
  end

  # Hidden, a sprite wears nothing, so its group goes to other lists; shown again, it
  # borrows one afresh and its colours are copied in again.
  def test_a_sprite_shown_again_borrows_again
    watcher = nil
    hidden = things_coming_and_going(before: -> { watcher = sprite(:ship, at: [200, 120]) }) do |tick|
      watcher.draw_with :kind7
      ((tick > 4) & (tick < 50)).then { watcher.hide }.else { watcher.show }
    end

    [45, 52, 60].each { |frames| assert_backends_agree(hidden, frames: frames) }
  end

  # A scene taking over sends its own table of sprite colours, which writes over every group;
  # the groups lent out are written again from the lists that hold them. The second scene has
  # a sprite of its own drawn with a list that borrows too.
  def test_lent_colors_survive_a_scene_taking_over
    switching = built do
      image :dot, width: 8, height: 8, data: Array.new(64, :blue), colors: %i[transparent blue white]
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: 4, image: :ship
      4.times { |n| things.spawn x: 10 + (n * 20), y: 40, kind: n * 3 }
      scene(:plain) { sprite :ship, at: [100, 100] }
      scene(:dotted) { sprite(:dot, at: [100, 100]).draw_with :kind9 }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        state.set!((tick / 7) % 2)
        things.each { |thing| thing.draw_with KIND_LISTS, showing: thing.kind }
        case_var(:state) do
          when_val 0, :plain
          when_val 1, :dotted
        end
      end
    end

    [5, 9, 16, 23].each { |frames| assert_backends_agree(switching, frames: frames) }
  end

  # More lists worn at once than there are groups to lend: the console draws the extra
  # things from a group another list holds, as the console's own games do, and counts it.
  def test_more_lists_worn_at_once_than_groups_are_counted
    crowded = built do
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: KINDS, image: :ship
      KINDS.times { |n| things.spawn x: ((n % 10) * 20) + 10, y: ((n / 10) * 20) + 40, kind: n }
      game_loop { things.each { |thing| thing.draw_with KIND_LISTS, showing: thing.kind } }
    end
    rom = assemble_rom(crowded, name: "CROWDED")
    v = assert_emulator_loads_rom(rom, frames: 6, vars: rom.var_addresses)

    assert_operator v.var(:__lent_colors_missed), :>, 0
  end
end
