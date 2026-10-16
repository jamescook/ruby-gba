# frozen_string_literal: true

require "game_test_helper"

# A test outside the walking group, so a run of the group can be told from a run of the whole.
class MenuTest < Minitest::Test
  def test_stands_for_the_rest_of_the_suite
    note_lowering

    pass
  end
end
