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
  runs_on :reference

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

  # --- Driving the game ---
  #
  # The tests that run on the console bring the game to a place with a script (see
  # `console_after`, below): what to press, said the way a person would say it. The ones
  # that run on the interpreter, here, still say which button is down on which frame. That
  # is not a choice between two styles: a script plays in the emulator and does not play
  # on the interpreter yet, so these keep their own input until it does.

  # Start a new game, then play +frames+ more, holding what the block gives for each frame
  # of the walk (counted from 1).
  def play(frames:, store: SaveImage.new, &walk)
    Reference.new(save: store)
             .input_each_frame { |f| [1, 3].include?(f) ? [:a] : Array(f >= STARTED ? walk&.call(f - 3) : nil) }
             .run(Hero.program, frames: frames + STARTED)
  end

  # Power the console on again with the same save memory and press what +presses+ says, by
  # frame from power-on.
  def power_on(store, frames:, presses: {})
    Reference.new(save: store).input_each_frame { |f| Array(presses[f]) }.run(Hero.program, frames: frames)
  end

  # THE WAY INTO THE GAME ON THE CONSOLE, as a lead-in every console test here starts with:
  # the game opens on its file screen, A picks FILE 1, whose menu opens on NEW GAME since
  # the file is empty, and A again starts the game. Nothing in it is counted, so each
  # test's own script begins with the hero standing in the world.
  def new_game_lead_in
    RubyGBA.playthrough "hero: a new game" do
      wait frames: 10
      press :a
      wait frames: 4
      press :a
      wait frames: 4
    end
  end

  # THE CARTRIDGE AS IT SHIPS, built the way `ruby examples/hero.rb` builds it: measured, and
  # its code placed by what the measuring found. The tests that say the game really renders
  # on the console run this one, since it is the one a player gets.
  def shipped_hero = Hero.build_rom(err: StringIO.new)

  # The same game built without the measuring, which is quicker and is the same game: for
  # the tests that are about what the game does and not about how it was laid out.
  def unmeasured_hero = Hero.build_rom(err: StringIO.new, profile: false)

  # The running cartridge after +steps+ have been played on a console from a new game, as
  # the last frame left it.
  def console_after(name, rom, &steps)
    RubyGBA.playthrough("hero: #{name}", &steps).play(rom, lead_in: new_game_lead_in).game
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

  # --- Pictures the game draws while it runs ---
  #
  # The sign's box sits along the bottom of the screen and its words start 4 pixels into it;
  # the map sits in the top-right corner, a pixel for every tile of the world.
  WORDS = { xs: (24..215), ys: (144..159) }.freeze
  MAP_CORNER = [204, 4].freeze

  def white_pixels_in_box(screen)
    WORDS[:xs].sum { |x| WORDS[:ys].count { |y| screen.pixel(x, y) == Color.resolve(:white) } }
  end

  # A new game starts a few steps from the sign, so A on the first frame of the walk opens
  # it. Its words type in over the frames after, two frames a letter.
  def test_the_sign_types_its_words_in_a_letter_at_a_time
    reading = ->(frames) { play(frames: frames) { |f| f == 2 ? :a : nil }.screen }
    soon = white_pixels_in_box(reading.call(6))
    later = white_pixels_in_box(reading.call(30))

    assert_operator soon, :>, 0, "a letter or two is up soon after A"
    assert_operator later, :>, soon, "and more of them as the frames go on"
  end

  def test_a_second_a_puts_the_rest_of_the_words_up_at_once
    hurried = play(frames: 6) { |f| [2, 4].include?(f) ? :a : nil }.screen
    typed = play(frames: 60) { |f| f == 2 ? :a : nil }.screen

    assert_equal white_pixels_in_box(typed), white_pixels_in_box(hurried)
  end

  # The map gains a dot where the hero stands, and keeps the one where they stood.
  def test_the_map_gains_a_dot_wherever_the_hero_walks
    walked = play(frames: 42) { |f| f <= 40 ? :right : nil }.screen
    white = Color.resolve(:white)
    start = [MAP_CORNER[0] + (Hero::START_X / 8), MAP_CORNER[1] + (Hero::START_Y / 8)]
    now = [MAP_CORNER[0] + ((Hero::START_X + 80) / 8), MAP_CORNER[1] + (Hero::START_Y / 8)]

    assert_equal white, walked.pixel(*start), "where the walk began"
    assert_equal white, walked.pixel(*now), "where the hero is now, 40 steps of 2 pixels east"
  end

  # On the console: A opens the sign, and its words type in while the map keeps its dot.
  def test_the_console_draws_the_sign_and_the_map_as_the_interpreter_does
    v = console_after "read the sign", unmeasured_hero do
      press :a
      wait frames: 26
    end

    assert v.pixel_is?(MAP_CORNER[0] + (Hero::START_X / 8), MAP_CORNER[1] + (Hero::START_Y / 8), :white), "the map's first dot"
    assert WORDS[:xs].any? { |x| WORDS[:ys].any? { |y| v.pixel_is?(x, y, :white) } }, "the sign's words"
  end

  # SELECT takes the walk to the file screen, and the map of it comes along to the same
  # corner: one picture the game paints, shown on two screens.
  def test_the_file_screen_shows_the_map_of_the_walk_it_was_opened_from
    start = [MAP_CORNER[0] + (Hero::START_X / 8), MAP_CORNER[1] + (Hero::START_Y / 8)]
    files = play(frames: 24) { |f| f <= 16 ? :right : (f == 18 ? :select : nil) }.screen

    refute_equal Color.resolve(:red), files.pixel(*CENTER), "on the file screen, where the hero is not out"
    assert_equal Color.resolve(:white), files.pixel(*start), "the map's first dot is still in the corner"
  end

  def test_the_console_shows_the_map_on_the_file_screen_too
    start = [MAP_CORNER[0] + (Hero::START_X / 8), MAP_CORNER[1] + (Hero::START_Y / 8)]
    v = console_after "walk, then back to the file screen", unmeasured_hero do
      hold :right, frames: 16
      wait frames: 1
      press :select
      wait frames: 12
    end

    refute v.red?(*CENTER), "on the file screen"
    assert v.pixel_is?(*start, :white), "the map's first dot, got 0x#{format('%04X', v.pixel_gba(*start))}"
  end

  # --- The save files ---

  # The game opens on its file screen: the hero is not out yet, and no file holds a walk.
  def test_the_game_opens_on_its_file_screen
    run = power_on(SaveImage.new, frames: 3)

    refute_equal Color.resolve(:red), run.screen.pixel(*CENTER), "the hero waits for a game to start"
    assert_equal [0, 0, 0], (0..2).map { |n| run[:"shown#{n}"] }
  end

  # Walk right, save with START, and turn the console off. On again, the file screen shows
  # how far that walk went; picking the file opens its menu on CONTINUE, which puts the hero back exactly
  # where the save left them — the whole of the world around them drawn the same.
  def test_a_saved_walk_continues_where_it_was_saved
    store = SaveImage.new
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
    store = SaveImage.new
    play(frames: 25, store: store) { |f| f <= 20 ? :right : nil }

    assert_equal 0, power_on(store, frames: 3)[:shown0]
  end

  # ERASE, three rows down from CONTINUE in the file's menu, empties the file; the
  # next power-on finds it empty.
  def test_erase_empties_the_file
    store = SaveImage.new
    play(frames: 25, store: store) { |f| { 21 => :start }.fetch(f) { f <= 20 ? :right : nil } }
    power_on(store, frames: 12, presses: { 1 => :a, 3 => :down, 5 => :down, 7 => :down, 9 => :a })

    assert_equal 0, power_on(store, frames: 3)[:shown0]
  end

  # COPY TO NEXT puts file 1's walk in file 2 as well.
  def test_copy_puts_the_walk_in_the_next_file
    store = SaveImage.new
    play(frames: 25, store: store) { |f| { 21 => :start }.fetch(f) { f <= 20 ? :right : nil } }
    power_on(store, frames: 10, presses: { 1 => :a, 3 => :down, 5 => :down, 7 => :a })

    back = power_on(store, frames: 3)
    assert_equal [20, 20, 0], (0..2).map { |n| back[:"shown#{n}"] }
  end

  # The console: a new game, a walk, START to save, SELECT back to the file screen, and
  # CONTINUE — to the same place the interpreter's hero reaches with the same walk. The
  # interpreter is told its presses by frame, as every interpreter test here is, and the
  # console by a script; what the two share is the walk itself, seventeen frames of RIGHT.
  def test_the_console_saves_and_continues_the_same_walk
    presses = { 4 => :a, 6 => :a, 30 => :start, 34 => :select, 38 => :a, 42 => :a }
    walk = ->(f) { presses.fetch(f) { f.between?(8, 24) ? :right : nil } }
    oracle = Reference.new.input_each_frame { |f| Array(walk.call(f)) }.run(Hero.program, frames: 50)

    v = console_after "walk, save, and continue", unmeasured_hero do
      hold :right, frames: 17
      wait frames: 5
      press :start
      wait frames: 3
      press :select
      wait frames: 3
      press :a
      wait frames: 3
      press :a
      wait frames: 14
    end

    %i[px py steps].each { |name| assert_equal oracle[name], v.var(name), name.to_s }
    assert v.red?(*CENTER), "the hero is back on screen after continuing"
  end

  # --- Hardware (the emulator): the follow-cam really renders and scrolls ---

  def test_the_follow_cam_renders_on_the_console
    v = console_after("stand", shipped_hero) { wait frames: 6 }

    assert v.red?(*CENTER),
           "the hero renders centered on hardware, got 0x#{format('%04X', v.pixel_gba(*CENTER))}"
    assert blue_in?(70..105, 72..92) { |x, y| v.blue?(x, y) },
           "the pond renders near the hero at rest"
  end

  # The console draws the mist over the hero too, and works the amount out as it goes.
  def test_the_mist_thickens_over_the_hero_on_the_console
    rom = shipped_hero
    clear = console_after("stand", rom) { wait frames: 30 }.pixel_gba(*CENTER)
    misted = console_after("walk north", rom) { hold :up, frames: 30 }.pixel_gba(*CENTER)

    assert_equal Color.resolve(:red), clear, "the air is clear until the hero walks north"
    assert_operator misted, :>, clear,
                    "the console left the hero unmisted, got 0x#{format('%04X', misted)}"
  end

  def test_the_world_scrolls_under_the_hero_on_the_console
    v = console_after "walk east", shipped_hero do
      hold :right, frames: 30
      wait frames: 15
    end

    assert v.red?(*CENTER),
           "the hero is still centered after walking, got 0x#{format('%04X', v.pixel_gba(*CENTER))}"
    assert blue_in?(8..46, 72..92) { |x, y| v.blue?(x, y) },
           "the pond has scrolled to the hero's left as the world moved under it"
    refute blue_in?(70..105, 72..92) { |x, y| v.blue?(x, y) },
           "the pond has left its resting spot — the world really scrolled"
  end
end
