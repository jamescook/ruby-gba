# frozen_string_literal: true

require "test_helper"

require "stringio"
require_relative "../../examples/hero"

# The Hero example (examples/hero.rb): a follow-you camera — a hardware sprite
# pinned to the center of the screen while a world bigger than the screen scrolls
# under it as you walk — and three save files to keep a walk in. Proves the features
# compose: the hero composites over the moving background, stays centered no matter how
# far you walk, the world really slides (a pond landmark moves out from under its resting
# spot), and a walk saved to a file comes back where it was left after the power goes
# off. Asserted on the interpreter oracle and on real hardware. The player never touches
# object memory, tile numbers, a scroll register or save memory.
class TestHeroExample < Minitest::Test
  include RubyGBA::Console::Hardware

  CENTER = [120, 80].freeze # the middle of the screen, where the hero's body always sits

  # The game opens on its file screen. A on the first frame picks FILE 1, whose menu opens
  # on NEW GAME since the file is empty; A on the third starts the game, and the walk begins
  # on the frame after.
  STARTED = 4

  # True if any pixel in the box reads blue, by whatever "is it blue here?" test the
  # caller supplies (interpreter framebuffer or the emulator). Scanning a box (not one pixel)
  # keeps the "did the pond move?" checks robust to a frame of hardware timing slack.
  def blue_in?(xs, ys)
    xs.any? { |x| ys.any? { |y| yield(x, y) } }
  end

  # Start a new game, then play +frames+ more, holding what the block gives for each frame
  # of the walk (counted from 1).
  def play(frames:, store: {}, &walk)
    Reference.new(save: store)
             .input_each_frame { |f| [1, 3].include?(f) ? [:a] : Array(f >= STARTED ? walk&.call(f - 3) : nil) }
             .run(Hero.program, frames: frames + STARTED)
  end

  # Power the console on again with the same save memory and press what +presses+ says, by
  # frame from power-on.
  def power_on(store, frames:, presses: {})
    Reference.new(save: store).input_each_frame { |f| Array(presses[f]) }.run(Hero.program, frames: frames)
  end

  def test_the_example_builds_clean
    rom = Hero.build_rom(err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # At rest the camera sits at scroll (4, 4), so the pond (world px 80..) shows just
  # up-left of the centered hero. Walk right for 30 frames and the camera follows to
  # scroll (64, 4): the hero is STILL dead center, and the pond has slid ~60px left —
  # out of its old spot and onto the hero's left. The world moved, not the hero.
  def test_the_hero_stays_centered_while_the_world_scrolls
    blue = Color.resolve(:blue)
    red  = Color.resolve(:red)

    rest = play(frames: 2).screen
    assert_equal red,  rest.pixel(*CENTER), "the hero sits centered on screen"
    assert_equal blue, rest.pixel(78, 78),  "at rest the pond landmark is just up-left of the hero"

    walked = play(frames: 32) { |f| f <= 30 ? :right : nil }.screen
    assert_equal red,     walked.pixel(*CENTER), "the hero is STILL centered after walking — the world moved, not the hero"
    assert_equal blue,    walked.pixel(18, 78),  "the pond has slid left with the scrolling world"
    refute_equal blue,    walked.pixel(78, 78),  "and it left its old spot behind (no smear)"
  end

  # --- The weather: mist that thickens as you walk north ---
  #
  # Two things at once, and the second is what makes the first mean anything. The mist is
  # a background declared IN FRONT of the hero, so it washes out the hero as well as the
  # world — the one arrangement a picture cannot fall into by accident. And how see-
  # through it is, is not a number in the program: it is `100 - mist`, worked out afresh
  # every frame from how far north the player has walked.

  # Walk one way for a while, then read the pixel the hero's body sits on.
  def after_walking(direction, frames)
    play(frames: frames + 1) { |f| f <= frames ? direction : nil }.screen.pixel(*CENTER)
  end

  # Mixing red toward white raises every channel, so a whiter pixel is a bigger number —
  # which makes "thicker than" something the test can say without naming a blend.
  def test_walking_north_draws_the_mist_over_the_hero
    assert_equal Color.resolve(:red), after_walking(:right, 12), "walking east, the air stays clear"

    a_little = after_walking(:up, 6)
    a_lot = after_walking(:up, 24)

    assert_operator a_little, :>, Color.resolve(:red), "walking north left the hero unmisted"
    assert_operator a_lot, :>, a_little, "the mist stopped thickening as the hero walked on"
  end

  # ...and it thins again on the way back, which is what says the amount is read every
  # frame rather than set once when something happened.
  def test_walking_south_again_clears_the_mist
    there_and_back = play(frames: 55) { |f| f <= 24 ? :up : :down }.screen

    assert_equal Color.resolve(:red), there_and_back.pixel(*CENTER),
                 "the mist never cleared on the walk back south"
  end

  # --- The save files ---

  # The game opens on its file screen: the hero is not out yet, and no file holds a walk.
  def test_the_game_opens_on_its_file_screen
    run = power_on({}, frames: 3)

    refute_equal Color.resolve(:red), run.screen.pixel(*CENTER), "the hero waits for a game to start"
    assert_equal [0, 0, 0], (0..2).map { |n| run[:"shown#{n}"] }
  end

  # Walk right, save with START, and turn the console off. On again, the file screen shows
  # how far that walk went; picking the file opens its menu on CONTINUE, which puts the hero back exactly
  # where the save left them — the whole of the world around them drawn the same.
  def test_a_saved_walk_continues_where_it_was_saved
    store = {}
    saved = play(frames: 40, store: store) { |f| { 21 => :start }.fetch(f) { f <= 20 ? :right : nil } }

    back = power_on(store, frames: 3)
    assert_equal 20, back[:shown0], "the file screen reads the walk from the save without loading it"

    continued = power_on(store, frames: 8, presses: { 1 => :a, 3 => :a })
    assert_equal [saved[:px], saved[:py], saved[:steps]], [continued[:px], continued[:py], continued[:steps]]
    # Both are the walk itself, the hero out in the world, and not the file screen: two file
    # screens would compare equal too.
    [saved, continued].each { |run| assert_equal Color.resolve(:red), run.screen.pixel(*CENTER) }
    (60..100).each do |y|
      assert_equal (0...240).map { |x| saved.screen.pixel(x, y) }, (0...240).map { |x| continued.screen.pixel(x, y) },
                   "row #{y} of the world is drawn where the save left it"
    end
  end

  # Walking without saving is lost when the console goes off.
  def test_a_walk_that_was_not_saved_is_not_kept
    store = {}
    play(frames: 25, store: store) { |f| f <= 20 ? :right : nil }

    assert_equal 0, power_on(store, frames: 3)[:shown0]
  end

  # ERASE, three rows down from CONTINUE in the file's menu, empties the file; the
  # next power-on finds it empty.
  def test_erase_empties_the_file
    store = {}
    play(frames: 25, store: store) { |f| { 21 => :start }.fetch(f) { f <= 20 ? :right : nil } }
    power_on(store, frames: 12, presses: { 1 => :a, 3 => :down, 5 => :down, 7 => :down, 9 => :a })

    assert_equal 0, power_on(store, frames: 3)[:shown0]
  end

  # COPY TO NEXT puts file 1's walk in file 2 as well.
  def test_copy_puts_the_walk_in_the_next_file
    store = {}
    play(frames: 25, store: store) { |f| { 21 => :start }.fetch(f) { f <= 20 ? :right : nil } }
    power_on(store, frames: 10, presses: { 1 => :a, 3 => :down, 5 => :down, 7 => :a })

    back = power_on(store, frames: 3)
    assert_equal [20, 20, 0], (0..2).map { |n| back[:"shown#{n}"] }
  end

  # The console: a new game, a walk, START to save, SELECT back to the file screen, and
  # CONTINUE — to the same place the interpreter's hero reaches with the same presses.
  def test_the_console_saves_and_continues_the_same_walk
    presses = { 4 => :a, 6 => :a, 30 => :start, 34 => :select, 38 => :a, 42 => :a }
    walk = ->(f) { presses.fetch(f) { f.between?(8, 24) ? :right : nil } }
    oracle = Reference.new.input_each_frame { |f| Array(walk.call(f)) }.run(Hero.program, frames: 50)

    keys = { a: KEY_A, start: KEY_START, select: KEY_SELECT, up: KEY_UP, right: KEY_RIGHT }
    rom = Hero.build_rom(err: StringIO.new, profile: false)
    v = assert_emulator_loads_rom(rom, frames: 56, keys: ->(f) { keys.fetch(walk.call(f), 0) }, vars: rom.var_addresses)

    %i[px py steps].each { |name| assert_equal oracle[name], v.var(name), name.to_s }
    assert v.red?(*CENTER), "the hero is back on screen after continuing"
  end

  # --- Hardware (the emulator): the follow-cam really renders and scrolls ---

  # The console opens on the file screen too, so every run below picks FILE 1 and NEW GAME first.
  NEW_GAME = ->(keys) { ->(f) { f.between?(3, 4) || f.between?(7, 8) ? KEY_A : (f > 10 ? keys.call(f - 10) : 0) } }

  def test_the_follow_cam_renders_on_the_console
    v = assert_emulator_loads_rom(Hero.build_rom(err: StringIO.new), frames: 16, keys: NEW_GAME.call(->(_) { 0 }))
    assert v.red?(*CENTER),
           "the hero renders centered on hardware, got 0x#{format('%04X', v.pixel_gba(*CENTER))}"
    assert blue_in?(70..105, 72..92) { |x, y| v.blue?(x, y) },
           "the pond renders near the hero at rest"
  end

  # The console draws the mist over the hero too, and works the amount out as it goes.
  def test_the_mist_thickens_over_the_hero_on_the_console
    rom = Hero.build_rom(err: StringIO.new)
    clear = assert_emulator_loads_rom(rom, frames: 40, keys: NEW_GAME.call(->(_) { 0 })).pixel_gba(*CENTER)
    misted = assert_emulator_loads_rom(rom, frames: 40, keys: NEW_GAME.call(->(_) { KEY_UP })).pixel_gba(*CENTER)

    assert_equal Color.resolve(:red), clear, "the air is clear until the hero walks north"
    assert_operator misted, :>, clear,
                    "the console left the hero unmisted, got 0x#{format('%04X', misted)}"
  end

  def test_the_world_scrolls_under_the_hero_on_the_console
    v = assert_emulator_loads_rom(Hero.build_rom(err: StringIO.new), frames: 55,
                                                                     keys: NEW_GAME.call(->(f) { f <= 30 ? KEY_RIGHT : 0 }))
    assert v.red?(*CENTER),
           "the hero is still centered after walking, got 0x#{format('%04X', v.pixel_gba(*CENTER))}"
    assert blue_in?(8..46, 72..92) { |x, y| v.blue?(x, y) },
           "the pond has scrolled to the hero's left as the world moved under it"
    refute blue_in?(70..105, 72..92) { |x, y| v.blue?(x, y) },
           "the pond has left its resting spot — the world really scrolled"
  end
end
