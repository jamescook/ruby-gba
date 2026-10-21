# frozen_string_literal: true

require "test_helper"

# A game too big for a Game Boy Color cartridge is refused in words about the game: which of its
# parts is too big, and what to do about it. A part that is the framework's own is the
# framework's fault, and stays an internal error with the linker's words.
class TestGBCLinker < Minitest::Test
  GBC = RubyGBA::IR::Backends::GBC
  Linker = GBC::Linker
  SM83 = GBC::SM83

  TABLES = SM83::Holding.new(what: "the game's tables", fix: "make its tables shorter")
  PICTURES = SM83::Holding.new(what: "the game's pictures", fix: "use fewer pictures")

  private def section(name, bytes, home:, holds: nil)
    asm = SM83.new(name, home: home, holds: holds)
    asm.label(name.tr(" ", "_"))
    asm.data_bytes(Array.new(bytes, 0))
    asm.section
  end

  private def link(*sections) = Linker.new(sections).link

  def test_a_game_part_too_big_for_the_part_always_in_view_is_named_with_its_fix
    error = assert_raises(Linker::TooBig) do
      link(section("runtime", 4000, home: :fixed), section("data", 14_000, home: :fixed, holds: TABLES))
    end

    assert_kind_of GBC::LoweringError, error
    assert_match(/does not fit in a Game Boy Color cartridge/, error.message)
    assert_match(/the game's tables take 14000 bytes/, error.message)
    assert_match(/To fix this, make its tables shorter\./, error.message)
  end

  def test_the_frameworks_own_code_too_big_for_the_part_always_in_view_is_an_internal_error
    error = assert_raises(Linker::Error) do
      link(section("runtime", 17_000, home: :fixed), section("data", 10, home: :fixed, holds: TABLES))
    end

    refute_kind_of GBC::LoweringError, error
  end

  def test_a_game_part_bigger_than_a_bank_is_named_with_its_fix
    error = assert_raises(Linker::TooBig) { link(section("tiles", 17_000, home: :banked, holds: PICTURES)) }

    assert_match(/the game's pictures needs 17000 bytes in one bank/, error.message)
    assert_match(/To fix this, use fewer pictures\./, error.message)
  end

  def test_a_section_of_the_frameworks_bigger_than_a_bank_is_an_internal_error
    assert_raises(Linker::Error) { link(section("runtime part", 17_000, home: :banked)) }
  end

  # The runtime switches banks by the eight bits of the bank number, so the cartridge has 256
  # banks at most. A game that needs more is refused rather than built with its bank numbers
  # wrapping round onto the wrong code.
  def test_a_game_that_needs_more_banks_than_the_cartridge_has_is_refused
    pictures = Array.new(Linker::MOST_BANKS) { |i| section("pictures #{i}", 10_000, home: :banked, holds: PICTURES) }
    error = assert_raises(Linker::TooBig) { link(*pictures) }

    assert_match(/does not fit in a Game Boy Color cartridge/, error.message)
    assert_match(/the game's pictures take #{256 * 10_000} bytes/, error.message)
    assert_match(/To fix this, use fewer pictures\./, error.message)
  end
end
