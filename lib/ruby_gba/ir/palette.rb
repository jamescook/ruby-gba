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

      # The table has 256 slots. Slot 0 is reserved for black so that an all-zero
      # (freshly cleared, never-painted) screen reads as black for free — the same
      # "empty screen is black" behavior the direct-color display gives you.
      CAPACITY = 256
      BLACK = 0x0000

      # Build the palette for a program, or raise Palette::Overflow if it names more
      # distinct colors than fit.
      def self.build(program)
        new(program)
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

      def initialize(program)
        distinct = collect(program).uniq # first-seen order, deduped by resolved value
        needed = (distinct + [BLACK]).uniq.size # one slot per color, plus reserved black
        raise Overflow, overflow_message(distinct.size) if needed > CAPACITY

        # value(15-bit) => slot. Black goes in first so it lands at 0; the rest take
        # slots in first-seen order.
        @slots = { BLACK => 0 }
        distinct.each { |value| @slots[value] ||= @slots.size }
        @entries = @slots.keys # keys are inserted in slot order, so this is the table
      end

      # Every distinct color the program draws, in first-seen order. Two sources:
      # the draw verbs (which carry an unresolved color spec) and bitmap definitions
      # (whose pixels are already packed 15-bit values). Walks the WHOLE tree, not
      # just statement children, so a color used only in an else-branch (held in an
      # attr, not a child) still gets a slot.
      def collect(program)
        values = []
        program.walk do |node|
          if node.kind == :bitmap
            collect_bitmap(node, values)
          elsif (spec = node[:color])
            values << Color.resolve(spec)
          end
        end
        values
      end

      # A bitmap's pixels are already resolved BGR555 halfwords. Its transparent
      # pixels mean "don't draw" rather than a color, so they don't need a slot —
      # skip them before masking (the transparent marker sets a bit a real color
      # never has, so masking it would turn it into a real color).
      def collect_bitmap(node, values)
        transparent = node[:transparent]
        node[:pixels].unpack("v*").each do |value|
          next if transparent && value == transparent

          values << (value & 0x7FFF)
        end
      end

      def overflow_message(count)
        "This program uses #{count} distinct colors, but the double-buffered display " \
          "shows at most #{CAPACITY} at once (one slot is reserved for a black background, " \
          "leaving #{CAPACITY - 1} for your colors). Reuse colors where you can, or switch to " \
          "the single-buffered display with `display :bitmap` (which allows thousands of colors)."
      end
    end
  end
end
