# frozen_string_literal: true

require "test_helper"

# THE COLOR'S EIGHT LISTS OF SPRITE COLOURS. A game whose sprites wear more lists than eight
# still builds: each list borrows one of the eight as a sprite wearing it is placed
# (test/ruby_gba/dsl/test_sprite_borrowed_colors.rb and test/ruby_gba/builder/test_colors_in_use.rb
# play that on every lowering). What cannot fit is a set given to `colors_in_use` with more than
# eight lists, since a set's lists are shown together; that is refused here, naming the set.
class TestGBCSpriteLists < Minitest::Test
  GBC = RubyGBA::IR::Backends::GBC

  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  def test_a_set_of_more_than_eight_lists_is_refused_naming_the_set
    error = assert_raises(GBC::LoweringError) { GBC.new.build(one_set_of(9)) }

    assert_match(/needs 9 lists of colours at once/, error.message)
    assert_match(/holds 8 lists for sprites/, error.message)
    assert_match(/test_gbc_sprite_lists\.rb:\d+/, error.message)
    assert_match(/give that set 8 lists or fewer/, error.message)
  end

  def test_a_set_of_eight_lists_builds
    assert GBC.new.build(one_set_of(8))
  end

  private

  # A pool of things each wearing one of +count+ lists, all of them in one set, beside a set of one.
  def one_set_of(count)
    names = (0...count).map { |n| :"set#{n}" }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: %i[transparent red green]
      names.each_with_index { |name, n| colors name, [:transparent, Color.rgb(n, 31 - n, 5), Color.rgb(31 - n, n, 9)] }
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: 2, image: :ship
      things.spawn x: 40, y: 40, kind: 0
      game_loop do
        colors_in_use [names.first(1), names], showing: 1
        things.each { |thing| thing.draw_with names, showing: thing.kind }
      end
    end
    builder.finalize_program
    builder.program
  end
end
