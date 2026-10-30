# frozen_string_literal: true

require "test_helper"
require "stringio"
require "all/vblank/builder/test_layer_transparency"

# A see-through layer on the Advance's cartridge: the picture read back in the emulator, and what
# the cartridge's build report says about it. What every run is held to is in
# test/all/vblank/builder/test_layer_transparency.rb, and what only the Advance can play in
# test/console/gba/vblank/builder/test_layer_transparency_on_the_advance.rb.
class TestLayerTransparencyCartridge < Minitest::Test
  include LayerTransparencyGames

  # The build report reads a finished cartridge, so a program under test has to be lowered
  # and carry the record the build made — where each routine ended up cannot be recovered
  # from the bytes afterwards.
  private def report_of(prog)
    backend = VBlank::IR::Backends::GBA.new
    machine_code = backend.lower(prog)
    rom = VBlank::Cartridge::ROM.assemble(machine_code, title: "LAYR", code: "LAYR", maker: "01",
                                              built: backend.build_record(prog))
    out = StringIO.new
    VBlank::Diagnostics::BuildReport.render(rom, out: out)
    out.string
  end

  private def console(program, x, y, name, frames: 6)
    assert_emulator_loads_rom(assemble_rom(program, name: name), frames: frames).pixel_gba(x, y)
  end

  def test_the_console_blends_a_see_through_layer_of_scenery_the_same
    [0, 50, 100].each_with_index do |amount, i|
      assert_equal [WHITE, HALF_WHITE_OVER_RED, RED][i],
                   console(scenery_program(amount), *SCENERY_XY, "SEEBG"),
                   "at #{amount} see-through the scenery disagrees"
    end
  end

  def test_the_console_blends_a_see_through_layer_of_sprites_the_same
    [0, 50, 100].each_with_index do |amount, i|
      assert_equal [WHITE, HALF_WHITE_OVER_RED, RED][i],
                   console(sprite_program(amount), *SPRITE_XY, "SEEOBJ"),
                   "at #{amount} see-through the sprite disagrees"
    end
  end

  # A see-through layer is a standing property of the picture, not something done each
  # frame, so it must not drift as the game runs.
  def test_the_blend_holds_frame_after_frame
    program = sprite_program(50)

    assert_equal HALF_WHITE_OVER_RED,
                 assert_emulator_loads_rom(assemble_rom(program, name: "SEEHLD"), frames: 40).pixel_gba(*SPRITE_XY)
  end

  # BEFORE the first frame boundary has even run, the layer is already at the amount its
  # variable starts at — boot writes that rather than waiting to be told. A game whose fog
  # starts clear must not flash solid on the way in.
  #
  # The first frame SHOWN, which is not a fixed number: the picture is held off, white, until
  # the game's first frame is set up, and how long setting up takes is the game's own affair.
  def test_the_first_frame_shows_the_amount_the_game_starts_at
    rom = assemble_rom(clearing_program, name: "FOGBOO")
    v = assert_emulator_loads_rom(rom, frames: 1)
    # A few frames at most: a layer that came up solid is white too, and would never stop.
    CONSOLE_LAG.times { v.step if v.pixel_gba(*SCENERY_XY) == WHITE }

    assert_equal RED, v.pixel_gba(*SCENERY_XY)
  end

  def test_the_console_leaves_the_layer_see_through_under_a_fade_too
    %i[scenery sprite].each do |kind|
      solid = console(faded_program(kind, 0, 25), *faded_xy(kind), "FADSOL")

      refute_equal solid, console(faded_program(kind, 50, 25), *faded_xy(kind), "FADSEE"),
                   "the console made the see-through #{kind} layer solid under a fade"
    end
  end

  def test_the_console_gives_the_layer_back_after_a_flash_too
    %i[scenery sprite].each do |kind|
      assert_equal HALF_WHITE_OVER_RED,
                   console(flashing_program(kind), *faded_xy(kind), "FLSBAK", frames: AFTER_THE_FLASH),
                   "the console never gave the #{kind} layer back"
    end
  end

  def test_a_lifting_fade_hands_back_the_amount_the_game_has_now
    settled = AFTER_THE_FLASH + CONSOLE_LAG

    assert_equal console(thickening_program(lifting: false), *SCENERY_XY, "NOFADE", frames: settled),
                 console(thickening_program(lifting: true), *SCENERY_XY, "FOGFAD", frames: settled),
                 "the lifted fade left the layer at some other amount than the one the game had"
  end

  # The half that was wrong: the console was told to blend a layer number the pane is not
  # on, so it drew the pane solid and the floor under it simply was not there.
  def test_the_console_sees_through_a_scenes_own_layer_the_same
    assert_equal HALF_WHITE_OVER_RED,
                 console(scenes_that_take_turns, *SCENERY_XY, "SCNBLD", frames: SWITCH_AT + 6),
                 "the console drew the scene's pane solid"
  end

  def test_the_report_says_a_fade_walks_the_colours_and_keeps_the_layer
    assert_includes report_of(flashing_program(:scenery)), "walks the colours"
  end

  def test_the_report_says_a_placed_fade_takes_the_blend
    assert_includes report_of(placed_fade_program(50, 25)), "is solid until it lifts"
  end

  def test_the_report_leaves_both_out_when_nothing_fades
    report = report_of(scenery_program(40))

    refute_includes report, "walks the colours"
    refute_includes report, "is solid until it lifts"
  end

  def test_the_report_says_which_layer_is_see_through
    assert_includes report_of(scenery_program(40)), ":glass is 40 see-through"
  end

  # ...and says that it costs nothing, which is the whole bargain of the tiled screen: the
  # display blends as it draws, so a see-through layer costs the same as the same layer drawn
  # solid, however much is on screen.
  def test_the_report_says_seeing_through_a_layer_is_free
    assert_includes report_of(scenery_program(40)), "the display blends it as it draws, for nothing"
  end
end
