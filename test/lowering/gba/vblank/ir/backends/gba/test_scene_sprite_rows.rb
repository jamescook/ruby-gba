# frozen_string_literal: true

require "test_helper"
require "differential"

# SPRITES OF SCENES NEVER UP TOGETHER TAKE TURNS AT THE CONSOLE'S ROWS. The console draws its
# sprites from a table of 128 rows, and a row is handed to a sprite while the cartridge is
# built. A title screen's lettering and the room the game is played in are never on screen
# together, so they can be given the same rows — and then a change of scene has to leave
# nothing of the scene that went in rows the next one now writes, not even for a frame.
class TestSceneSpriteRows < Minitest::Test
  include Differential

  RED = VBlank::Graphics::Color.rgb(31, 0, 0)
  GREEN = VBlank::Graphics::Color.rgb(0, 31, 0)

  TITLE_LETTERS = 100
  WALKERS = 60
  SPARKS = 30
  ORDERED = 20

  # A game of two screens with more sprites between them than the console has rows: a title
  # of lettering that never moves, and play, with walkers the game moves and a pool of sparks.
  # The game walks between them on its own: the title until frame 6, play until frame 12, the
  # title again.
  private def two_screens
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :letter, width: 8, height: 8, data: Array.new(64, RED)
      image :walker, width: 8, height: 8, data: Array.new(64, GREEN)
      image :spark, width: 8, height: 8, data: Array.new(64, GREEN)
      t = var :t, 0
      var :where, 0
      scene :title do
        TITLE_LETTERS.times { |i| sprite :letter, at: [(i % 25) * 9, (i / 25) * 9] }
      end
      scene :play do
        WALKERS.times { |i| sprite(:walker, at: [(i % 20) * 11, 60 + ((i / 20) * 11)]).move(:right, by: 1) }
        sparks = pool :spark, x: 0, y: 0, capacity: SPARKS, image: :spark
        (sparks.count < SPARKS).then { sparks.spawn(x: sparks.count * 7, y: 130) }
      end
      game_loop do
        t.add! 1
        (t == 6).then { set! :where, 1 }
        (t == 12).then { set! :where, 0 }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # EVERY FRAME SHOWS ONE SCREEN'S SPRITES AND NOTHING OF THE OTHER'S, through both changes.
  def test_each_frame_shows_one_scenes_sprites_and_none_of_the_others
    v = assert_emulator_loads_rom(assemble_rom(two_screens, name: "ROWS"), frames: 2)
    20.times do |frame|
      letters = v.sprites(:letter).size
      play = v.sprites(:walker).size + v.sprites(:spark).size
      assert letters.zero? || play.zero?, "frame #{frame}: #{letters} letters up beside #{play} of play's sprites"
      assert_includes [0, TITLE_LETTERS], letters, "frame #{frame}: the title shows all its letters or none"
      v.step
    end
  end

  def test_the_console_draws_what_the_oracle_draws_across_both_changes
    [4, 7, 8, 10, 13, 14, 16].each { |f| assert_backends_agree(two_screens, frames: f) }
  end

  # The same two screens with some of play's walkers drawn in an order the game works out, which
  # the console is given by copying a run of rows into the table on each frame. Those keep rows
  # of their own, and the rest of play's still take turns with the title's letters. The letters
  # must come up whole when play goes, and play's walkers when it comes.
  private def two_screens_with_play_in_order
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :letter, width: 8, height: 8, data: Array.new(64, RED)
      image :walker, width: 8, height: 8, data: Array.new(64, GREEN)
      t = var :t, 0
      var :where, 0
      scene :title do
        TITLE_LETTERS.times { |i| sprite :letter, at: [(i % 25) * 9, (i / 25) * 9] }
      end
      scene :play do
        walkers = Array.new(WALKERS) { |i| sprite(:walker, at: [(i % 20) * 11, 60 + ((i / 20) * 11)]) }
        walkers.each { |walker| walker.move(:right, by: 1) }
        draw_in_order(*walkers.last(ORDERED)) # the frontmost, so they stand between no two scenes
      end
      game_loop do
        t.add! 1
        (t == 6).then { set! :where, 1 }
        (t == 12).then { set! :where, 0 }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_scene_drawn_in_order_leaves_the_others_rows_to_them
    v = assert_emulator_loads_rom(assemble_rom(two_screens_with_play_in_order, name: "ROWS"), frames: 2)
    20.times do |frame|
      letters = v.sprites(:letter).size
      walkers = v.sprites(:walker).size
      assert letters.zero? || walkers.zero?, "frame #{frame}: #{letters} letters up beside #{walkers} walkers"
      assert_includes [TITLE_LETTERS, WALKERS], letters + walkers, "frame #{frame}: one screen shows whole"
      v.step
    end
  end
end
