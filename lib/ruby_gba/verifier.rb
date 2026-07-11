# frozen_string_literal: true

module RubyGBA
  # Loads a ROM in mGBA and reads back actual rendered pixels.
  #
  # This is the definitive answer to "did my ROM actually draw anything?"
  # Instead of squinting at an emulator window, assert exact pixel values.
  #
  # Requires gemba to be available (loads Gemba::Core).
  #
  # @example Verify a pixel
  #   rom = RubyGBA.build("TEST", code: "BTST", maker: "01") do
  #     display :bitmap
  #     pixel 120, 80, :red
  #     halt
  #   end
  #
  #   v = RubyGBA::Verifier.new(rom)
  #   v.pixel(120, 80)        # => { r: 248, g: 0, b: 0 }
  #   v.pixel_gba(120, 80)    # => 0x001F (15-bit GBA color)
  #   v.red?(120, 80)         # => true
  #   v.black?(0, 0)          # => true (no pixel drawn there)
  #
  # @example Check a region
  #   v.all_black?                        # => false (we drew a pixel)
  #   v.region_color?(80, 50, 80, 60, :blue)  # all blue in rect?
  class Verifier
    include Constants

    # @param rom [RubyGBA::ROM] a finalized ROM
    # @param frames [Integer] how many frames to run before reading pixels (default: 2)
    def initialize(rom, frames: 2)
      @rom = rom
      @frames = frames
      @pixels = nil
      @width = SCREEN_WIDTH
      @height = SCREEN_HEIGHT
      load_mgba!
    end

    # Get the 8-bit RGB color at a screen coordinate.
    # @return [Hash] { r:, g:, b: } with 0-255 values
    def pixel(x, y)
      ensure_rendered!
      validate_coords!(x, y)
      idx = (y * @width + x) * 4
      # mGBA native format is XBGR8 (0xXXBBGGRR) — R in low byte
      r = @pixels.getbyte(idx)
      g = @pixels.getbyte(idx + 1)
      b = @pixels.getbyte(idx + 2)
      { r: r, g: g, b: b }
    end

    # Get the 15-bit GBA color at a screen coordinate.
    # Quantizes 8-bit channels back to 5-bit for easy comparison
    # with GBA color constants.
    # @return [Integer] 15-bit BGR555 color
    def pixel_gba(x, y)
      c = pixel(x, y)
      (c[:r] >> 3) | ((c[:g] >> 3) << 5) | ((c[:b] >> 3) << 10)
    end

    # Check if a pixel matches a named color (within GBA 5-bit precision).
    # @param x [Integer] screen x
    # @param y [Integer] screen y
    # @param color [Symbol, Integer] color name or 15-bit value
    # @return [Boolean]
    def pixel_is?(x, y, color)
      expected = Color.resolve(color)
      pixel_gba(x, y) == expected
    end

    # Convenience color checks
    def black?(x, y) = pixel_is?(x, y, :black)
    def white?(x, y) = pixel_is?(x, y, :white)
    def red?(x, y)   = pixel_is?(x, y, :red)
    def green?(x, y) = pixel_is?(x, y, :green)
    def blue?(x, y)  = pixel_is?(x, y, :blue)

    # Check if the entire screen is black (nothing rendered).
    def all_black?
      ensure_rendered!
      @pixels.bytes.each_slice(4).all? { |r, g, b, _| r == 0 && g == 0 && b == 0 }
    end

    # Check if every pixel in a rectangle matches a color.
    # @return [Boolean]
    def region_color?(x, y, w, h, color)
      expected = Color.resolve(color)
      h.times do |dy|
        w.times do |dx|
          return false unless pixel_gba(x + dx, y + dy) == expected
        end
      end
      true
    end

    # Find the first pixel that doesn't match the expected color in a region.
    # Useful for debugging — tells you exactly where the mismatch is.
    # @return [Hash, nil] { x:, y:, expected:, actual: } or nil if all match
    def region_mismatch(x, y, w, h, color)
      expected = Color.resolve(color)
      h.times do |dy|
        w.times do |dx|
          px = x + dx
          py = y + dy
          actual = pixel_gba(px, py)
          if actual != expected
            return { x: px, y: py,
                     expected: format("0x%04X", expected),
                     actual: format("0x%04X", actual),
                     actual_rgb: pixel(px, py) }
          end
        end
      end
      nil
    end

    # Dump a text grid showing what colors are on screen.
    # Each character represents an 8x8 tile area.
    # @return [String] visual map of the screen
    def screen_map(tile_size: 8)
      ensure_rendered!
      lines = []
      (@height / tile_size).times do |ty|
        row = +""
        (@width / tile_size).times do |tx|
          # Sample center of each tile
          sx = tx * tile_size + tile_size / 2
          sy = ty * tile_size + tile_size / 2
          c = pixel_gba(sx, sy)
          row << color_char(c)
        end
        lines << row
      end
      lines.join("\n")
    end

    # Summary report of what's on screen.
    # @return [String]
    def report
      ensure_rendered!
      lines = []
      lines << "=== Frame Verifier Report ==="
      lines << "  Frames rendered: #{@frames}"

      # Count unique colors
      colors = Hash.new(0)
      (@height).times do |y|
        (@width).times do |x|
          colors[pixel_gba(x, y)] += 1
        end
      end

      total = @width * @height
      lines << "  Unique colors: #{colors.size}"
      colors.sort_by { |_, count| -count }.first(10).each do |color, count|
        pct = (count * 100.0 / total).round(1)
        name = color_name(color)
        lines << "    0x#{format('%04X', color)} #{name}: #{count} pixels (#{pct}%)"
      end

      lines << "  Screen map (8x8 tiles):"
      screen_map.each_line { |l| lines << "    #{l}" }

      lines.join("\n")
    end

    private

    def load_mgba!
      begin
        require "gemba/core"  # Ruby class shell
        require "gemba_ext"   # C extension with actual methods
      rescue LoadError => e
        raise LoadError, "Verifier requires gemba (gem install gemba). Original error: #{e.message}"
      end
    end

    def ensure_rendered!
      return if @pixels

      # Write ROM to a temp file, load in mGBA, run frames, read pixels
      require "tempfile"
      Tempfile.create(["verify", ".gba"]) do |f|
        @rom.write(f.path)
        core = Gemba::Core.new(f.path)
        @frames.times { core.run_frame }
        @pixels = core.video_buffer
        core.destroy
      end
    end

    def validate_coords!(x, y)
      raise ArgumentError, "x=#{x} out of range (0-#{@width - 1})" unless (0...@width).cover?(x)
      raise ArgumentError, "y=#{y} out of range (0-#{@height - 1})" unless (0...@height).cover?(y)
    end

    def color_char(gba_color)
      case gba_color
      when 0x0000 then "."  # black
      when 0x7FFF then "#"  # white
      when 0x001F then "R"  # red
      when 0x03E0 then "G"  # green
      when 0x7C00 then "B"  # blue
      when 0x03FF then "Y"  # yellow
      when 0x7FE0 then "C"  # cyan
      when 0x7C1F then "M"  # magenta
      else "?"              # other
      end
    end

    def color_name(gba_color)
      Color::PRESETS.each do |name, val|
        return "(#{name})" if val == gba_color
      end
      ""
    end
  end
end
