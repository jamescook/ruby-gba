# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_sprite_borrowed_colors"

# The Advance's cartridge lending its groups of sprite colours: that the lowering takes twenty
# kinds a few at a time, the colours read off the console's own sprite table in the emulator, and
# the count of things it had no group for. What each thing wears on every run is in
# test/all/vblank/dsl/test_sprite_borrowed_colors.rb.
class TestSpriteBorrowedColorsCartridge < Minitest::Test
  include SpriteBorrowedColorsGames

  def test_twenty_kinds_a_few_at_a_time_fit_the_console
    GBA.new.lower(things_coming_and_going)
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
        assert_equal SpriteBorrowedColorsGames.colors_of_kind(kind)[1, 2], row.colors[1, 2],
                     "kind #{kind} at #{row.x}, #{row.y}"
        seen += 1
      end
    end
    assert_operator seen, :>, 30
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
