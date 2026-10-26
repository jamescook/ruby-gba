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

  # WHAT A MOMENT CAN ASK OF A COLOR GAME: the sprites it drew, by the names the game gave them
  # and where the game put them; the colours the Color draws from, in its own lists of four;
  # and how many times round the game loop it got, which is the count of ticks.
  def test_a_moment_asks_a_color_game_for_its_sprites_colours_and_passes
    looked = {}
    RubyGBA.playthrough "walk and look" do
      wait frames: 10
      hold :right, frames: 20
      wait frames: 5
      moment :looked
    end.play(color_cartridge) do |_, game|
      looked[:sprites] = game.sprites(:block).map { |row| [row.name, row.x, row.y] }
      looked[:everything] = game.sprites.map(&:name)
      looked[:palette] = game.palette
      looked[:sprite_colours] = game.palette(:sprites)
      looked[:one_list] = game.palette(:sprites, 0)
      looked[:passes] = game.passes
      looked[:ticks] = game.var(:ticks)
    end

    assert_equal [[:block, 40, 60]], looked[:sprites]
    assert_equal [:block], looked[:everything]
    assert_equal 64, looked[:palette].size, "eight lists of four for the backgrounds, eight for the sprites"
    assert_equal 32, looked[:sprite_colours].size
    assert_includes looked[:sprite_colours], Color.resolve(:white), "the block is white"
    assert_equal looked[:sprite_colours].first(4), looked[:one_list]
    assert_equal looked[:ticks], looked[:passes]
  end

  # WHILE THE BLOCK WALKS, the sprite stands where the last pass put it, two pixels behind the
  # number the pass that is still to be shown has counted to — as on the Advance, and as the
  # interpreter says it.
  def test_a_walking_sprite_stands_where_the_last_pass_put_it
    seen = nil
    RubyGBA.playthrough "walk" do
      wait frames: 10
      hold :right, frames: 10
      moment :walking
      hold :right, frames: 5
    end.play(color_cartridge) { |_, game| seen = [game.sprites(:block).first.x, game.var(:x)] }

    sprite_x, counted = seen
    assert_equal counted - 2, sprite_x
  end

  # The count of passes is the Color runtime's count of waits for the screen, which is one a pass
  # only for a game loop that waits for it once, at its top. A game that waits anywhere else is
  # refused the count in plain words rather than given a wrong one.
  def test_passes_is_refused_for_a_game_that_waits_for_the_screen_itself
    manual = RubyGBA.game("WAITS", consoles: %i[gba gbc], frame_sync: :manual) do
      ticks = var :ticks, 0
      game_loop do
        ticks.add! 1
        wait_vblank
      end
    end
    game = RubyGBA::Playthroughs::Playthrough.power_on(manual.build_rom(console: :gbc, out: nil, err: nil, profile: false))
    game.step(20)
    error = assert_raises(ArgumentError) { game.passes }

    assert_match(/waits for the screen/, error.message)
    assert_match(/Game Boy Color/, error.message)
  end

  # Out of the Color's eight lists, a list number that is not one is refused, not answered with
  # another list's colours or with nothing.
  def test_palette_refuses_a_list_the_color_does_not_have
    game = color_game_now

    assert_match(/8 groups of 4/, assert_raises(ArgumentError) { game.palette(:sprites, 8) }.message)
    assert_match(/numbered 0 to 7/, assert_raises(ArgumentError) { game.palette(:sprites, -1) }.message)
  end

  # What only an Advance's reader can say — the processor's registers, the wave voice's pitch,
  # where its routines start, how often the game read the pad, and the mixer of recordings a Color
  # game cannot have — is not a Color reader's question at all, and asking it anyway is refused by
  # name, never answered wrong or with a backtrace from inside. The layers and the sound channels
  # are the Color's own, and are answered.
  def test_a_moment_is_refused_what_only_an_advance_answers
    refusals = {}
    answers = {}
    RubyGBA.playthrough("look") { wait frames: 20; moment :still }.play(color_cartridge) do |_, game|
      %i[registers wave_rate pad_reads voices sounding sample_clock sound_drops].each do |question|
        refusals[question] = assert_raises(NoMethodError) { game.public_send(question) }.message
      end
      refusals[:run_until] = assert_raises(NoMethodError) { game.run_until(:game) }.message
      answers[:layers] = game.layers
      answers[:alone] = game.showing(only: :sprites) { game.step.only_color }
    end

    refusals.each do |question, words|
      assert_match(/Game Boy Color/, words, question)
      assert_match(/`#{question}`/, words, question)
    end
    assert_includes answers[:layers], :sprites
    assert_nil answers[:alone], "the block is drawn on an empty screen, so the picture is not one colour"
    assert_match(/no sprite :nobody/, assert_raises(ArgumentError) { color_game_now.sprites(:nobody) }.message)
  end

  private def color_game_now
    game = RubyGBA::Playthroughs::Playthrough.power_on(color_cartridge)
    game.step(20)
    game
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
