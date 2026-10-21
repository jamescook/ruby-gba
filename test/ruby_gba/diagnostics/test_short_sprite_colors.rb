# frozen_string_literal: true

require "test_helper"
require "stringio"

# A SPRITE DRAWN IN ANOTHER LIST'S COLOURS because the console ran out of groups to lend.
#
# The console lends the groups of sprite colours its sprites' own colours leave over to the
# lists things on screen wear (see ScreenLayout::LentColors). With more lists on screen at once
# than groups left over, the extra things are drawn in whatever colours a group holds. Nothing
# stops and the build cannot know, since it depends on what is on screen together, so a run
# has to count it and the profile has to say so.
class TestShortSpriteColors < Minitest::Test
  include EmulatorSupport

  OWN = [:transparent, :red, :green].freeze
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  # Each thing wears a list of its own, and +shown+ of them stand on screen together. The
  # ship's own colours take one group of the sixteen, so fifteen are left to lend.
  private def things_on_screen(shown)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      lists = (0...20).map do |n|
        colors :"kind#{n}", [:transparent, RubyGBA::Graphics::Color.rgb(n, 31 - n, 5), :white]
      end
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: 20, image: :ship
      shown.times { |n| things.spawn x: ((n % 10) * 20) + 10, y: ((n / 10) * 20) + 40, kind: n }
      game_loop { things.each { |thing| thing.draw_with lists, showing: thing.kind } }
    end
    b.finalize_program
    b.program
  end

  private def profiled(program, **options)
    out = StringIO.new
    rom = assemble_rom(program, name: "SHORT")
    [rom.profile(out: out, frames: 8, settle: 4, **options), out.string]
  end

  def test_the_report_says_when_sprites_were_drawn_in_the_wrong_colors
    result, printed = profiled(things_on_screen(20))

    assert_equal 5 * 8, result.colors_short, "five things a frame, over the eight frames measured"
    assert_match(/40 times, a sprite was drawn in the wrong colors/, printed)
  end

  # Within the groups there are to lend, nothing is said — not "0 times".
  def test_a_run_that_had_groups_enough_says_nothing_about_it
    result, printed = profiled(things_on_screen(15))

    assert_equal 0, result.colors_short
    refute_match(/wrong colors/, printed)
  end

  def test_the_same_number_comes_back_as_data
    out = StringIO.new
    assemble_rom(things_on_screen(20), name: "SHORT").profile(format: :json, out: out, frames: 8, settle: 4)

    assert_equal 40, JSON.parse(out.string).fetch("colors_short")
  end

  # A game whose lists all have a group of their own lends nothing and has nothing to count,
  # so the field is empty (null) rather than nought.
  def test_a_game_that_lends_nothing_reports_an_empty_field
    out = StringIO.new
    small = Builder.new
    small.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      sprite :ship, at: [40, 40]
      game_loop { wait_vblank }
    end
    small.finalize_program
    assemble_rom(small.program, name: "FITS").profile(format: :json, out: out, frames: 8, settle: 4)

    json = JSON.parse(out.string)

    assert_includes json, "colors_short"
    assert_nil json["colors_short"]
  end
end
