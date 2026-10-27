# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../../tools/make_menu_font"

# tools/make_menu_font.rb draws the menu's letters into the file the library ships. The file is
# what it would draw now: a change to the letters kept, the size or the font that was not drawn
# again fails here. A machine without SDL3_ttf, which only this tool needs, skips it.
class TestMakeMenuFont < Minitest::Test
  # Fiddle calls into C from the main Ractor only.
  runs_on_the_main_ractor!

  def test_the_shipped_letters_are_what_the_tool_draws_now
    begin
      MakeMenuFont.ttf
    rescue RuntimeError => e
      skip e.message
    end
    MakeMenuFont.ttf.TTF_Init
    shipped = JSON.parse(File.read(MakeMenuFont::OUT))

    assert_equal MakeMenuFont::LETTERS.join, shipped.fetch("letters")
    MakeMenuFont::DENSITIES.each do |density|
      assert_equal shipped.fetch("densities").fetch(density.to_s), MakeMenuFont.at_density(density),
                   "the letters at #{density}x differ from the tool's; run ruby tools/make_menu_font.rb"
    end
  end
end
