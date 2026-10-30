# frozen_string_literal: true

require "test_helper"
require "console/gba/examples/test_hero_example"

# The Hero example (examples/hero.rb) on the Advance's cartridge: built as it ships, and played
# in the emulator by a script. What every run that plays the Advance is held to is in
# test/console/gba/examples/test_hero_example.rb.
class TestHeroExampleCartridge < Minitest::Test
  include HeroExamplePlaces

  # THE WAY INTO THE GAME ON THE CONSOLE, as a lead-in every console test here starts with:
  # the game opens on its file screen, A picks FILE 1, whose menu opens on NEW GAME since
  # the file is empty, and A again starts the game. Nothing in it is counted, so each
  # test's own script begins with the hero standing in the world.
  private def new_game_lead_in
    VBlank.playthrough "hero: a new game" do
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
  private def shipped_hero = Hero.build_rom(err: StringIO.new)

  # The same game built without the measuring, which is quicker and is the same game: for
  # the tests that are about what the game does and not about how it was laid out.
  private def unmeasured_hero = Hero.build_rom(err: StringIO.new, profile: false)

  # The running cartridge after +steps+ have been played on a console from a new game, as
  # the last frame left it.
  private def console_after(name, rom, &steps)
    require_emulator!
    VBlank.playthrough("hero: #{name}", &steps).play(rom, lead_in: new_game_lead_in).game
  end

  def test_the_example_builds_clean
    rom = Hero.build_rom(err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
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

  # The console: a new game, a walk, START to save, SELECT back to the file screen, and
  # CONTINUE — to the same place the interpreter's hero reaches with the same walk. The
  # interpreter is told its presses by frame, as every interpreter test here is, and the
  # console by a script; what the two share is the walk itself, seventeen frames of RIGHT.
  def test_the_console_saves_and_continues_the_same_walk
    presses = { 4 => :a, 6 => :a, 30 => :start, 34 => :select, 38 => :a, 42 => :a }
    walk = ->(f) { presses.fetch(f) { f.between?(8, 24) ? :right : nil } }
    oracle = game_player.input_each_frame { |f| Array(walk.call(f)) }.run(Hero.program, frames: 50)

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
