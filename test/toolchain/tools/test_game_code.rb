# frozen_string_literal: true

require "test_helper"

# The four characters in a cartridge's header are the only thing an emulator has to
# tell one cartridge from another, so a made-up code that belongs to a real one is a
# cartridge wearing somebody else's name and somebody else's save hardware.
class TestGameCode < Minitest::Test
  CODE = RubyGBA::Cartridge::ROM::HEADER_CODE
  MAKER = RubyGBA::Cartridge::ROM::HEADER_MAKER

  def test_a_real_cartridges_code_is_taken
    assert RubyGBA::Cartridge::GameCode.taken?("BSMP"), "Metal Slug Advance shipped with this code"
  end

  # The header field is upper-case ASCII, and an emulator would match the lower-case
  # spelling to the same cartridge.
  def test_a_taken_code_is_taken_however_it_is_spelled
    assert RubyGBA::Cartridge::GameCode.taken?("bsmp")
  end

  def test_no_real_cartridge_starts_with_one_of_the_free_letters
    RubyGBA::Cartridge::GameCode::FREE_LETTERS.each do |letter|
      starting = RubyGBA::Cartridge::GameCode.known.select { |code| code.start_with?(letter) }
      assert_empty starting, "#{letter} was supposed to be free"
    end
  end

  def test_the_letter_the_framework_picks_is_one_of_the_free_ones
    assert_includes RubyGBA::Cartridge::GameCode::FREE_LETTERS, RubyGBA::Cartridge::GameCode::OUR_LETTER
  end

  def test_the_framework_works_a_free_code_out_from_the_name
    code = RubyGBA::Cartridge::GameCode.for("SNAKE")

    assert_equal 4, code.length
    refute RubyGBA::Cartridge::GameCode.taken?(code), "#{code} belongs to a real cartridge"
  end

  def test_the_same_name_always_gets_the_same_code
    assert_equal RubyGBA::Cartridge::GameCode.for("SNAKE"), RubyGBA::Cartridge::GameCode.for("SNAKE")
  end

  # Two games that start the same way still get codes of their own, so an emulator
  # keeps their saves apart.
  def test_names_that_start_the_same_get_different_codes
    refute_equal RubyGBA::Cartridge::GameCode.for("SNAKE"), RubyGBA::Cartridge::GameCode.for("SNAKEBUF")
  end

  # A game says what it is called and nothing else: the four characters underneath
  # are the framework's business.
  def test_a_game_that_writes_no_code_gets_a_free_one
    rom = RubyGBA.build("SNAKE") { halt }

    assert_equal RubyGBA::Cartridge::GameCode.for("SNAKE"), rom.buffer[CODE, 4], "game code"
    refute_equal "01", rom.buffer[MAKER, 2], "01 is Nintendo's maker code"
  end

  def test_a_code_a_real_cartridge_carries_stops_the_build
    error = assert_raises(ArgumentError) do
      RubyGBA.build("SHMUP", code: "BSMP", maker: "01") { halt }
    end

    assert_includes error.message, "BSMP"
    assert_includes error.message, "code:"
  end

  def test_a_free_code_written_by_hand_is_left_alone
    rom = RubyGBA.build("SHMUP", code: "HSMP", maker: "01") { halt }

    assert_equal "HSMP", rom.buffer[CODE, 4]
    assert_equal "01", rom.buffer[MAKER, 2]
  end
end
