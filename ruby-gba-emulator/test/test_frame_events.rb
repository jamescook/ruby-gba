# frozen_string_literal: true

require_relative "test_helper"

# WHAT HAPPENED WHILE THAT FRAME RAN.
#
# The binding's contract has been "run a frame, then ask questions", so everything about
# WHEN something happened had to be reconstructed afterwards — and some of it could not be
# reconstructed at all, so the framework resorted to adding a counter to the cartridge and
# measuring that instead. The core tells us these things itself; it just has to be asked.
class TestFrameEvents < Minitest::Test
  include RubyGBAEmulatorTestSupport

  # A tiled screen draws from 8x8 tiles, so that is what a tileset's art has to be.
  TILE_8X8 = ("########\n" * 8).freeze

  def test_a_probe_says_how_often_the_game_asked_for_buttons
    path = build_rom("PADREAD", code: "TPAD") do
      screen :bitmap
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        held(:right).then { tick.add! 1 }
      end
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(8)

    assert_operator probe.pad_reads, :>, 0, "the game ran, and it reads the pad every pass"
    assert_operator probe.pad_reads, :<=, 8, "it cannot have asked more often than there were frames"
  end

  # The trap this name exists to avoid: a game loop that never asks for input reads the pad
  # never, however many times it goes round. So this counts the asking, and a test wanting
  # passes has to count something else.
  def test_a_game_that_never_asks_for_buttons_reads_the_pad_never
    path = build_rom("NOPAD", code: "TNOP") do
      screen :bitmap
      game_loop { clear_screen :blue }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(8)

    assert_equal 0, probe.pad_reads
  end

  # WHERE THE SPRITES ARE, asked rather than deduced.
  #
  # A test that wants to know where a sprite is has had to hunt for its pixels and reason
  # backwards — which fails for a sprite behind something, one drawn in the backdrop colour,
  # or one off the edge, and says nothing at all about a sprite that is hidden when it
  # should not be. The console keeps a table of them and the emulator has it.
  def test_a_probe_can_read_the_sprites_the_console_is_showing
    path = build_rom("SPRITES", code: "TSPR") do
      screen :tiled
      image(:dot, "." => :transparent, "#" => :red) { <<~ART }
        ########
        ########
        ########
        ########
        ########
        ########
        ########
        ########
      ART
      sprite :dot, at: [40, 24]
      game_loop { wait_vblank }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(4)
    shown = probe.sprites

    assert_equal 1, shown.size, "one sprite was declared, so one is on screen"
    assert_equal 40, shown.first[:x]
    assert_equal 24, shown.first[:y]
  end

  # A sprite the game has hidden is not on screen, and the table says so rather than the
  # test inferring it from an absence of pixels — which is the same picture a sprite drawn
  # in the backdrop colour makes.
  def test_a_hidden_sprite_is_not_among_the_ones_being_shown
    path = build_rom("HIDDEN", code: "THID") do
      screen :tiled
      image(:dot, "." => :transparent, "#" => :red) { <<~ART }
        ########
        ########
        ########
        ########
        ########
        ########
        ########
        ########
      ART
      s = sprite :dot, at: [40, 24]
      s.hide
      game_loop { wait_vblank }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(4)

    assert_empty probe.sprites
  end

  # THE COLOURS THE CONSOLE IS DRAWING FROM. A game fades, tints, or swaps a character's
  # colours by changing this table rather than by redrawing anything — so "did the fade
  # happen" read off the picture is really a question about these numbers, asked the long
  # way round and confounded by whatever else is on screen.
  def test_a_probe_can_read_the_colours_the_console_is_drawing_from
    path = build_rom("PALETTE", code: "TPAL") do
      screen :tiled
      image(:brick, "#" => :red) { TILE_8X8 }
      tiles :set, "#" => :brick
      background :bg, tiles: :set, map: "##\n##\n"
      game_loop { wait_vblank }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(4)
    colours = probe.palette

    assert_equal 512, colours.size, "the console holds 512 colours, backgrounds then sprites"
    assert(colours.any? { |c| c.positive? }, "the game declared colours, so some are set")
  end

  # WHERE THE CAMERA IS. A scrolling game moves the window over its map, and the registers
  # that say by how much are write-only on the hardware — so a test reading the picture can
  # only guess at it. The emulator kept the values.
  def test_a_probe_can_read_where_each_background_is_scrolled_to
    path = build_rom("SCROLL", code: "TSCR") do
      screen :tiled
      image(:brick, "#" => :red) { TILE_8X8 }
      tiles :set, "#" => :brick
      bg = background :bg, tiles: :set, map: "##\n##\n"
      game_loop { bg.scroll_to 24, 8 }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(6)
    across, down = probe.scroll(0)

    assert_equal 24, across
    assert_equal 8, down
  end

  # What the emulator itself said while the frame ran. mGBA reports a bad read or an
  # unimplemented register as a log line; the binding has been discarding every one of them,
  # so a cartridge doing something the console would object to fails a test silently.
  def test_a_probe_keeps_what_the_emulator_said
    path = build_rom("QUIET", code: "TQUI") do
      screen :bitmap
      game_loop { clear_screen :blue }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(4)

    assert probe.respond_to?(:complaints), "a probe can say what the emulator complained about"
    assert_kind_of Array, probe.complaints
  end
end
