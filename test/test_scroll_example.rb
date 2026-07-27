# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "../examples/scroll"
require_relative "test_helper"

# The Scroll example (examples/scroll.rb): pan a camera over a tiled world bigger
# than the screen. This confirms the example is valid and the world renders; the
# scrolling and wrapping themselves are pinned in test_background_scroll.rb.
class TestScrollExample < Minitest::Test
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM

  # The lake sits at map cols 12-19, rows 10-14 -> pixels x 96..159, y 80..119, all on
  # screen at the starting (0,0) offset.
  def blue_in_lake?(pixel)
    (100..150).any? { |x| (84..116).any? { |y| pixel.call(x, y) } }
  end

  def test_it_builds_a_rom
    assert_operator Scroll.build_rom(err: StringIO.new).size, :>, 0, "the built ROM should be non-empty"
  end

  def test_the_world_renders
    s = Ruby.new.run(Scroll.program, max_steps: 200).screen
    blue = RubyGBA::Color.resolve(:blue)
    assert blue_in_lake?(->(x, y) { s.pixel(x, y) == blue }), "the lake renders in the middle of the world"
  end

  def test_the_world_renders_on_the_console
    v = assert_gemba_loads_rom(ROM.assemble(GBA.new.lower(Scroll.program), title: "SCROLL", code: "BSCR", maker: "01"),
                               frames: 3)
    assert blue_in_lake?(->(x, y) { v.blue?(x, y) }), "the lake renders on hardware"
  end
end
