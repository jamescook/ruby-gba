# frozen_string_literal: true

module RubyGBA
  # Loads a ROM in mGBA and reads back actual rendered pixels.
  #
  # This is the definitive answer to "did my ROM actually draw anything?"
  # Instead of squinting at an emulator window, assert exact pixel values.
  #
  # Requires gemba-core to be available (loads GembaCore::Core) — the headless
  # libmgba probe vendored under gemba-core/ in this repo.
  #
  # @example Verify a pixel
  #   rom = RubyGBA.build("TEST", code: "BTST", maker: "01") do
  #     screen :bitmap
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
    # @param keys [Integer, #call, nil] held-button input for each frame — an
    #   active-high bitmask (bit per button, matching KEY_*), or a callable given
    #   the frame number returning one. nil means no buttons held.
    # @param vars [Hash{Symbol=>Integer}, nil] variable name → IWRAM address, from the
    #   backend that lowered the ROM (backend.var_addresses) — lets {#var} read a
    #   variable's value back from memory after the run.
    def initialize(rom, frames: 2, keys: nil, vars: nil)
      @rom = rom
      @frames = frames
      @keys = keys
      @var_addresses = vars
      @pixels = nil
      @audio = nil
      @width = SCREEN_WIDTH
      @height = SCREEN_HEIGHT
      Emulator.load! # fail fast if the emulator backend isn't built
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

    # The whole rendered frame as 15-bit GBA colors, row-major (index = y*240 + x).
    #
    # {#pixel_gba} answers "what color is this one pixel?"; this answers "what does
    # the whole screen look like?" in one pass, which is what a frame-to-frame
    # comparison needs — asking pixel by pixel would mean 38,400 separate reads.
    # The values line up with the reference interpreter's own framebuffer dump, so
    # the two backends' pictures can be compared directly.
    # @return [Array<Integer>] 240*160 colors in BGR555
    def frame_gba
      ensure_rendered!
      # mGBA gives us one 32-bit word per pixel as XBGR8 (0xXXBBGGRR): red in the
      # low byte, then green, then blue. The GBA itself stores 5 bits per channel,
      # so shift each 8-bit channel back down to the 15-bit color the ROM asked for.
      @pixels.unpack("V*").map! do |word|
        r = word & 0xFF
        g = (word >> 8) & 0xFF
        b = (word >> 16) & 0xFF
        (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)
      end
    end

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

    # --- memory ---
    #
    # Read values back out of the running console, not just the screen. gemba reads
    # the GBA bus directly, so a hardware test can assert run-time STATE — a variable
    # a program computed, or a hardware register like VCOUNT — the same way it asserts
    # pixels. Reads happen at the final frame boundary (after the frames have run).

    # Read a 32-bit word off the GBA bus at +address+ — an IWRAM variable, or a
    # memory-mapped register. (VCOUNT, the current scanline, is a 16-bit register at
    # 0x04000006; use {#mem16} for it.)
    def mem32(address)
      ensure_rendered!
      @core.bus_read32(address)
    end

    # Read a 16-bit halfword off the GBA bus at +address+.
    def mem16(address)
      ensure_rendered!
      @core.bus_read16(address)
    end

    # Read a single byte off the GBA bus at +address+.
    def mem8(address)
      ensure_rendered!
      @core.bus_read8(address)
    end

    # Read a program variable's value from IWRAM, by name. Needs the variable-address
    # map from the backend that lowered the ROM — construct the Verifier with
    # `vars: backend.var_addresses`. This is how a test asserts what a program
    # actually computed on real hardware.
    def var(name)
      unless @var_addresses
        raise ArgumentError,
              "no variable map given — build the Verifier with `vars: backend.var_addresses` to read a variable"
      end
      address = @var_addresses[name] ||
                raise(ArgumentError, "unknown variable #{name.inspect} — known: #{@var_addresses.keys.join(', ')}")
      mem32(address)
    end

    # --- audio ---
    #
    # The counterpart to reading pixels: read the sound that actually came out.
    # gemba mixes each frame to stereo PCM and we concatenate the whole run, so
    # these ask "what did the speaker do?" rather than trusting the ROM's bytes.

    # Total absolute amplitude across every PCM sample captured — 0 is perfect
    # silence. A deliberately crude "did any sound come out?" measure that doesn't
    # care about pitch or waveform, only whether the hardware made noise.
    def audio_energy
      ensure_rendered!
      @audio.unpack("s<*").sum(&:abs)
    end

    # True when the run produced no sound at all (energy exactly 0).
    def silent?
      audio_energy.zero?
    end

    # True when the run produced any sound.
    def sound?
      !silent?
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

    def ensure_rendered!
      return if @pixels

      # Write ROM to a temp file, load in mGBA, run frames, read back the final
      # frame's pixels and the whole run's audio. Audio drains per frame, so we
      # concatenate each frame's chunk to hear the entire run, not just the last.
      require "tempfile"
      # Keep the core (and its ROM file) alive on the instance rather than tearing
      # them down here: memory reads (#mem32 / #var) run against the same core after
      # the frames, at the final frame boundary. Both are released when this Verifier
      # is garbage-collected.
      @tempfile = Tempfile.new(["verify", ".gba"])
      @tempfile.binmode
      @rom.write(@tempfile.path)
      @tempfile.flush
      @core = Emulator.open(@tempfile.path)
      @audio = +"".b
      @frames.times do |frame|
        @core.set_keys(keys_for(frame)) if @keys
        @core.run_frame
        @audio << @core.audio_buffer
      end
      @pixels = @core.video_buffer
    end

    # The held-button bitmask for a given frame (0 if none configured).
    def keys_for(frame)
      return 0 unless @keys

      @keys.respond_to?(:call) ? @keys.call(frame) : @keys
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
