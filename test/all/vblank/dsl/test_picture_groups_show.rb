# frozen_string_literal: true

require "test_helper"

# WHAT `show` ON A SET OF PICTURE GROUPS REFUSES. It takes the numbers of the groups up from now
# on, and the build stops at a call that cannot mean anything: more groups than up_together: lets
# be up at once, none at all, or a number with a fraction, which names some other group.
class TestPictureGroupsShow < Minitest::Test
  private def refused(&block)
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :tiled
        image(:red_box, "#" => :red) { Array.new(8) { "#" * 8 }.join("\n") }
        image(:blue_box, "#" => :blue) { Array.new(8) { "#" * 8 }.join("\n") }
        rooms = picture_groups :rooms, { 0 => %i[red_box], 1 => %i[blue_box] }, up_together: [[0, 1]]
        game_loop { instance_exec(rooms, &block) }
      end
      b.finalize_program
    end
    error.message
  end

  def test_more_groups_than_can_be_up_together_are_refused
    message = refused { |rooms| rooms.show 0, 1, 0 }

    assert_match(/three groups/, message)
    assert_match(/two groups/, message)
  end

  def test_no_group_at_all_is_refused
    assert_match(/no group/, refused { |rooms| rooms.show })
  end

  def test_a_number_with_a_fraction_is_refused
    message = refused do |rooms|
      room = var :room, 0.5
      rooms.show room
    end

    assert_match(/fraction/, message)
    assert_match(/to_i/, message)
  end
end
