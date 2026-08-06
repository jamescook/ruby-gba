# frozen_string_literal: true

require "test_helper"

require "stringio"
require_relative "../examples/shmup"

# The Shmup example: a whole game split across files — examples/shmup/player.rb,
# enemies.rb, hud.rb — each a plain Ruby object that takes the build and calls the DSL
# verbs on it, wired into two scenes (PLAYING and a GAME OVER screen). This proves the
# multi-file pattern and real scenes end to end: the parts declare their own sprites and
# HUD inside the playing scene (so they vanish on the game-over screen), collaborate (an
# enemy touching the ship calls the HUD's hit), and losing the last ship switches scenes —
# on the interpreter oracle and on real hardware.
class TestShmupExample < Minitest::Test

  CYAN = Color.resolve(:cyan)   # the ship (player.rb)
  RED = Color.resolve(:red)     # an enemy (enemies.rb) / the GAME OVER banner
  WHITE = Color.resolve(:white) # the HUD text (hud.rb)

  PLAYING = Shmup::PLAYING
  GAME_OVER = Shmup::GAME_OVER

  RENDER = 3_000    # enough frames to draw the opening screen
  MOVE = 6_000      # enough for the ship to walk to a screen edge
  TO_GAME_OVER = 70_000 # enough, at rest, to lose all three ships (~356 frames)

  def red_somewhere?(screen)
    (0...160).any? { |y| (0...240).any? { |x| screen.pixel(x, y) == RED } }
  end

  def red_in?(screen, x, y, w, h)
    (y...y + h).any? { |py| (x...x + w).any? { |px| screen.pixel(px, py) == RED } }
  end

  def test_the_example_builds_clean
    rom = Shmup.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0, "the split-across-files game still builds one ROM"
  end

  # Each file's part draws while playing: the ship, the HUD, and the enemies all appear.
  def test_every_part_renders_on_the_interpreter
    s = Reference.new.run(Shmup.program, max_steps: RENDER).screen
    assert_equal CYAN, s.pixel(119, 132), "the ship (player.rb) renders"
    assert_equal WHITE, s.pixel(9, 4), "the HUD SCORE text (hud.rb) renders"
    assert red_somewhere?(s), "an enemy (enemies.rb) renders"
  end

  # Player#update runs its input logic from its own file: holding right walks the ship
  # to the right edge, where at rest it never is.
  def test_holding_right_drives_the_ship_from_its_own_file
    still = Reference.new.run(Shmup.program, max_steps: MOVE).screen
    right = Reference.new.hold(:right).run(Shmup.program, max_steps: MOVE).screen
    refute_equal CYAN, still.pixel(231, 133), "at rest the ship isn't at the right edge"
    assert_equal CYAN, right.pixel(231, 133), "holding right, the ship moved there"
  end

  # The parts collaborate across files: an enemy that drifts into the ship calls the
  # HUD's `hit`, so a life is lost. (Per-pixel collision, between two files' sprites.)
  def test_parts_collaborate_across_files
    i = Reference.new.run(Shmup.program, max_steps: MOVE)
    assert_operator i[:lives], :<, 3, "an enemy reached the ship — enemies.rb called hud.hit"
  end

  # Losing the last ship switches to the game-over scene: the gameplay sprites and HUD
  # stop being presented (they belong to the playing scene) and the GAME OVER banner —
  # which belongs to the game-over scene — appears. No per-draw visibility flag anywhere.
  def test_losing_every_ship_shows_the_game_over_screen
    i = Reference.new.run(Shmup.program, max_steps: TO_GAME_OVER)
    assert_equal GAME_OVER, i[:state], "the last ship lost switched to the game-over scene"
    assert_equal 0, i[:lives]

    s = i.screen
    assert red_in?(s, 88, 64, 66, 18), "the GAME OVER banner shows on the game-over screen"
    refute_equal CYAN, s.pixel(119, 132), "the ship is gone on the game-over screen"
    refute_equal WHITE, s.pixel(9, 4), "the playing HUD is gone on the game-over screen"
  end

  # START on the game-over screen begins a fresh game — full ships again. (A brief START
  # tap every 40 frames: ignored while playing, and the first tap after game over restarts.)
  def test_start_restarts_a_fresh_game_after_game_over
    saw_game_over = false
    restored = false
    i = Reference.new.input_each_frame { |f| (f % 40).zero? && !f.zero? ? [:start] : [] }
    i.each_vblank do |_f|
      saw_game_over = true if i[:state] == GAME_OVER
      restored = true if saw_game_over && i[:lives] == 3 # ships back to full after game over
    end
    i.run(Shmup.program, max_steps: TO_GAME_OVER)
    assert saw_game_over, "the game reached the game-over screen"
    assert restored, "a START tap restarted a fresh game — the ships came back"
  end

  # The whole thing runs on the console: the ship and HUD while playing.
  def test_it_renders_on_the_console
    v = assert_gemba_loads_rom(Shmup.build_rom(out: StringIO.new, err: StringIO.new), frames: 3)
    assert v.pixel_is?(119, 132, :cyan), "the ship, got 0x#{format('%04X', v.pixel_gba(119, 132))}"
    assert v.white?(9, 4), "the HUD text, got 0x#{format('%04X', v.pixel_gba(9, 4))}"
  end

  # And the game-over screen renders on the console: run long enough (at rest) to lose all
  # three ships, and the GAME OVER banner is on screen — scene-switched presentation, live
  # on hardware.
  def test_the_game_over_screen_renders_on_the_console
    v = assert_gemba_loads_rom(Shmup.build_rom(out: StringIO.new, err: StringIO.new), frames: 380)
    assert v.pixel_is?(94, 68, :red), "the GAME OVER banner, got 0x#{format('%04X', v.pixel_gba(94, 68))}"
    refute v.pixel_is?(119, 132, :cyan), "the ship is gone on the game-over screen"
  end
end
