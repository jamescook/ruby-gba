# frozen_string_literal: true

module RubyGBA
  # A bitmap font: a named collection of glyphs plus the metrics to lay them out.
  # Each glyph is a small monochrome bitmap stored as +height+ row-bytes, the low
  # +width+ bits of each byte being one row (MSB = leftmost pixel). Text draws by
  # stamping each character's set pixels; `draw_text`/`draw_number` pick which font
  # renders, via the {Fonts} registry.
  #
  # A font knows how to walk the set pixels of a string (`each_pixel`), how wide a
  # string is (`text_width`), and how many pixels a glyph lights (`glyph_pixels`,
  # used by the draw-cost model). Metrics are fixed per font here — every glyph is
  # +width+×+height+ with a +spacing+ gap; proportional (per-glyph width) fonts are
  # a later refinement.
  class Font
    attr_reader :width, :height, :spacing

    # @param glyphs [Hash{String=>Array<Integer>}] char → +height+ row-bytes
    # @param width [Integer] glyph width in pixels
    # @param height [Integer] glyph height in pixels
    # @param spacing [Integer] blank pixels between characters
    # @param fold [Symbol, nil] :upper to look glyphs up upcased (an uppercase-only
    #   font renders "abc" as "ABC"); nil to look them up exactly
    def initialize(glyphs:, width:, height:, spacing: 1, fold: nil)
      @glyphs = glyphs
      @width = width
      @height = height
      @spacing = spacing
      @fold = fold
    end

    # Pixels advanced per character: the glyph plus the gap after it.
    def cell_w
      @width + @spacing
    end

    # The row-bytes for a character, or nil if this font has no such glyph.
    def glyph(char)
      @glyphs[@fold == :upper ? char.upcase : char]
    end

    # Yield (dx, dy) for every set pixel of +text+, relative to its top-left origin.
    # Characters the font lacks are skipped, and clip in the caller's set_pixel — the
    # same edge-safety as any draw.
    def each_pixel(text)
      text.each_char.with_index do |ch, ci|
        rows = glyph(ch) or next
        base_x = ci * cell_w
        rows.each_with_index do |row, y|
          @width.times { |x| yield base_x + x, y if (row >> (@width - 1 - x)) & 1 == 1 }
        end
      end
    end

    # Rendered width of +text+ in pixels (no trailing gap).
    def text_width(text)
      return 0 if text.empty?

      (text.length * cell_w) - @spacing
    end

    # How many pixels a single character lights — what the cost model charges for
    # plotting it. 0 for a character the font lacks (nothing is drawn).
    def glyph_pixels(char)
      rows = glyph(char) or return 0
      rows.sum { |row| (0...@width).count { |x| (row >> (@width - 1 - x)) & 1 == 1 } }
    end

    # Total lit pixels a string draws.
    def text_pixels(text)
      text.each_char.sum { |ch| glyph_pixels(ch) }
    end

    # The most any one of +chars+ lights — the worst-case cost of drawing a single
    # run-time-chosen character (a digit field draws one of 0..9).
    def max_glyph_pixels(chars)
      chars.map { |c| glyph_pixels(c) }.max || 0
    end

    # Collects glyphs drawn as ASCII art and builds a {Font} — the machine behind the
    # `font :name do … end` verb, the sibling of how `image` takes ASCII art. Inside
    # the block, `glyph "A", art` maps a character to a small bitmap; a lit pixel is
    # the +on+ character (default "#"), anything else is blank. Every glyph must be
    # the same size (fixed metrics), so a ragged or odd-sized glyph is a friendly
    # error as the font is built.
    class Definition
      def initialize(name, on: "#")
        @name = name
        @on = on
        @glyphs = {}
        @width = nil
        @height = nil
      end

      # Add a glyph for +char+ from a block of art (rows of +on+/other characters).
      def glyph(char, art)
        rows = art.to_s.each_line.map(&:chomp).reject(&:empty?)
        raise ArgumentError, "font :#{@name} glyph #{char.inspect} has no art" if rows.empty?

        widths = rows.map(&:length).uniq
        unless widths.size == 1
          raise ArgumentError,
                "font :#{@name} glyph #{char.inspect} has ragged rows (#{widths.sort.join(', ')} wide) — " \
                "every row of a glyph must be the same length"
        end
        fix_size!(char, widths.first, rows.size)
        @glyphs[char] = rows.map { |row| row_byte(row) }
      end

      # Build the finished, registerable font.
      def to_font(spacing:, fold:)
        raise ArgumentError, "font :#{@name} defines no glyphs" if @glyphs.empty?

        Font.new(glyphs: @glyphs, width: @width, height: @height, spacing: spacing, fold: fold)
      end

      private

      # Pin the font's size to the first glyph; every later glyph must match, since a
      # fixed-metrics font lays every character out on the same grid.
      def fix_size!(char, width, height)
        @width ||= width
        @height ||= height
        return if width == @width && height == @height

        raise ArgumentError,
              "font :#{@name} glyph #{char.inspect} is #{width}x#{height}, but the font is " \
              "#{@width}x#{@height} — every glyph must be the same size"
      end

      # One art row → its row-byte: bit (width-1-x) set where column x holds the
      # +on+ character, matching how {Font#each_pixel} reads a row back.
      def row_byte(row)
        byte = 0
        @width.times { |x| byte |= 1 << (@width - 1 - x) if row[x] == @on }
        byte
      end
    end

    # rubocop:disable Layout/ExtraSpacing
    # The built-in 5x7 uppercase glyphs. Each row is 5 bits: bit 4 (0x10) = leftmost
    # column, bit 0 = rightmost, so 0b10101 lights columns 0, 2, 4.
    DEFAULT_GLYPHS = {
      "A" => [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
      "B" => [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
      "C" => [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
      "D" => [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
      "E" => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
      "F" => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
      "G" => [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E],
      "H" => [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
      "I" => [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
      "J" => [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
      "K" => [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
      "L" => [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
      "M" => [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
      "N" => [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
      "O" => [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
      "P" => [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
      "Q" => [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
      "R" => [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
      "S" => [0x0E, 0x11, 0x10, 0x0E, 0x01, 0x11, 0x0E],
      "T" => [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
      "U" => [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
      "V" => [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
      "W" => [0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11],
      "X" => [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
      "Y" => [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
      "Z" => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
      "0" => [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
      "1" => [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
      "2" => [0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F],
      "3" => [0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E],
      "4" => [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
      "5" => [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
      "6" => [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
      "7" => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
      "8" => [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
      "9" => [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
      " " => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
      "!" => [0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04],
      "." => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04],
      ":" => [0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00],
      "-" => [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
    }.freeze

    # A compact 3x5 numeric font — half the footprint, for a tight HUD. Each row is
    # 3 bits (bit 2 = leftmost). Digits only; a different SIZE than the default, so
    # picking it visibly changes a number's box (and its draw cost).
    TINY_GLYPHS = {
      "0" => [0b111, 0b101, 0b101, 0b101, 0b111],
      "1" => [0b010, 0b110, 0b010, 0b010, 0b111],
      "2" => [0b111, 0b001, 0b111, 0b100, 0b111],
      "3" => [0b111, 0b001, 0b111, 0b001, 0b111],
      "4" => [0b101, 0b101, 0b111, 0b001, 0b001],
      "5" => [0b111, 0b100, 0b111, 0b001, 0b111],
      "6" => [0b111, 0b100, 0b111, 0b101, 0b111],
      "7" => [0b111, 0b001, 0b010, 0b010, 0b010],
      "8" => [0b111, 0b101, 0b111, 0b101, 0b111],
      "9" => [0b111, 0b101, 0b111, 0b001, 0b111],
      " " => [0b000, 0b000, 0b000, 0b000, 0b000],
    }.freeze
    # rubocop:enable Layout/ExtraSpacing
  end
end
