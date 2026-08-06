# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The cross-backend contracts that live in the IR core (peers of IR::Int32): the
# button vocabulary and the screen model. Every backend must agree on these, so
# these tests pin the single source of truth and guard the backends against
# quietly drifting from it.
class TestIRContracts < Minitest::Test
  Buttons = RubyGBA::IR::Buttons
  Screen = RubyGBA::IR::Screen

  def test_the_button_vocabulary_is_the_ten_gba_buttons
    assert_equal %i[a b down l left r right select start up], Buttons::NAMES.sort
    assert Buttons.known?(:start)
    refute Buttons.known?(:turbo)
  end

  def test_the_gba_backend_maps_exactly_the_shared_vocabulary
    # The console's name -> key-bit mapping must cover every shared button and no
    # stragglers. If they drift, a valid button would fail to lower (or a bogus
    # one would sneak in a mapping) — this catches that at the seam.
    mapped = RubyGBA::IR::Backends::GBA::BUTTON_BIT.keys
    assert_equal Buttons::NAMES.sort, mapped.sort
  end

  def test_the_screen_size_has_a_single_source_of_truth
    assert_equal 240, Screen::WIDTH
    assert_equal 160, Screen::HEIGHT
    # The GBA hardware constants are an alias for the contract, not a second copy.
    assert_equal Screen::WIDTH, RubyGBA::Constants::SCREEN_WIDTH
    assert_equal Screen::HEIGHT, RubyGBA::Constants::SCREEN_HEIGHT
  end

  def test_the_interpreter_framebuffer_sizes_itself_from_the_contract
    fb = RubyGBA::IR::Backends::Reference::Framebuffer.new
    assert_equal Screen::WIDTH, fb.width
    assert_equal Screen::HEIGHT, fb.height
  end
end
