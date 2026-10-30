# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_sprite_off_screen"

# A SPRITE OFF THE SCREEN, ON THE ADVANCE'S CARTRIDGE: what keeping it off costs in code, and
# what the console's own table of sprites says of it, read in the emulator. What the picture
# shows, asked of every run, is in test/all/vblank/builder/test_sprite_off_screen.rb.
class TestSpriteOffScreenCartridge < Minitest::Test
  include SpriteOffScreenGames

  HEIGHT = 160 # the Advance's screen

  # A line of text stands where the program wrote it, so nothing about where it stands is
  # worked out as the game runs and no test is spent on it.
  def test_text_written_on_the_screen_costs_no_test
    lettered = lambda do |y|
      cast_on_floor do
        draw_text "SCORE", 8, y, :white
        game_loop {}
      end
    end
    near = VBlank::IR::Backends::GBA.new.lower(lettered.call(8)).bytesize
    far = VBlank::IR::Backends::GBA.new.lower(lettered.call(300)).bytesize

    assert_operator near, :<, far, "the letters far off are tested, the ones on the screen are not"
  end

  # --- what a test reading the console's table is told ---

  # A sprite that is off the screen is still in the table, which is what tells it from one
  # the game switched off. Where the table can say its place, it says the game's own.
  def test_a_sprite_off_the_screen_is_still_a_row_of_the_consoles_table
    require_emulator!
    rom = VBlank.build("PARKED", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:block, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(16, 16) }
      image(:slab, "#" => :red, "o" => :white) { TestSpriteOffScreen.checks(64, 64) }
      sprite :near, at: [250, 170], facing: { right: :block }
      sprite :far, at: [100, 300], facing: { right: :block }
      sprite :hidden, at: [100, 300], facing: { right: :block }, shown: false
      spun = sprite :spun, at: [100, 300], facing: { right: :slab }
      spun.scale 2.0
      game_loop {}
    end
    reader = assert_emulator_loads_rom(rom, frames: 4)
    near, far, spun = %i[near far spun].map { |name| reader.sprites(name) }

    assert_equal [[250, 170]], near.map { |row| [row.x, row.y] }, "just off the edge, it is where the game put it"
    assert_equal [[100, HEIGHT]], far.map { |row| [row.x, row.y] }, "too far down for the table to say, it reads as the first row below"
    assert_equal [HEIGHT], spun.map(&:y), "and so does a box too tall to stand there turned"
    assert_empty reader.sprites(:hidden), "where one the game hid is not in the table at all"
  end
end
