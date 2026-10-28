# frozen_string_literal: true

require "test_helper"

# A game says which consoles it is for (`consoles:`), and is built for any of them: its block reads
# the screen it is being built for (`screen_width`, `screen_height`), so one game lays itself out
# for the Advance's 240×160 and the Game Boy Color's 160×144 alike. A game for the Advance alone is
# refused for the Color in plain words.
class TestGameConsoles < Minitest::Test
  GAME = VBlank.game("BOTH", consoles: %i[gba gbc]) do
    var :wide, screen_width
    var :tall, screen_height
    game_loop { wait_vblank }
  end

  ADVANCE_ONLY = VBlank.game("ADVANCE", consoles: %i[gba]) { var :x, 1 }

  private def interpreted(program) = Reference.new.run(program, frames: 1)

  def test_the_block_reads_the_screen_of_the_console_it_is_built_for
    assert_equal [240, 160], interpreted(GAME.program).then { |run| [run[:wide], run[:tall]] }
    assert_equal [160, 144], interpreted(GAME.program(console: :gbc)).then { |run| [run[:wide], run[:tall]] }
  end

  def test_the_interpreter_plays_a_color_program_on_the_colors_screen
    screen = interpreted(GAME.program(console: :gbc)).screen

    assert_equal [160, 144], [screen.width, screen.height]
  end

  def test_a_game_for_the_color_builds_a_color_cartridge_named_for_it
    rom = GAME.build_rom(console: :gbc, out: nil, err: nil, profile: false)

    assert_kind_of VBlank::Cartridge::GBCROM, rom
    assert rom.valid_header?
    assert_equal "both.gbc", GAME.default_filename(console: :gbc)
    assert_equal "both.gba", GAME.default_filename
  end

  def test_a_game_for_the_advance_alone_is_refused_for_the_color_naming_both_screens
    error = assert_raises(ArgumentError) { ADVANCE_ONLY.program(console: :gbc) }

    assert_match(/written for the Game Boy Advance, not the Game Boy Color/, error.message)
    assert_match(/160×144/, error.message)
    assert_match(/consoles: %i\[gba gbc\]/, error.message)
  end

  # Nothing is taken to be for the Advance: a game that names no console is refused where it is
  # named, saying what to write.
  def test_a_game_that_names_no_console_is_refused_saying_what_to_write
    error = assert_raises(ArgumentError) { VBlank.game("SILENT") { var :x, 1 } }

    assert_match(/SILENT does not say which consoles it is for/, error.message)
    assert_match(/consoles: %i\[gba\]/, error.message)
    assert_match(/consoles: %i\[gba gbc\]/, error.message)
  end

  def test_a_console_there_is_not_is_refused_naming_the_ones_there_are
    error = assert_raises(ArgumentError) { VBlank.game("X", consoles: %i[gba nes]) { var :x, 1 } }

    assert_match(/no console named :nes/, error.message)
  end

  def test_a_chip_is_named_beside_the_consoles
    game = VBlank.game("CHIPPED", consoles: %i[gba snes], variants: { snes: :superfx }) { var :x, 1 }

    assert_equal :superfx, game.variant_for(:snes)
    assert_nil game.variant_for(:gba)
    assert_equal :superfx, game.program(console: :snes).variant
    assert_nil game.program(console: :snes, variant: nil).variant
  end

  def test_a_variant_the_console_does_not_have_is_refused_naming_the_ones_it_has
    error = assert_raises(ArgumentError) { VBlank.game("X", consoles: %i[snes], variants: { snes: :dsp1 }) { var :x, 1 } }

    assert_match(/has no variant named :dsp1/, error.message)
    assert_match(/:superfx/, error.message)
  end

  def test_a_variant_for_a_console_the_game_is_not_for_is_refused
    error = assert_raises(ArgumentError) { VBlank.game("X", consoles: %i[gba], variants: { snes: :superfx }) { var :x, 1 } }

    assert_match(/not for it/, error.message)
    assert_match(/add :snes to consoles:/, error.message)
  end

  def test_variants_that_are_not_a_hash_are_refused
    error = assert_raises(ArgumentError) { VBlank.game("X", consoles: %i[snes], variants: :superfx) { var :x, 1 } }

    assert_match(/variants: \{ snes: :superfx \}/, error.message)
  end
end
