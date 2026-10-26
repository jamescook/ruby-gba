# frozen_string_literal: true

require "test_helper"

# The tests of test_follow_camera.rb that read the Advance's screen as it lays out — the character
# centred on 240 pixels at column 116, a landmark at world column 160 — so they play on the
# Advance's runs alone. A Game Boy Color's screen is 160 pixels across.
class TestFollowCameraOnTheAdvance < Minitest::Test
  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A green world with one blue tile as a landmark you can watch slide by, and a red
  # character in the middle of the screen with the camera locked onto it.
  private def walking_game(&extra)
    program do
      screen :tiled
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:mark, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass, "M" => :mark
      # One blue cell at column 20, row 10 — world pixels 160..167, 80..87.
      map = (0...32).map { |r| (0...32).map { |c| r == 10 && c == 20 ? "M" : "." }.join }
      world = background :world, tiles: :terrain, map: map

      hero = sprite :guy, at: [0, 0]
      hero.center_on_screen
      camera_follows hero, across: world

      game_loop { instance_exec(hero, &extra) if extra }
    end
  end

  # The leftmost column of the character's own colour, on the row through its middle.
  private def hero_left(screen)
    (0...240).find { |x| screen.pixel(x, 80) == RED }
  end

  # The leftmost column of the landmark, or nil once it has slid off. Read on a row the
  # landmark covers wherever the world has been scrolled to, and which the character —
  # pinned at x 116..123 — is never on the same column of.
  private def mark_left(screen)
    (0...240).find { |x| screen.pixel(x, 81) == BLUE }
  end

  # --- the swap: the sprite moves, the world does ---

  def test_the_character_stays_put_while_the_world_slides_under_it
    prog = walking_game { |hero| held(:right).then { hero.move :right, by: 2 } }
    seen = (1..8).map do |n|
      game_player.hold(:right).run(prog, frames: n).screen
    end

    assert_equal [116] * 8, seen.map { |s| hero_left(s) },
                 "the character's picture never leaves its spot, however far it walks"
    scrolled = seen.map { |s| mark_left(s) }
    assert_equal scrolled.sort.reverse, scrolled,
                 "and the scenery slides the other way, every frame"
    assert_operator scrolled.first - scrolled.last, :>=, 12,
                    "eight frames at two pixels really moves the world"
  end

  def test_walking_the_other_way_scrolls_the_other_way
    prog = walking_game { |hero| held(:left).then { hero.move :left, by: 2 } }
    first = game_player.hold(:left).run(prog, frames: 2).screen
    later = game_player.hold(:left).run(prog, frames: 8).screen

    assert_equal 116, hero_left(later), "still planted"
    assert_operator mark_left(later), :>, mark_left(first),
                    "walking left brings the scenery in from the left"
  end

  def test_a_game_that_stands_still_does_not_drift
    prog = walking_game { |hero| hero } # no input, no movement
    early = game_player.run(prog, frames: 2).screen
    late = game_player.run(prog, frames: 30).screen

    assert_equal hero_left(early), hero_left(late), "the character does not wander"
    assert_equal mark_left(early), mark_left(late), "and neither does the world"
  end
end
