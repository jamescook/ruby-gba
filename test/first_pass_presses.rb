# frozen_string_literal: true

# PRESSES COUNTED FROM THE GAME'S FIRST PASS, for a test whose game sets up save records before
# it listens. Setting up counts frames too, and a console slower than the Advance can spend
# several placing its save records before its first pass, so a press numbered from power-on
# would fall before the game was listening. Shared by test/all/vblank/builder/test_save_data.rb and
# test/all/vblank/ir/backends/reference/test_save_into.rb.
module FirstPassPresses
  # The buttons of +pressing+ (a frame's number => buttons) counted from the first frame the game
  # reads its buttons on, rather than from power-on: a block for `input_each_frame`.
  private def presses_from_first_pass(pressing)
    first = nil
    lambda do |frame|
      first ||= frame
      Array(pressing[frame - first + 1])
    end
  end
end
