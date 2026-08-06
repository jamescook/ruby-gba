# frozen_string_literal: true

require "test_helper"

# Fading the whole screen toward black or white.
#
# Like the camera, this changes what the display SHOWS and not what was drawn — the
# picture is all still there under a fade — so the thing to assert is that colors
# come back exactly when the fade lifts, and that both backends blend by the same
# amounts. A fade that agreed only roughly between backends would make every
# fade-related pixel test a guess.
class TestFade < Minitest::Test

  Guardrails = RubyGBA::IR::Guardrails

  RED = RubyGBA::Color.resolve(:red)
  BLUE = RubyGBA::Color.resolve(:blue)
  BLACK = RubyGBA::Color.resolve(:black)
  WHITE = RubyGBA::Color.resolve(:white)

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A blue screen with a red block at (100, 70), under a fade.
  def faded(toward, amount)
    program do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 70, 40, 20, :red
      fade toward, amount
      halt
    end
  end

  def channels(color)
    [color & 0x1F, (color >> 5) & 0x1F, (color >> 10) & 0x1F]
  end

  # --- the blend ---

  def test_no_fade_shows_the_picture_as_drawn
    i = Reference.new.run(faded(:black, 0))

    assert_equal RED, i.screen.pixel(120, 80)
    assert_equal BLUE, i.screen.pixel(10, 10)
  end

  def test_a_full_fade_to_black_covers_everything
    i = Reference.new.run(faded(:black, 100))

    assert_equal BLACK, i.screen.pixel(120, 80), "the block is gone"
    assert_equal BLACK, i.screen.pixel(10, 10), "and so is the background"
  end

  def test_a_full_fade_to_white_covers_everything
    i = Reference.new.run(faded(:white, 100))

    assert_equal WHITE, i.screen.pixel(120, 80)
    assert_equal WHITE, i.screen.pixel(10, 10)
  end

  # Halfway is halfway on each channel: a full channel (31) keeps 16 of its 31 parts
  # going to black. Asserting the number, not just "darker", is what pins the blend.
  def test_a_half_fade_moves_each_channel_half_way
    dark = Reference.new.run(faded(:black, 50))
    light = Reference.new.run(faded(:white, 50))

    assert_equal [16, 0, 0], channels(dark.screen.pixel(120, 80)), "red, half faded to black"
    assert_equal [0, 0, 16], channels(dark.screen.pixel(10, 10)), "blue, half faded to black"
    assert_equal [31, 15, 15], channels(light.screen.pixel(120, 80)), "red, half faded to white"
  end

  # The invariant that matters: a fade covers the picture, it does not destroy it.
  # If the drawing were really changed, a game that faded out could never fade in.
  def test_the_picture_comes_back_exactly_when_the_fade_lifts
    i = Reference.new.run(program do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 70, 40, 20, :red
      fade :black, 100
      fade :black, 0
      halt
    end)

    assert_equal RED, i.screen.pixel(120, 80)
    assert_equal BLUE, i.screen.pixel(10, 10)
  end

  def test_an_amount_the_game_computes_fades_by_that_much
    i = Reference.new.run(program do
      screen :bitmap
      clear_screen :blue
      level = var :level, 0
      frame = var :frame, 0
      game_loop do
        frame.add 1
        level.approach 100, 25
        fade :black, level
        (frame >= 4).then { halt }
      end
    end)

    assert_equal 100, i[:level], "the level walked all the way up"
    assert_equal BLACK, i.screen.pixel(10, 10), "and the screen followed it"
  end

  # The camera moves the bitmap layer only, so it cannot pan a tiled screen. A fade
  # blends every layer, so it works on both — worth pinning, since the two primitives
  # look alike and this is where they differ. It has to be checked on the console,
  # not just lowered: a tiled screen draws through different layers than a bitmap
  # one, so "which layers does the blend cover" is only really answered there.
  def tiled_fade(amount)
    program do
      screen :tiled
      image(:brick, "#" => :red) { (["########"] * 8).join("\n") }
      tiles :walls, "#" => :brick
      background :field, tiles: :walls, map: (["##############################"] * 20)
      fade :black, amount
      game_loop { }
    end
  end

  def test_a_fade_works_on_a_tiled_screen_too
    assert_equal BLACK, Reference.new.run(tiled_fade(100)).screen.pixel(60, 60)

    lit = ROM.assemble(GBA.new.lower(tiled_fade(0)), title: "FADET", code: "BFDT", maker: "01")
    dark = ROM.assemble(GBA.new.lower(tiled_fade(100)), title: "FADET", code: "BFDT", maker: "01")

    assert assert_gemba_loads_rom(lit, frames: 6).red?(60, 60), "the tiles are there to begin with"
    assert assert_gemba_loads_rom(dark, frames: 6).black?(60, 60),
           "and the fade covers them — every layer, not just the bitmap one"
  end

  # --- friendly errors ---

  def test_fading_to_some_other_color_is_a_friendly_error
    err = assert_raises(ArgumentError) { program { screen :bitmap; fade :blue } }

    assert_match(/black/, err.message, "it names what you can fade to")
    assert_match(/white/, err.message)
  end

  def test_an_amount_outside_the_range_is_a_friendly_error
    err = assert_raises(ArgumentError) { program { screen :bitmap; fade :black, 150 } }

    assert_match(/0 to 100/, err.message)
  end

  # --- the guardrail ---

  def check
    Guardrails::Checks::FadeNeverLifted.new
  end

  def test_a_full_fade_that_is_never_lifted_is_caught
    findings = check.detect(faded(:black, 100))

    assert_equal 1, findings.size
    assert_match(/never fades back/, findings.first.message)
    assert_equal :fade, findings.first.node.kind, "it blames the fade that was left on"
  end

  def test_a_fade_that_is_lifted_is_not_flagged
    prog = program do
      screen :bitmap
      clear_screen :blue
      fade :black, 100
      fade :black, 0
      halt
    end

    assert_empty check.detect(prog)
  end

  # A fade the game drives is how fading over time is written, and where it ends up
  # cannot be read off the tree — so those programs are left alone rather than nagged.
  def test_a_fade_the_game_computes_is_not_flagged
    prog = program do
      screen :bitmap
      clear_screen :blue
      level = var :level, 100
      game_loop { fade :black, level }
    end

    assert_empty check.detect(prog)
  end

  # A part-faded screen still shows the game, so a permanently dimmed screen is a
  # style choice rather than the silent-black-screen bug.
  def test_a_partial_fade_left_on_is_not_flagged
    assert_empty check.detect(faded(:black, 60))
  end

  def test_a_game_that_never_fades_is_not_flagged
    assert_empty check.detect(program { screen :bitmap; clear_screen :blue; halt })
  end

  # --- on the console ---

  def rom_for(toward, amount)
    ROM.assemble(GBA.new.lower(faded(toward, amount)), title: "FADE", code: "BFAD", maker: "01")
  end

  def test_the_fade_really_fades_on_the_console
    assert assert_gemba_loads_rom(rom_for(:black, 0), frames: 4).red?(120, 80),
           "with no fade the console shows the picture as drawn"
    assert assert_gemba_loads_rom(rom_for(:black, 100), frames: 4).black?(10, 10),
           "a full fade to black covers the screen"
    assert assert_gemba_loads_rom(rom_for(:white, 100), frames: 4).white?(10, 10),
           "and a full fade to white does too"
  end

  # Mid-fade the console lands within one step of the interpreter, not exactly on it.
  # That gap is the emulator's, not the blend's: mGBA renders at 8-bit precision and
  # blends there, so reading a color back as 5 bits can round a step down (a channel
  # comes back as 127/255 where the console's own 5-bit blend gives 16/31). The
  # endpoints above are exact, and the blend itself is pinned on the interpreter.
  def test_a_half_fade_on_the_console_matches_the_interpreter_within_a_step
    console = assert_gemba_loads_rom(rom_for(:black, 50), frames: 4).pixel_gba(10, 10)
    interpreted = Reference.new.run(faded(:black, 50)).screen.pixel(10, 10)

    channels(console).zip(channels(interpreted)).each do |got, want|
      assert_in_delta want, got, 1, "console 0x#{format('%04X', console)} vs " \
                                    "interpreter 0x#{format('%04X', interpreted)}"
    end
    refute_equal BLACK, console, "half way is not all the way"
    refute_equal BLUE, console, "and it is not nothing either"
  end
end
