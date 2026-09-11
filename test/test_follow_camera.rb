# frozen_string_literal: true

require "test_helper"

# The follow camera — `camera_follows`, which keeps a character where it stands on the
# screen and moves the world under it instead.
#
# The claim to test is a swap: the game moves the SPRITE, and what actually moves is the
# WORLD. So every test here looks at two things at once — that the character's picture
# has not moved on screen, and that the scenery has. Reading only one of them would pass
# for a game where nothing happens at all.
class TestFollowCamera < Minitest::Test
  RED = RubyGBA::Color.resolve(:red)
  BLUE = RubyGBA::Color.resolve(:blue)
  GREEN = RubyGBA::Color.resolve(:green)

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A green world with one blue tile as a landmark you can watch slide by, and a red
  # character in the middle of the screen with the camera locked onto it.
  def walking_game(at: nil, &extra)
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
      camera_follows hero, across: world, at: at

      game_loop { instance_exec(hero, &extra) if extra }
    end
  end

  # The leftmost column of the character's own colour, on the row through its middle.
  def hero_left(screen)
    (0...240).find { |x| screen.pixel(x, 80) == RED }
  end

  # The leftmost column of the landmark, or nil once it has slid off. Read on a row the
  # landmark covers wherever the world has been scrolled to, and which the character —
  # pinned at x 116..123 — is never on the same column of.
  def mark_left(screen)
    (0...240).find { |x| screen.pixel(x, 81) == BLUE }
  end

  # --- the swap: the sprite moves, the world does ---

  def test_the_character_stays_put_while_the_world_slides_under_it
    prog = walking_game { |hero| held(:right).then { hero.move :right, by: 2 } }
    seen = (1..8).map do |n|
      Reference.new.hold(:right).run(prog, frames: n).screen
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
    first = Reference.new.hold(:left).run(prog, frames: 2).screen
    later = Reference.new.hold(:left).run(prog, frames: 8).screen

    assert_equal 116, hero_left(later), "still planted"
    assert_operator mark_left(later), :>, mark_left(first),
                    "walking left brings the scenery in from the left"
  end

  def test_a_game_that_stands_still_does_not_drift
    prog = walking_game { |hero| hero } # no input, no movement
    early = Reference.new.run(prog, frames: 2).screen
    late = Reference.new.run(prog, frames: 30).screen

    assert_equal hero_left(early), hero_left(late), "the character does not wander"
    assert_equal mark_left(early), mark_left(late), "and neither does the world"
  end

  # --- where the character starts in the world ---

  # The sprite's own position says where it sits on the SCREEN, which under a follow
  # camera is a different question from where it stands in the world. `at:` answers the
  # second one, and this is the test that they really are different: two games whose
  # sprites sit in the same place show different parts of the world.
  def test_at_says_where_in_the_world_the_character_starts
    here = Reference.new.run(walking_game(at: [120, 80]), frames: 2).screen
    there = Reference.new.run(walking_game(at: [140, 80]), frames: 2).screen

    assert_equal hero_left(here), hero_left(there), "the character sits in the same spot either way"
    assert_equal mark_left(here) - 20, mark_left(there),
                 "but starting twenty pixels into the world shows the scenery twenty pixels along"
  end

  # --- what the swap is FOR: the character is an ordinary sprite ---

  # The point of following is that the hero can be moved with the same verbs as any other
  # sprite, rather than being a pair of world-position variables the game keeps by hand.
  # Facing is the visible proof: `move` picks the pose, and the camera follows anyway.
  def test_the_character_still_faces_the_way_it_moves
    prog = program do
      screen :tiled
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:l, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:r, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass
      world = background :world, tiles: :terrain, map: (0...32).map { "." * 32 }

      hero = sprite :l, at: [0, 0], facing: { left: :l, right: :r }
      hero.center_on_screen
      camera_follows hero, across: world

      game_loop do
        held(:right).then { hero.move :right, by: 2 }
        held(:left).then { hero.move :left, by: 2 }
      end
    end

    going_right = Reference.new.hold(:right).run(prog, frames: 4).screen
    going_left = Reference.new.hold(:left).run(prog, frames: 4).screen

    assert_equal RED, going_right.pixel(120, 80), "moving right swapped to the right-facing pose"
    assert_equal BLUE, going_left.pixel(120, 80), "and moving left to the left-facing one"
  end

  # --- centring, which is what kills the coordinate literals ---

  def test_center_on_screen_uses_the_sprites_own_size
    prog = program do
      screen :tiled
      image(:big, "#" => :red) { (["#" * 16] * 16).join("\n") }
      sprite(:big, at: [0, 0]).center_on_screen
      game_loop {}
    end
    screen = Reference.new.run(prog, frames: 2).screen

    left = (0...240).find { |x| screen.pixel(x, 80) == RED }
    right = (0...240).reverse_each.find { |x| screen.pixel(x, 80) == RED }
    assert_equal 240 - 1 - right, left, "a 16-wide sprite has equal margins either side"
    assert_equal 112, left, "which for this one is x 112..127"
  end

  # --- friendly errors ---

  def test_following_on_a_bitmap_screen_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      program do
        screen :bitmap
        image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
        camera_follows sprite(:guy, at: [0, 0]), across: :nothing
      end
    end
    assert_match(/screen :tiled/, error.message)
  end

  def test_following_something_that_is_not_a_background_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
        camera_follows sprite(:guy, at: [0, 0]), across: :world
      end
    end
    assert_match(/background/, error.message)
  end

  def test_a_nonsense_starting_place_is_a_friendly_error
    error = assert_raises(ArgumentError) { walking_game(at: 120) }
    assert_match(/at: \[120, 80\]/, error.message)
  end

  # One camera can follow one character. Two would fight over the same world every frame,
  # each undoing the other, which looks like a bug in the framework rather than in the game.
  def test_following_a_second_character_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
        image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
        tiles :terrain, "." => :grass
        world = background :world, tiles: :terrain, map: (0...32).map { "." * 32 }
        camera_follows sprite(:guy, at: [10, 10]), across: world
        camera_follows sprite(:guy, at: [50, 50]), across: world
      end
    end
    assert_match(/one character/, error.message)
  end

  # --- guardrail ---

  def warnings(prog)
    RubyGBA::IR::Guardrails::Validator.new.run(prog, autofix: false).warnings.map(&:check)
  end

  def test_a_follow_camera_with_no_game_loop_is_caught
    prog = program do
      screen :tiled
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass
      world = background :world, tiles: :terrain, map: (0...32).map { "." * 32 }
      camera_follows sprite(:guy, at: [10, 10]), across: world
      halt
    end

    assert_includes warnings(prog), :follow_camera_needs_game_loop
  end

  def test_a_follow_camera_inside_a_game_loop_is_not_flagged
    refute_includes warnings(walking_game), :follow_camera_needs_game_loop
  end

  # --- and on the console ---

  def test_the_world_scrolls_under_a_planted_character_on_the_console
    prog = walking_game { |hero| held(:right).then { hero.move :right, by: 2 } }
    rom = RubyGBA::ROM.assemble(GBA.new.lower(prog), title: "FOLLOW", code: "BFLW", maker: "01")

    at_rest = assert_emulator_loads_rom(rom, frames: 4)
    walked = assert_emulator_loads_rom(rom, frames: 30, keys: RubyGBA::Constants::KEY_RIGHT)

    assert at_rest.red?(120, 80), "the character renders in the middle of the screen"
    assert walked.red?(120, 80), "and is still there after walking — the console moved the world"
  end
end
