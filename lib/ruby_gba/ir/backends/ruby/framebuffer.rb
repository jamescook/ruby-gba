# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Ruby
        # A simulated screen — the Ruby backend's stand-in for the display a real
        # console would draw to. It's just a grid of colors: every cell holds one
        # color directly, and drawing means writing colors into cells. Tests read
        # cells back to assert what a program *would* put on screen, with no
        # emulator and no ROM.
        #
        # The default size, 240x160, is the console's bitmap-mode screen. Writes
        # that fall outside the grid are silently dropped rather than raising or
        # scribbling onto memory — the same edge-safety the DSL promises, so a
        # stray pixel at (999, 999) can never corrupt anything or crash a test.
        class Framebuffer
          # Sized from the shared display contract, not a fresh copy of 240x160.
          WIDTH = Screen::WIDTH
          HEIGHT = Screen::HEIGHT

          attr_reader :width, :height

          # @param fill [Integer] the color every cell starts as (0 reads as black)
          def initialize(width: WIDTH, height: HEIGHT, fill: 0)
            @width = width
            @height = height
            @fill = fill
            @pixels = Array.new(width * height, fill)
          end

          # The color at (x, y). An off-screen coordinate reads as nil — a clear
          # "there is no such pixel" rather than a color that isn't really there.
          def pixel(x, y)
            return nil unless in_bounds?(x, y)

            @pixels[(y * @width) + x]
          end

          # Paint one cell. Off-screen coordinates are dropped (see the class note
          # on edge-safety), so this never raises for a bad (x, y).
          def set_pixel(x, y, color)
            return unless in_bounds?(x, y)

            @pixels[(y * @width) + x] = color
          end

          # Paint a w-by-h rectangle whose top-left is (x, y). Any part hanging off
          # the screen is clipped, because each cell goes through set_pixel.
          def fill_rect(x, y, width, height, color)
            y.upto(y + height - 1) do |py|
              x.upto(x + width - 1) do |px|
                set_pixel(px, py, color)
              end
            end
          end

          # Paint the entire screen one color.
          def clear(color)
            @pixels.fill(color)
          end

          # A flat, row-major copy of every cell — for asserting the whole screen
          # or counting how many cells hold a given color.
          def to_a
            @pixels.dup
          end

          private

          def in_bounds?(x, y)
            x >= 0 && x < @width && y >= 0 && y < @height
          end
        end
      end
    end
  end
end
