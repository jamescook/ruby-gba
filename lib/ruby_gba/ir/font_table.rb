# frozen_string_literal: true

module RubyGBA
  module IR
    # WHICH FONT A NAME MEANS TO ONE PROGRAM.
    #
    # A game can draw with two kinds of font: the ones the framework ships, which are
    # everybody's and live in {Graphics::Fonts}, and the ones it declared for itself with
    # `font :heavy do ... end`, which are part of the game and ride in its tree as `font`
    # nodes — the same way a declared picture does.
    #
    # Everything that has to turn a font NAME into a font goes through here: the builder
    # while the program is being written, the off-screen guardrail, the glyph count, the
    # headless interpreter and the two places the GBA backend paints text. So the rule about
    # which one wins is written down once, and a font declared by one game can never be
    # drawn by the next — which is what happened while a declared font went into a table the
    # whole process shared.
    #
    # ASK FOR IT ONCE PER PROGRAM, not once per glyph. Finding the fonts means walking the
    # tree, so a caller that paints thousands of characters gets the table at the top and
    # keeps it. That is the same bargain the palette pass makes for pictures.
    class FontTable
      # The fonts +program+ can draw with. A node will do instead of a program — it answers
      # for the tree it hangs from — which is what a caller holding one statement has.
      def self.of(node) = new(node)

      def initialize(node)
        @declared = declared_in(root_of(node))
      end

      # Did this program declare a font of its own under +name+?
      def declared?(name) = @declared.key?(name)

      # The font +name+ means: one the program declared first, then one the framework ships.
      # A name that is neither is a friendly error naming what there is, since an unknown
      # font is nearly always a typo.
      def get(name)
        found = @declared[name] || Graphics::Fonts.find(name)
        return found if found

        raise ArgumentError, "unknown font #{name.inspect} — the fonts are #{names.join(', ')}"
      end

      # Every name this program can draw with: its own first, then the ones that ship.
      def names = @declared.keys + Graphics::Fonts.names

      private

      def root_of(node)
        node = node.parent while node.respond_to?(:parent) && node.parent
        node
      end

      def declared_in(root)
        return {} unless root.respond_to?(:walk)

        root.walk.each_with_object({}) do |node, found|
          found[node.name] = node.font if node.kind == :font
        end
      end
    end
  end
end
