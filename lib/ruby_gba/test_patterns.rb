# frozen_string_literal: true

module RubyGBA
  # Built-in diagnostic ROM generators.
  #
  # These produce unmistakable visual patterns for quick sanity checks.
  # If you can't see these patterns in mGBA, the problem is in the
  # emulator setup, not your code.
  #
  # @example Build and save a test pattern
  #   rom = RubyGBA::TestPatterns.color_bars
  #   rom.write("/tmp/color_bars.gba")
  #
  # @example Verify rendering pipeline
  #   rom = RubyGBA::TestPatterns.solid_fill(:red)
  #   v = RubyGBA::Verifier.new(rom)
  #   v.red?(120, 80) # => true if rendering works
  module TestPatterns
    module_function

    # Full screen filled with a single color.
    # The most basic test — if this doesn't work, nothing will.
    #
    # @param color [Symbol, Integer] fill color (default: :red)
    # @return [RubyGBA::ROM]
    def solid_fill(color = :red)
      RubyGBA.build("SOLIDFILL", code: "BTSF", maker: "01") do
        screen :bitmap
        fill_rect 0, 0, 240, 160, color
        halt
      end
    end

    # Three vertical stripes: red, green, blue (each 80px wide).
    # Tests that all three color channels render independently.
    #
    # @return [RubyGBA::ROM]
    def color_bars
      RubyGBA.build("COLORBARS", code: "BTCB", maker: "01") do
        screen :bitmap
        fill_rect 0,   0, 80, 160, :red
        fill_rect 80,  0, 80, 160, :green
        fill_rect 160, 0, 80, 160, :blue
        halt
      end
    end

    # Corner markers — small colored squares in each corner.
    # Tests that pixel addressing works at screen boundaries.
    # Red=top-left, Green=top-right, Blue=bottom-left, White=bottom-right.
    #
    # @return [RubyGBA::ROM]
    def corners
      RubyGBA.build("CORNERS", code: "BTCN", maker: "01") do
        screen :bitmap
        size = 20
        fill_rect 0, 0, size, size, :red                                # top-left
        fill_rect 240 - size, 0, size, size, :green                     # top-right
        fill_rect 0, 160 - size, size, size, :blue                      # bottom-left
        fill_rect 240 - size, 160 - size, size, size, :white            # bottom-right
        halt
      end
    end

    # Centered crosshair — helps verify coordinate system.
    # Horizontal and vertical lines through center (120, 80).
    #
    # @return [RubyGBA::ROM]
    def crosshair
      RubyGBA.build("CROSSHAIR", code: "BTCH", maker: "01") do
        screen :bitmap
        # Horizontal line at y=80
        fill_rect 0, 79, 240, 2, :white
        # Vertical line at x=120
        fill_rect 119, 0, 2, 160, :white
        # Center dot
        fill_rect 118, 78, 4, 4, :red
        halt
      end
    end
  end
end
