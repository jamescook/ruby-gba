# frozen_string_literal: true

require "test_helper"

# HOW MUCH SAVE MEMORY A CARTRIDGE HAS, which the build picks from the records it keeps.
#
# The console's cartridges came with 32K of battery-backed memory, or with 64K or 128K of
# flash. A game says nothing: the build lays its save_data records out and takes the smallest
# that holds them. `save_memory:` names one instead, for a game that wants room to grow.
#
# Flash is wiped 4K at a time, so on it every half of a record covers whole 4K blocks, and the
# table of places takes two blocks. That is why a record that is a little over 6K a half needs
# 64K for three copies: 2 blocks a half, 4 a copy, 12, and 2 more.
class TestSaveMemory < Minitest::Test
  # A game whose one record keeps +bytes+ flags, +copies+ times over.
  def game(bytes:, copies:, **options)
    RubyGBA.build("SAVEMEM", out: nil, err: nil, **options) do
      screen :bitmap
      flags = list :flags, capacity: bytes, width: :byte
      files = save_data(:file, copies: copies) { keep flags }
      game_loop { pressed(:a).then { files[0].save } }
    end
  end

  def refusal(**)
    assert_raises(ArgumentError) { game(**) }.message
  end

  # Which save memory a cartridge has is said by the marker an emulator looks for.
  FLASH_64K = "FLASH512_V131"
  FLASH_128K = "FLASH1M_V103"

  def test_records_too_big_for_32k_get_64k_of_flash
    assert_includes game(bytes: 6000, copies: 3).buffer, FLASH_64K
  end

  # Five copies of the same record: 20 blocks and 2 more, which is past 64K's 16.
  def test_records_too_big_for_64k_get_128k
    assert_includes game(bytes: 6000, copies: 5).buffer, FLASH_128K
  end

  # Eight copies: 32 blocks and 2 more, past 128K's 32.
  def test_records_too_big_for_128k_are_refused_naming_the_biggest
    message = refusal(bytes: 6000, copies: 8)

    assert_match(/does not fit in save memory/, message)
    assert_match(/128K/, message)
  end

  def test_a_named_size_the_records_do_not_fit_names_the_size_they_need
    message = refusal(bytes: 6000, copies: 3, save_memory: 32)

    assert_match(/save_memory: 32/, message)
    assert_match(/need 64K/, message)
  end

  def test_a_size_no_cartridge_has_is_refused
    message = refusal(bytes: 10, copies: 1, save_memory: 48)

    assert_match(/48/, message)
    assert_match(/32, 64 or 128/, message)
  end

  # Room to grow is a reason to name a size the records do not need yet.
  def test_naming_flash_for_a_small_game_gives_it_flash
    assert_includes game(bytes: 10, copies: 1, save_memory: 64).buffer, FLASH_64K
  end

  # A game that keeps nothing in a save_data record still has save memory, for its save_var.
  def test_naming_flash_for_a_game_with_only_a_save_var_gives_it_flash
    rom = RubyGBA.build("SAVEMEM", out: nil, err: nil, save_memory: 128) do
      screen :bitmap
      save_var :best, 0
      game_loop {}
    end

    assert_includes rom.buffer, FLASH_128K
  end

  # On flash the save_vars are kept in a record of their own, which takes two blocks. Three
  # copies of a two-block file are 12 blocks, a one-block record 2 and the table 2, which is
  # 64K exactly, so a save_var beside them needs 128K.
  def test_a_save_var_beside_records_on_flash_takes_room_of_its_own
    built = ->(with_save_var) do
      RubyGBA.build("SAVEMEM", out: nil, err: nil) do
        screen :bitmap
        save_var :best, 0 if with_save_var
        flags = list :flags, capacity: 6000, width: :byte
        save_data(:file, copies: 3) { keep flags }
        mode = var :mode, 0
        save_data(:settings) { keep mode }
        game_loop {}
      end.buffer
    end

    assert_includes built.call(false), FLASH_64K
    assert_includes built.call(true), FLASH_128K
  end

  # Said on the line that names the game, beside its cartridge code, it reaches the build.
  def test_the_size_can_be_named_where_the_game_is_named
    named = RubyGBA.game("SAVEMEM", save_memory: 64) do
      screen :bitmap
      flags = list :flags, capacity: 10, width: :byte
      save_data(:file) { keep flags }
      game_loop {}
    end

    assert_equal 64, RubyGBA::IR::SaveLayout.memory_of(named.program).kilobytes
  end

  def test_naming_32k_for_a_game_that_fits_builds_the_same_cartridge
    assert_equal game(bytes: 1000, copies: 3).buffer, game(bytes: 1000, copies: 3, save_memory: 32).buffer
  end
end
