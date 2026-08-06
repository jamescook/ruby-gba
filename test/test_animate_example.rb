# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "../examples/animate"
require_relative "test_helper"

# The Animate example (examples/animate.rb): a spinning coin (a flipbook `sprite`
# with frames:/rate:) you can also walk around. This confirms the example itself is
# valid and renders; that the flipbook actually cycles over time is pinned in
# test_sprite_animation.rb.
class TestAnimateExample < Minitest::Test
  include GembaSupport

  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  # The coin's centre column is gold on every frame of the spin (only its width
  # changes), so it's a stable point to find it.
  CENTRE = [119, 79].freeze

  def test_it_builds_a_rom
    assert_operator Animate.build_rom(err: StringIO.new).size, :>, 0, "the built ROM should be non-empty"
  end

  def test_the_coin_renders
    s = Reference.new.run(Animate.program, max_steps: 200).screen
    assert_equal Color.resolve(:yellow), s.pixel(*CENTRE), "the coin renders in the middle"
  end

  def test_the_coin_renders_on_the_console
    rom = ROM.assemble(GBA.new.lower(Animate.program), title: "ANIMATE", code: "BANM", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3)
    assert v.pixel_is?(*CENTRE, :yellow), "the coin renders on hardware, got 0x#{format('%04X', v.pixel_gba(*CENTRE))}"
  end
end
