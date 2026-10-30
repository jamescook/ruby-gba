# frozen_string_literal: true

require "test_helper"

# The test of test_image_import.rb whose game paints more colours into one 8×8 square of the
# screen than a Game Boy Color's square holds — a red, green, blue and white photo over black — so it
# plays on the Advance's runs alone.
class TestImageImportOnTheAdvance < Minitest::Test
  FIXTURES = VBlank.root.join("test/fixtures").to_s
  # The 2x2 fixture is red / green / blue / white, row-major (top-left first).
  TWO_BY_TWO = File.join(FIXTURES, "import_2x2.png")
  EXPECTED   = [0x001F, 0x03E0, 0x7C00, 0x7FFF].freeze # red, green, blue, white

  private def photo_program(x, y)
    fixture = TWO_BY_TWO
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      image :photo, from: fixture, width: 2, height: 2 # imported and embedded
      blit :photo, x, y
      halt
    end
    builder.finalize_program
    builder.program
  end

  def test_imported_image_embeds_and_blits_on_the_interpreter
    screen = game_player.run(photo_program(10, 20)).screen

    assert_equal EXPECTED[0], screen.pixel(10, 20), "top-left red"
    assert_equal EXPECTED[1], screen.pixel(11, 20), "top-right green"
    assert_equal EXPECTED[2], screen.pixel(10, 21), "bottom-left blue"
    assert_equal EXPECTED[3], screen.pixel(11, 21), "bottom-right white"
  end
end
