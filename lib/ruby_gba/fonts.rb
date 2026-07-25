# frozen_string_literal: true

module RubyGBA
  # The registry of named {Font}s — the way a draw picks which font renders it.
  # `draw_text "HI", x, y, color, font: :tiny` names a font here; the backends and
  # the off-screen guardrail resolve the name through this registry rather than
  # reaching for one hardwired font. It ships two built-ins and a game (or a plugin
  # pack) can `register` its own.
  #
  #   Fonts.register :myfont, Font.new(glyphs: …, width:, height:)
  #   Fonts.names       # => [:default, :tiny, :myfont]
  #   Fonts.get(:tiny)  # => the Font
  module Fonts
    @registry = {}

    class << self
      # Add (or replace) a named font. Returns the font.
      def register(name, font)
        @registry[name] = font
      end

      # The font registered under +name+, or a friendly error naming the ones that
      # exist (an unknown font is almost always a typo).
      def get(name)
        @registry.fetch(name) do
          raise ArgumentError, "unknown font #{name.inspect} — the fonts are #{names.join(', ')}"
        end
      end

      # Every registered font name.
      def names
        @registry.keys
      end

      def registered?(name)
        @registry.key?(name)
      end

      # The font a draw uses when it doesn't ask for one.
      def default
        get(:default)
      end
    end

    # The built-ins: the 5x7 uppercase font (what text has always used) and a compact
    # 3x5 numeric font for tight HUDs.
    register(:default, Font.new(glyphs: Font::DEFAULT_GLYPHS, width: 5, height: 7, fold: :upper))
    register(:tiny, Font.new(glyphs: Font::TINY_GLYPHS, width: 3, height: 5))
  end
end
