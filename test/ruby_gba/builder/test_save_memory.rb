# frozen_string_literal: true

require "test_helper"

# HOW MUCH SAVE MEMORY A CARTRIDGE HAS, which the build picks from the records it keeps.
#
# The console's cartridges came with 32K of battery-backed memory, or with 64K or 128K of
# flash. A game says nothing: the build lays its save_data records out and takes the smallest
# that holds them. `save_memory:` names one instead, for a game that wants room to grow.
#
# Flash is wiped 4K at a time, so on it every half of a record covers whole 4K blocks, and the
# table of places and save_var's values take two blocks each. That is why a record that is a
# little over 6K a half needs 64K for three copies: 2 blocks a half, 4 a copy, 12, and 4 more.
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

  def test_records_too_big_for_32k_ask_for_64k_of_flash
    message = refusal(bytes: 6000, copies: 3)

    assert_match(/64K/, message)
    assert_match(/not available yet/, message)
  end

  # Five copies of the same record: 20 blocks and 4 more, which is past 64K's 16.
  def test_records_too_big_for_64k_ask_for_128k
    assert_match(/128K/, refusal(bytes: 6000, copies: 5))
  end

  # Eight copies: 32 blocks and 4 more, past 128K's 32.
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

  # Room to grow is a reason to name a size the records do not need yet, and it is flash.
  def test_naming_flash_for_a_small_game_is_not_available_yet
    message = refusal(bytes: 10, copies: 1, save_memory: 64)

    assert_match(/not available yet/, message)
    assert_match(/leave `save_memory:` out/, message, "the records fit 32K, so keeping less is not the fix")
  end

  # A game that keeps nothing in a save_data record still has save memory, for its save_var.
  def test_naming_flash_for_a_game_with_only_save_var_is_not_available_yet
    message = assert_raises(ArgumentError) do
      RubyGBA.build("SAVEMEM", out: nil, err: nil, save_memory: 128) do
        screen :bitmap
        save_var :best, 0
        game_loop {}
      end
    end.message

    assert_match(/leave `save_memory:` out/, message)
  end

  # Said on the line that names the game, beside its cartridge code, it reaches the build.
  def test_the_size_can_be_named_where_the_game_is_named
    named = RubyGBA.game("SAVEMEM", save_memory: 64) do
      screen :bitmap
      flags = list :flags, capacity: 10, width: :byte
      save_data(:file) { keep flags }
      game_loop {}
    end

    assert_match(/not available yet/, assert_raises(ArgumentError) { named.program }.message)
  end

  # A program built by hand rather than as a game skips the game's own refusal, so the step that
  # makes the cartridge refuses flash too: it has only the 32K kind to write to.
  def test_a_flash_program_built_by_hand_is_refused_on_its_way_to_a_cartridge
    builder = Builder.new(save_memory: 64)
    builder.instance_eval do
      screen :bitmap
      save_var :best, 0
      game_loop {}
    end
    builder.finalize_program

    error = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { assemble_rom(builder.program) }
    assert_match(/not available yet/, error.message)
  end

  def test_naming_32k_for_a_game_that_fits_builds_the_same_cartridge
    assert_equal game(bytes: 1000, copies: 3).buffer, game(bytes: 1000, copies: 3, save_memory: 32).buffer
  end
end
