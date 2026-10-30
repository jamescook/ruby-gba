# frozen_string_literal: true

require "test_helper"
require "many_tiles"

# WHAT A COLOR CARTRIDGE SHOWS FROM POWER-ON UNTIL THE GAME'S FIRST FRAME. The cartridge copies its
# art into the console before the game's first line, and a game sets itself up before its first
# frame, which together can take several frames. A Color game whose screens fade in from white
# never shows black on the way: the screen shows the backdrop, the first colour of its first list,
# from power-on until the game draws. A game whose backdrop is black shows black, as it always did.
class TestGBCPowerOn < Minitest::Test
  # A tile of each number, drawn by place from a list whose first colour is white: none of the
  # screen is ever black, so a black pixel is the console showing nothing.
  TILES = 300
  LIST = %i[transparent white red green blue].freeze

  # +count+ tiles of different pictures in the tileset :pale_set, each drawn by place from :pale,
  # declared in +game+; the map of a screen that shows them all in turn, row by row.
  def self.declare_pale_tiles(game, count)
    game.colors :pale, LIST
    names = (0...count).map do |n|
      game.image :"tile#{n}", width: 8, height: 8, colors: :pale,
                              places: Array.new(64) { |i| (n[i % 9] + n[(i + 3) % 9] + (i / 32)) % 4 + 1 }
      :"tile#{n}"
    end
    keys = (0...count).map { |n| (n + 256).chr(Encoding::UTF_8) }
    game.tiles :pale_set, keys.zip(names).to_h
    Array.new(18) { |r| (0...20).map { |c| keys[((r * 20) + c) % count] }.join }
  end

  private def white_game_with_much_art(setting_up:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      map = TestGBCPowerOn.declare_pale_tiles(self, TILES)
      field = background :field, tiles: :pale_set, map: map
      # Drawn with lists of its own, as a screen faded in from white is: its first colour, white,
      # is then the backdrop, since no cell of it is empty.
      colors :pale_again, %i[transparent white blue green red]
      count = var :count, 0
      repeat(setting_up) { count.add! 1 }
      game_loop { field.draw_with :pale_again }
    end
    b.finalize_program
    b.program
  end

  # A GAME WHOSE SCREENS BRING THEIR OWN COLOURS IN: a white title, and a second screen of eight
  # lists more, which together are more than the Color's eight at once. Each screen's lists come in
  # with it, and the title's are not in the console until the game first shows it. A title of
  # +title_tiles+ different tiles takes frames to copy in after the game's first frame, and until
  # its lists come in with it the screen shows nothing drawn: the game's +backdrop+, nil for black.
  private def white_title_among_lists(setting_up: 0, title_tiles: 1, backdrop: nil)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      backdrop ? screen(:tiled, backdrop: backdrop) : screen(:tiled)
      map = TestGBCPowerOn.declare_pale_tiles(self, title_tiles)
      colors :pale_again, %i[transparent white blue green red]
      # Each list holds the backdrop, so one of them can be the list an empty cell shows.
      lists = (0...8).map { |n| [:transparent, VBlank::Graphics::Color.rgb(31, n, n), 31 << 5, 31 << 10, backdrop || 0] }
      row = ManyTiles.declare_listed(self, :many, lists)
      scene(:title) do
        title = background :title, tiles: :pale_set, map: map
        title.draw_with :pale_again
      end
      scene(:busy) { background :busy, tiles: :many, map: [row] }
      count = var :count, 0
      repeat(setting_up) { count.add! 1 }
      var :state, 0
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :busy
        end
      end
    end
    b.finalize_program
    b.program
  end

  # A GAME WHOSE FIRST SCREEN IS PAINTED white, pixel by pixel, rather than drawn from tiles.
  private def white_painted_game(setting_up:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      count = var :count, 0
      repeat(setting_up) { count.add! 1 }
      game_loop do
        clear_screen :white
        fill_rect 40, 40, 20, 20, :red
      end
    end
    b.finalize_program
    b.program
  end

  # Sixteen places across the screen.
  SPOTS = [20, 60, 100, 140].product([16, 56, 96, 136]).freeze

  # The frames of the first thirty a cartridge of +program+ shows black on at any of SPOTS.
  private def black_frames(program)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "WHITE")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 0)
    (1..30).filter_map do |frame|
      v.step
      frame if SPOTS.any? { |x, y| v.pixel_gba(x, y).zero? }
    end
  end

  def test_a_white_game_never_shows_black_while_it_loads
    assert_empty black_frames(white_game_with_much_art(setting_up: 20_000)), "frames that showed black"
  end

  def test_a_white_title_among_screens_with_their_own_colours_never_shows_black_while_it_loads
    assert_empty black_frames(white_title_among_lists(setting_up: 20_000)), "frames that showed black"
  end

  # A TITLE WITH MUCH ART, which takes two frames to copy in after the game's first, shows nothing
  # drawn until then: black, the backdrop of a game that says none — and the game's own, said white,
  # the way a cartridge that fades its screens in from white starts.
  def test_a_white_title_with_much_art_shows_the_backdrop_while_it_loads
    assert_equal [5, 6], black_frames(white_title_among_lists(title_tiles: 200)), "black while it loads"
    assert_empty black_frames(white_title_among_lists(title_tiles: 200, backdrop: :white)), "frames that showed black"
  end

  # ...and plays as the interpreter plays it, pass for pass.
  def test_a_white_title_on_a_white_backdrop_plays_as_the_interpreter_plays_it
    game_player.run(white_title_among_lists(title_tiles: 200, backdrop: :white), frames: 6)
  end

  def test_a_white_painted_screen_never_shows_black_while_it_loads
    assert_empty black_frames(white_painted_game(setting_up: 20_000)), "frames that showed black"
  end

  # THE FRAMES SPENT SETTING UP ARE COUNTED, though the screen is off for all of them: a game that
  # spins before its loop notes what `frames_since_power_on` read on its first pass, and the frame
  # that pass's change is first seen on is one after that.
  private def counting_game(setting_up)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      count = var :count, 0
      passes = var :passes, 0
      first = var :first, -1
      repeat(setting_up) { count.add! 1 }
      game_loop do
        (passes == 0).then { first.set! frames_since_power_on }
        passes.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  # [the frame the first pass is first seen on, what it read]
  private def first_pass_on_color(setting_up)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(counting_game(setting_up), title: "POWERON")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 1, vars: rom.built.variables)
    frame = 1
    until v.var(:passes).positive?
      flunk "no pass ran in 200 frames" if frame == 200
      v.step
      frame += 1
    end
    [frame, v.var(:first)]
  end

  def test_the_frames_spent_setting_up_are_counted
    quick_frame, quick = first_pass_on_color(0)
    slow_frame, slow = first_pass_on_color(3_000)

    assert_equal quick_frame - 1, quick, "a game that sets up at once reads the frames before its first pass"
    assert_operator slow_frame, :>, quick_frame + 3, "spinning first should make setting up take longer"
    assert_equal slow_frame - 1, slow, "and the frames spent setting up are counted"
  end
end
