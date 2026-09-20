# frozen_string_literal: true

module RubyGBA
  module Graphics
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
      @registry = {}.freeze

      class << self
        # Add (or replace) a named font. Returns the font.
        #
        # The registry is replaced rather than changed in place, and the font is frozen on
        # the way in. A registered font is shared by every build in the process, and a game
        # may build from a Ractor — which can read a table like this one only when nothing
        # in it can still change. Registering is a load-time act, so nothing is lost.
        def register(name, font)
          @registry = @registry.merge(name => Ractor.make_shareable(font)).freeze
          font
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

        # Drop every font registered at run time, back to the built-ins — the counterpart
        # of Effects.clear_registered! and Guardrails.clear_registered!, and for the same
        # reason: the registry is per process, so one test's font would otherwise still be
        # there for the next.
        def clear_registered!
          @registry = @registry.slice(*BUILT_IN).freeze
          self
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
      # 3x5 numeric font for tight HUDs. These are the ones clear_registered! keeps.
      BUILT_IN = %i[default tiny].freeze

      register(:default, Font.new(glyphs: Font::DEFAULT_GLYPHS, width: 5, height: 7, fold: :upper))
      register(:tiny, Font.new(glyphs: Font::TINY_GLYPHS, width: 3, height: 5))
    end
  end
end
