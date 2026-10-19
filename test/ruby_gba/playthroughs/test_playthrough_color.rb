# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "png_reading"

# A PLAYTHROUGH ON A GAME BOY COLOR CARTRIDGE: the same script, played the same way, on the
# cartridge a game built for the Color too makes. What a script says is in frames and buttons,
# and both consoles have both, so nothing about the script changes.
class TestPlaythroughColor < Minitest::Test
  include PNGReading

  # The counting game of test_playthrough.rb, for both consoles: one more tick each frame, and
  # a block two pixels across each frame RIGHT is down.
  COUNTING = RubyGBA.game("COUNTING", consoles: %i[gba gbc]) do
    screen :tiled
    image(:block, "#" => :white) { "########\n" * 8 }
    ticks = var :ticks, 0
    x = var :x, 0
    block = sprite :block, at: [x, 60]
    game_loop do
      ticks.add! 1
      held(:right).then { x.add! 2 }
      block.move_to x, 60
    end
  end

  private def color_cartridge = COUNTING.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)

  # RIGHT is down for 20 frames at two pixels a frame, so the game has gone 40 pixels once the
  # hold is over, and the moment falls on the frame the hold ends.
  def test_a_script_plays_on_a_color_cartridge
    walk = RubyGBA.playthrough "walk right" do
      wait frames: 10
      hold :right, frames: 20
      moment :walked
      wait frames: 5
    end
    seen = {}
    played = walk.play(color_cartridge) { |name, game| seen[name] = game.var(:ticks) }

    assert_equal 35, played.frames
    assert_equal({ walked: 30 }, played.moments)
    assert_operator seen.fetch(:walked), :>, 0, "the game was running at the moment"
    assert_equal 40, played.game.var(:x)
  end

  # The tape of the playing names the cartridge it was recorded on by the title in the Color's
  # own header, which is not where the Advance keeps one.
  def test_the_tape_names_the_color_cartridge_by_its_title
    played = RubyGBA.playthrough("wait") { wait frames: 3 }.play(color_cartridge)

    assert_equal "COUNTING", played.tape.title
  end

  # The picture at a moment is the Color's whole screen, 160 by 144, with the block where the
  # game drew it: at the left edge, 60 rows down, and nothing like it far from there. The Color
  # takes some frames to set the game up before it shows one, so the moment waits past them.
  def test_the_picture_at_a_moment_is_the_color_screen
    Dir.mktmpdir do |dir|
      RubyGBA.playthrough("look") { wait frames: 20; moment :still }.play(color_cartridge, pictures_in: dir)
      png = File.binread(File.join(dir, "still.png"))

      assert_equal [160, 144], png_size(png)
      assert_equal png_pixel(png, 2, 62), png_pixel(png, 5, 66), "the block is one colour"
      refute_equal png_pixel(png, 2, 62), png_pixel(png, 100, 100), "the block stands out from the screen"
    end
  end

  # A comparison lines two screens up as the Advance's, so two Color cartridges are refused in
  # plain words rather than compared wrong.
  def test_a_comparison_refuses_a_color_cartridge
    error = assert_raises(ArgumentError) do
      RubyGBA.playthrough("wait") { wait frames: 3 }.compare(color_cartridge, color_cartridge)
    end

    assert_match(/Game Boy Color/, error.message)
  end
end
