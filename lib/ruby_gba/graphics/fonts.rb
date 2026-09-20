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
        # Add (or replace) a font every program in this process can draw with. Returns it.
        #
        # THIS IS NOT WHERE A GAME'S OWN FONT GOES. A font a program declares with the
        # `font` verb belongs to that program and rides on it — see Nodes::Program. What is
        # in here is the two the framework ships, and anything a plugin pack adds as it
        # loads: fonts that are genuinely everybody's.
        #
        # The table is replaced rather than changed in place, and the font is frozen on the
        # way in, because a game may build on several cores at once and a worker can read a
        # table like this one only while nothing in it can still change. That works because
        # everything in here is registered as the library loads.
        def register(name, font)
          @registry = @registry.merge(name => Ractor.make_shareable(font)).freeze
          font
        end

        # One of the fonts that ship, by name, or nil.
        #
        # A GAME'S OWN FONT IS NOT IN HERE and is not found by either of these. A font a
        # program declares belongs to that program and rides in its tree, so the thing that
        # knows about both kinds is {IR::FontTable}, and that is what everything drawing
        # text goes through. These two are about the fonts that ship.
        def find(name) = @registry[name]

        # The same, as a friendly error rather than a nil when there is no such font — for
        # a caller naming one of the built-ins directly.
        def get(name)
          find(name) ||
            raise(ArgumentError, "unknown font #{name.inspect} — the fonts that ship are #{names.join(', ')}")
        end

        # Every font name that ships.
        def names = @registry.keys

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
