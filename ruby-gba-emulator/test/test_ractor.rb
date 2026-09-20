# frozen_string_literal: true

require_relative "test_helper"

# SEVERAL CARTRIDGES RUNNING AT ONCE, ON DIFFERENT CORES.
#
# Ruby shuts a C extension out of Ractors by default, and this one now says it is safe to
# let in. That is an assertion rather than a check: once it is made Ruby stops protecting
# anything here, so these are what earn it.
#
# The risk is not the emulation itself — each cartridge has its own everything, its screen,
# its sound, its processor. The risk is the handful of things this extension used to keep
# ONE OF, for the whole process, so that the callbacks the emulator fires part-way through
# a frame could find their way back to whoever was running. Those are per thread now, which
# is what makes two cartridges at once possible, and what these tests hold it to.
class TestRactor < Minitest::Test
  include RubyGBAEmulatorTestSupport

  AT_ONCE = 4

  # Ractors say they are experimental every time one is made. Nothing here chooses that.
  def without_the_experimental_warning
    was = Warning[:experimental]
    Warning[:experimental] = false
    yield
  ensure
    Warning[:experimental] = was
  end

  def a_picture
    build_rom("RACTOR", code: "TRAC") do
      screen :bitmap
      clear_screen :blue
      fill_rect 20, 20, 40, 40, :red
      halt
    end
  end

  # A few spots spread over the screen, after a few frames.
  def self.reading(path)
    probe = RubyGBAEmulator.open(path)
    probe.step(6)
    [[0, 0], [30, 30], [120, 80], [239, 159]].map { |x, y| probe.pixel(x, y) }
  end

  def test_a_cartridge_runs_on_a_side_core_and_draws_the_same_picture
    path = a_picture
    alone = TestRactor.reading(path)
    elsewhere = without_the_experimental_warning { Ractor.new(path) { |p| TestRactor.reading(p) }.value }

    assert_equal alone, elsewhere
  end

  def test_several_cartridges_at_once_all_draw_what_one_alone_draws
    path = a_picture
    alone = TestRactor.reading(path)

    together = without_the_experimental_warning do
      Array.new(AT_ONCE) { Ractor.new(path) { |p| TestRactor.reading(p) } }.map(&:value)
    end

    assert_equal [alone] * AT_ONCE, together
  end

  # THE ONE A QUIET CARTRIDGE CANNOT SHOW, and the one that found a real bug.
  #
  # What the emulator says about a cartridge while it runs is kept on that cartridge. To do
  # that, the extension has to record which cartridge is running before handing control to
  # the emulator — and it used to record it in one place for the whole process. Run two at
  # once and the second to start owned it: the first one's complaints went into the second
  # one's list, or were dropped.
  #
  # Nothing about the picture shows this, which is why it needs its own test. Each cartridge
  # here trips over a different invalid instruction, and the emulator prints the instruction
  # it choked on — so every line is signed by the cartridge it came from.
  def test_what_the_emulator_says_about_one_cartridge_stays_with_it
    carts = (1..AT_ONCE).to_h { |n| [n, complains_with(n)] }

    alone = carts.transform_values { |path| TestRactor.complaints(path) }
    together = without_the_experimental_warning do
      carts.transform_values { |path| Ractor.new(path) { |p| TestRactor.complaints(p) } }
           .transform_values(&:value)
    end

    carts.each_key do |n|
      assert_includes alone[n].first, signature(n), "run alone, cartridge #{n} logs its own trouble"
      assert_equal alone[n].first, together[n].first,
                   "run alongside the others, cartridge #{n} still logs only its own"
    end
  end

  def self.complaints(path)
    probe = RubyGBAEmulator.open(path)
    probe.step(8)
    probe.complaints
  end

  # The ARM word that is permanently undefined, carrying +n+ where the emulator will print
  # it back. A cartridge that runs into this complains, over and over, for as long as it
  # runs — which is what fills its list.
  def bad_word(n) = 0xE7F0_00F0 | (n << 16)

  def signature(n) = format("%08x", bad_word(n))

  def complains_with(n)
    word = bad_word(n)
    build_rom("NOISY#{n}", code: "TN#{n}0"[0, 4]) do
      screen :bitmap
      clear_screen :blue
      entry { 4.times { @bytes << [word].pack("V") } }
      halt
    end
  end
end
