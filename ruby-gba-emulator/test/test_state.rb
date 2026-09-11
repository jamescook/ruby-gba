# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "zlib"

# SAVING AND RESTORING THE WHOLE CONSOLE, and telling which cartridge a saved state belongs to.
#
# A state is how a moment gets measured that nobody can reach by holding a button — the boss
# with its health half gone, the floor with sixty guards. Play to it once, save it, and it can
# be come back to for ever after.
#
# The identity half carries as much weight as the saving half. A state is a snapshot of
# ADDRESSES, and rebuilding the game moves every one of them, so a state read into the wrong
# build produces numbers about whatever code took those addresses over. mGBA will not catch
# that for us — these tests pin down exactly what it does and does not catch, because the
# caller's guard is built on the difference.
class TestRubyGBAEmulatorState < Minitest::Test
  include RubyGBAEmulatorTestSupport

  def counting_rom(name, code, bump)
    build_rom(name, code: code) do
      screen :bitmap
      clear_screen :black
      var :x, 0
      game_loop { add :x, bump }
    end
  end

  def test_a_saved_state_comes_back_where_it_was_left
    Dir.mktmpdir do |dir|
      path = File.join(dir, "moment.state")
      rom = counting_rom("SAVE", "SAVE", 1)

      settled = with_probe(rom) do |probe|
        probe.step(30)
        probe.save_state(path)
        probe.read32(0x0300_0000)
      end

      assert_operator File.size(path), :>, 0

      with_probe(rom) do |probe|
        probe.step(2) # somewhere else entirely
        probe.load_state(path)
        assert_equal settled, probe.read32(0x0300_0000),
                     "the console is back in the moment that was saved"
      end
    end
  end

  def test_a_state_says_which_cartridge_it_came_from
    Dir.mktmpdir do |dir|
      path = File.join(dir, "moment.state")
      rom = counting_rom("IDNT", "IDNT", 1)

      with_probe(rom) do |probe|
        probe.step(10)
        probe.save_state(path)
      end

      with_probe(rom) do |probe|
        said = probe.state_identity(path)
        assert_equal Zlib.crc32(File.binread(rom)), said[:rom_crc32]
        assert_equal "IDNT", said[:title]
      end
    end
  end

  # WHAT mGBA CATCHES BY ITSELF, and it is only half of what matters: it compares the title in
  # the cartridge header, so a state from a DIFFERENT GAME is refused...
  def test_a_state_from_a_different_game_will_not_load
    Dir.mktmpdir do |dir|
      path = File.join(dir, "moment.state")
      with_probe(counting_rom("ONEG", "ONEG", 1)) do |probe|
        probe.step(10)
        probe.save_state(path)
      end

      with_probe(counting_rom("TWOG", "TWOG", 7)) do |probe|
        probe.step(1)
        assert_raises(RuntimeError) { probe.load_state(path) }
      end
    end
  end

  # ...and a state from a different BUILD of the same game LOADS QUITE HAPPILY, which is the
  # case that happens every time somebody edits a line. The identity is the only thing that
  # separates them, which is why it is exposed rather than left to the loader.
  def test_a_state_from_another_build_of_the_same_game_loads_but_its_identity_differs
    Dir.mktmpdir do |dir|
      path = File.join(dir, "moment.state")
      first = counting_rom("REBL", "REBL", 1)
      again = counting_rom("REBL", "REBL", 2) # one number changed; every address moved

      refute_equal Zlib.crc32(File.binread(first)), Zlib.crc32(File.binread(again)),
                   "the two builds really are different cartridges"

      with_probe(first) do |probe|
        probe.step(10)
        probe.save_state(path)
      end

      with_probe(again) do |probe|
        probe.step(1)
        probe.load_state(path) # no complaint from the emulator at all
        assert_equal Zlib.crc32(File.binread(first)), probe.state_identity(path)[:rom_crc32],
                     "the state still names the build it came from, which is how a caller can tell"
      end
    end
  end

  def test_a_state_file_that_is_not_there_says_so
    with_probe(counting_rom("MISS", "MISS", 1)) do |probe|
      assert_raises(ArgumentError) { probe.load_state("/nowhere/moment.state") }
      assert_nil probe.state_identity("/nowhere/moment.state")
    end
  end

  def test_a_file_that_is_not_a_state_is_not_read_as_one
    Dir.mktmpdir do |dir|
      path = File.join(dir, "not.state")
      File.binwrite(path, "this is not a save state")

      with_probe(counting_rom("JUNK", "JUNK", 1)) do |probe|
        assert_nil probe.state_identity(path)
      end
    end
  end
end
