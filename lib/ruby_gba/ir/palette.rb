# frozen_string_literal: true

module RubyGBA
  module IR
    # The auto-managed color palette for indexed bitmap display.
    #
    # Some displays don't store a full color in every pixel. Instead each pixel is
    # a small number — an *index* — that picks a color out of a shared 256-entry
    # table (the palette). It's a memory trick: one byte per pixel instead of two,
    # which is what leaves room for two full screens and makes tear-free
    # double-buffering possible. The catch is a hard ceiling of 256 distinct colors
    # on screen at once.
    #
    # The framework's promise is that a game author never has to know any of that:
    # they keep naming colors (`clear_screen :navy`, `fill_rect ..., :gold`) and the
    # machinery builds the table for them. This pass is what keeps that promise. It
    # walks a finished program, collects every distinct color it actually uses, and
    # assigns each one a table slot. A backend that targets an indexed display then
    # reads two things off it: #entries, the table to upload, and #index_of(color),
    # the number to write for each pixel of a given color.
    #
    # This is pure, target-agnostic analysis — it inspects the IR and produces a
    # color-to-slot mapping, nothing machine-specific. Where that table physically
    # lives, and how a pixel byte gets written, is the backend's concern.
    class Palette
      # Raised when a program uses more distinct colors than the table can hold.
      # A friendly build-time error, not a silent failure.
      class Overflow < StandardError; end

      # Raised when a program supplies its own table and then draws with a color that
      # is not in it.
      class Missing < StandardError; end

      # Raised when two screens supply different tables. The display has one.
      class Conflict < StandardError; end

      # The table has 256 slots. Slot 0 is reserved for black so that an all-zero
      # (freshly cleared, never-painted) screen reads as black for free — the same
      # "empty screen is black" behavior the direct-color display gives you.
      CAPACITY = 256
      BLACK = 0x0000

      # Build the palette for a program, or raise Palette::Overflow if it names more
      # distinct colors than fit.
      #
      # +scopes+ narrows what's collected to a given set of statement subtrees —
      # the backend passes the buffered scenes only, since the palette exists for
      # the indexed double-buffered screen and a direct-color scene needs no slots.
      # Omitted, it collects the whole program (handy for inspecting a program's
      # colors in isolation).
      def self.build(program, scopes: nil)
        new(program, scopes)
      end

      # Slot for a color the program uses. +spec+ is anything the author could have
      # written — a name, a hex string, a raw value — resolved the same way the draw
      # verbs resolve it, so `:green`, `0x03E0`, and `"#00F800"` all find one slot.
      # Black is always present; any other color the program never used is a caller
      # bug (the pass would have collected a color that's really drawn), so it's a
      # clear error rather than a wrong index.
      def index_of(spec)
        value = Color.resolve(spec)
        @slots.fetch(value) do
          raise ArgumentError,
                "color #{spec.inspect} is not in the palette — this program never draws it"
        end
      end

      # The raw 15-bit color at a slot (what a backend uploads for that entry).
      def color_at(index)
        @entries.fetch(index)
      end

      # A picture as palette numbers: one byte a pixel, each the slot its color sits in.
      #
      # The indexed screen holds a number per pixel where every picture in the framework holds
      # a whole color, so nothing can be drawn on that screen until this conversion happens.
      # Returns the bytes and the number that means "leave this pixel alone", which is nil for
      # a picture that has no see-through pixels.
      def indices_for(bitmap)
        clear = bitmap.transparent
        marker = clear && transparent_index(bitmap)

        bytes = bitmap.pixels.unpack("v*").map do |value|
          next marker if clear && value == clear

          @slots.fetch(value & 0x7FFF) { raise Missing, unplaceable_message(bitmap, value) }
        end

        [bytes.pack("C*"), marker]
      end

      # A see-through pixel needs a number that is not any slot, since every slot is a real
      # color a drawer would paint. The first number past the end of the table is that, and it
      # exists only while the table has room — a full one leaves nothing to say it with.
      def transparent_index(bitmap)
        return @entries.size if @entries.size < CAPACITY

        raise Missing,
              "The picture :#{bitmap.name} has see-through pixels, but the screen's #{CAPACITY} " \
              "colors are all in use, so there is no number left to mean \"leave this pixel " \
              "alone\". Free one color, or draw this picture with no see-through pixels."
      end

      # The table to upload, slot by slot: entries[i] is the 15-bit color at slot i.
      # entries[0] is always black.
      def entries
        @entries.dup
      end

      # How many slots are in use (>= 1, since black always occupies slot 0).
      def size
        @entries.size
      end

      private

      def initialize(program, scopes)
        roots = scopes || [program] # the subtrees to gather colors from
        given = given_entries(program)
        return adopt(given, roots) if given

        distinct = collect(roots).uniq # first-seen order, deduped by resolved value
        needed = (distinct + [BLACK]).uniq.size # one slot per color, plus reserved black
        raise Overflow, overflow_message(distinct.size) if needed > CAPACITY

        # value(15-bit) => slot. Black goes in first so it lands at 0; the rest take
        # slots in first-seen order.
        @slots = { BLACK => 0 }
        distinct.each { |value| @slots[value] ||= @slots.size }
        @entries = @slots.keys # keys are inserted in slot order, so this is the table
      end

      # A table the program brought with it, because its pictures were made against that
      # table and their pixels are numbers picking out of it. Slots are its order, not
      # ours, so nothing may be reordered and nothing may be added — including black,
      # which the derived path reserves at slot 0 and this path leaves entirely to the
      # program (an unpainted screen reads as whatever the program put first).
      #
      # A duplicate color keeps its FIRST slot for drawing, and both slots stay in the
      # table: a real imported palette repeats colors, and dropping the later one would
      # shift every slot after it and break every picture.
      def adopt(given, roots)
        @entries = given
        @slots = {}
        given.each_with_index { |value, slot| @slots[value] ||= slot }

        missing = collect(roots).uniq.reject { |value| @slots.key?(value) }
        raise Missing, missing_message(missing, roots) unless missing.empty?
      end

      # Which picture a color came from, where one did. An unexpected color usually arrives in a
      # picture rather than in something somebody typed, so saying which picture is most of the
      # help — without it the author is hunting a number through their own art.
      def picture_holding(value, roots)
        roots.each do |root|
          root.walk do |node|
            next unless node.kind == :bitmap

            pixels = node.pixels.unpack("v*")
            return node.name if pixels.any? { |p| p != node.transparent && (p & 0x7FFF) == value }
          end
        end
        nil
      end

      # A screen may say which colors it shows. Several scenes may each name a screen,
      # but the display has one table, so two different ones is a contradiction rather
      # than a choice.
      def given_entries(program)
        tables = program.walk.filter_map { |node| node.kind == :screen ? node.colors : nil }.uniq
        raise Conflict, conflict_message(tables) if tables.length > 1

        tables.first
      end

      # Every distinct color the given subtrees draw, in first-seen order. Two
      # sources: the draw verbs (which carry an unresolved color spec) and bitmap
      # definitions (whose pixels are already packed 15-bit values). Walks each
      # subtree WHOLE, not just its statement children, so a color used only in an
      # else-branch (held in an attr, not a child) still gets a slot.
      def collect(roots)
        values = []
        roots.each do |root|
          root.walk do |node|
            if node.kind == :bitmap
              collect_bitmap(node, values)
            elsif node.colored? && node.color
              values << Color.resolve(node.color)
            end
          end
        end
        values
      end

      # A bitmap's pixels are already resolved BGR555 halfwords. Its transparent
      # pixels mean "don't draw" rather than a color, so they don't need a slot —
      # skip them before masking (the transparent marker sets a bit a real color
      # never has, so masking it would turn it into a real color).
      def collect_bitmap(node, values)
        transparent = node.transparent
        node.pixels.unpack("v*").each do |value|
          next if transparent && value == transparent

          values << (value & 0x7FFF)
        end
      end

      # A picture is where an unexpected color usually comes from, because nobody typed it —
      # so say which picture, not just which color.
      def unplaceable_message(bitmap, value)
        "The picture :#{bitmap.name} holds the color #{name_for(value & 0x7FFF)}, which the " \
          "screen does not show. A screen given `colors:` shows those colors and no others, so " \
          "either add this one to that list or use a picture drawn from the colors already in it."
      end

      def missing_message(missing, roots)
        named = missing.first(6).map { |value| with_source(value, roots) }.join(", ")
        more = missing.length > 6 ? ", and #{missing.length - 6} more" : ""
        one = missing.length == 1
        "This program draws with #{one ? 'a color' : "#{missing.length} colors"} the screen was " \
          "not given: #{named}#{more}. A screen given `colors:` shows those colors and no others. " \
          "Add #{one ? 'it' : 'them'} to that list, or draw with a color that is already in it."
      end

      def with_source(value, roots)
        picture = picture_holding(value, roots)
        picture ? "#{name_for(value)} (in the picture :#{picture})" : name_for(value)
      end

      # Say :magenta rather than #7C1F where the color has a name people write.
      def name_for(value)
        @names ||= Color::PRESETS.to_h { |name, resolved| [resolved, name.inspect] }
        @names.fetch(value) { format("#%04X", value) }
      end

      def conflict_message(tables)
        "Two screens were given different colors (#{tables.map(&:length).join(' and ')} of them). " \
          "The display holds one table of colors at a time, so every screen must be given the same " \
          "list. Give one list to all of them."
      end

      def overflow_message(count)
        "This program uses #{count} distinct colors, but the double-buffered display " \
          "shows at most #{CAPACITY} at once (one slot is reserved for a black background, " \
          "leaving #{CAPACITY - 1} for your colors). Reuse colors where you can, or switch to " \
          "the single-buffered screen with `screen :bitmap` (which allows thousands of colors)."
      end
    end
  end
end
