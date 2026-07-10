# frozen_string_literal: true

module RubyGBA
  # GBA color utilities.
  #
  # The GBA uses 15-bit color: 5 bits red, 5 bits green, 5 bits blue.
  # Format: 0bBBBBBGGGGGRRRRR (blue in high bits, red in low bits).
  # Each channel ranges from 0-31.
  module Color
    # Named color presets — common colors in GBA 15-bit format.
    PRESETS = {
      black:   0x0000,
      white:   0x7FFF,
      red:     0x001F,
      green:   0x03E0,
      blue:    0x7C00,
      yellow:  0x03FF,  # red + green
      cyan:    0x7FE0,  # green + blue
      magenta: 0x7C1F,  # red + blue
      orange:  0x02BF,  # r=31, g=10, b=0 (approx)
      gray:    0x2D6B,  # r=11, g=11, b=11
    }.freeze

    module_function

    # Pack RGB channels (0-31 each) into a 15-bit GBA color.
    # Raises if any channel is out of the 0-31 range — this catches
    # the common mistake of passing 8-bit (0-255) values. Use
    # {from_hex} or {rgb8} if you're working with 8-bit color.
    #
    # @example
    #   Color.rgb(31, 0, 0)  # => bright red
    #   Color.rgb(0, 31, 0)  # => bright green
    def rgb(r, g, b)
      validate_channel!(r, "red")
      validate_channel!(g, "green")
      validate_channel!(b, "blue")
      r | (g << 5) | (b << 10)
    end

    # Pack 8-bit RGB channels (0-255 each) into a 15-bit GBA color.
    # Automatically downsamples to 5-bit per channel.
    #
    # @example
    #   Color.rgb8(255, 0, 0)  # => bright red (same as rgb(31, 0, 0))
    def rgb8(r, g, b)
      validate_channel8!(r, "red")
      validate_channel8!(g, "green")
      validate_channel8!(b, "blue")
      rgb(r >> 3, g >> 3, b >> 3)
    end

    # Convert a 24-bit hex color string to 15-bit GBA color.
    # Automatically downsamples from 8-bit (0-255) to 5-bit (0-31) per channel.
    #
    # @example
    #   Color.from_hex("#FF0000")  # => bright red
    #   Color.from_hex("00FF00")   # => bright green
    def from_hex(hex)
      hex = hex.delete_prefix("#")
      raise ArgumentError, "invalid hex color: #{hex}" unless hex.match?(/\A[0-9A-Fa-f]{6}\z/)

      r8 = hex[0, 2].to_i(16)
      g8 = hex[2, 2].to_i(16)
      b8 = hex[4, 2].to_i(16)

      rgb8(r8, g8, b8)
    end

    def validate_channel!(value, name)
      return if (0..31).cover?(value)

      hint = value > 31 ? " (did you mean rgb8 for 8-bit values?)" : ""
      raise ArgumentError, "#{name} channel #{value} out of range (0-31)#{hint}"
    end

    def validate_channel8!(value, name)
      return if (0..255).cover?(value)

      raise ArgumentError, "#{name} channel #{value} out of range (0-255)"
    end

    # Resolve a color from multiple input types.
    #
    # @param value [Symbol, String, Integer] color value
    # @return [Integer] 15-bit GBA color
    #
    # @example
    #   Color.resolve(:red)        # => named preset
    #   Color.resolve("#FF8800")   # => hex string
    #   Color.resolve(0x001F)      # => raw 15-bit value (passed through)
    def resolve(value)
      case value
      when Integer
        value & 0x7FFF
      when Symbol
        PRESETS.fetch(value) { raise ArgumentError, "unknown color: #{value}. Known: #{PRESETS.keys.join(', ')}" }
      when String
        from_hex(value)
      else
        raise ArgumentError, "expected Integer, Symbol, or hex String, got #{value.class}"
      end
    end
  end
end
