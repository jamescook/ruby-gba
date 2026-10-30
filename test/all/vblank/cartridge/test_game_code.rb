# frozen_string_literal: true

require "test_helper"

# The four characters in a cartridge's header are the only thing an emulator has to
# tell one cartridge from another, so a made-up code that belongs to a real one is a
# cartridge wearing somebody else's name and somebody else's save hardware.
class TestGameCode < Minitest::Test
  CODE = VBlank::Cartridge::ROM::HEADER_CODE
  MAKER = VBlank::Cartridge::ROM::HEADER_MAKER

  def test_a_real_cartridges_code_is_taken
    assert VBlank::Cartridge::GameCode.taken?("BSMP"), "Metal Slug Advance shipped with this code"
  end

  # The header field is upper-case ASCII, and an emulator would match the lower-case
  # spelling to the same cartridge.
  def test_a_taken_code_is_taken_however_it_is_spelled
    assert VBlank::Cartridge::GameCode.taken?("bsmp")
  end

  def test_no_real_cartridge_starts_with_one_of_the_free_letters
    VBlank::Cartridge::GameCode::FREE_LETTERS.each do |letter|
      starting = VBlank::Cartridge::GameCode.known.select { |code| code.start_with?(letter) }
      assert_empty starting, "#{letter} was supposed to be free"
    end
  end

  def test_the_letter_the_framework_picks_is_one_of_the_free_ones
    assert_includes VBlank::Cartridge::GameCode::FREE_LETTERS, VBlank::Cartridge::GameCode::OUR_LETTER
  end

  def test_the_framework_works_a_free_code_out_from_the_name
    code = VBlank::Cartridge::GameCode.for("SNAKE")

    assert_equal 4, code.length
    refute VBlank::Cartridge::GameCode.taken?(code), "#{code} belongs to a real cartridge"
  end

  def test_the_same_name_always_gets_the_same_code
    assert_equal VBlank::Cartridge::GameCode.for("SNAKE"), VBlank::Cartridge::GameCode.for("SNAKE")
  end

  # Two games that start the same way still get codes of their own, so an emulator
  # keeps their saves apart.
  def test_names_that_start_the_same_get_different_codes
    refute_equal VBlank::Cartridge::GameCode.for("SNAKE"), VBlank::Cartridge::GameCode.for("SNAKEBUF")
  end

  # A game says what it is called and nothing else: the four characters underneath
  # are the framework's business.
  def test_a_game_that_writes_no_code_gets_a_free_one
    rom = VBlank.build("SNAKE", console: :gba, out: nil, err: nil) { halt }

    assert_equal VBlank::Cartridge::GameCode.for("SNAKE"), rom.buffer[CODE, 4], "game code"
    refute_equal "01", rom.buffer[MAKER, 2], "01 is Nintendo's maker code"
  end

  def test_a_code_a_real_cartridge_carries_stops_the_build
    error = assert_raises(ArgumentError) do
      VBlank.build("SHMUP", console: :gba, code: "BSMP", maker: "01", out: nil, err: nil) { halt }
    end

    assert_includes error.message, "BSMP"
    assert_includes error.message, "code:"
  end

  def test_a_free_code_written_by_hand_is_left_alone
    rom = VBlank.build("SHMUP", console: :gba, code: "HSMP", maker: "01", out: nil, err: nil) { halt }

    assert_equal "HSMP", rom.buffer[CODE, 4]
    assert_equal "01", rom.buffer[MAKER, 2]
  end
end
