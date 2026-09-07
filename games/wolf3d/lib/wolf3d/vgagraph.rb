# frozen_string_literal: true

module Wolf3D
  # VGAGRAPH: the menu art, the title screens, the status bar's steel plate and the two
  # alphabets the game writes with.
  #
  # THREE FILES THAT ONLY WORK TOGETHER, and each holds a piece nothing else has.
  # VGADICT is the packing tree. VGAHEAD is where each chunk starts — in THREE-byte
  # offsets, not four, which is the detail that costs an afternoon if nobody writes it
  # down. VGAGRAPH is the packed chunks themselves.
  #
  # A chunk's first four bytes say how big it comes out; the packing does not carry its
  # own length, so that number is what stops the decoder. The chunks are laid out the
  # same way in every release: the picture table, then the two fonts, then the pictures.
  #
  # WHAT IS DERIVED RATHER THAN LOOKED UP. How many chunks there are comes from the size
  # of VGAHEAD, and how many pictures there are comes from the picture table's own
  # length — four bytes a picture, a width and a height. So nothing here carries a table
  # of numbers per release except the NAMES, which really are different from one release
  # to the next.
  #
  # A PICTURE IS STORED IN FOUR PLANES, because the display it was drawn for held its
  # memory that way: a card with four banks side by side, each holding every fourth
  # column. So the picture arrives as four quarter-width pictures stacked, and putting
  # them back together is the one unscrambling this file needs.
  class Vgagraph
    # How long a chunk comes out, written in front of it.
    LENGTH_BYTES = 4
    # VGAHEAD stores three-byte offsets. The last one is the end of the file.
    OFFSET_BYTES = 3
    # A chunk that was never made. Its offset is all ones.
    ABSENT = 0xFFFFFF
    DICTIONARY_BYTES = Codec::Huffman::DICTIONARY_BYTES

    # The layout every release shares: the picture table, then two fonts, then pictures.
    PICTURE_TABLE = 0
    FIRST_FONT = 1
    FONTS = 2
    FIRST_PICTURE = FIRST_FONT + FONTS

    # A width and a height per picture, each a 16-bit number.
    SIZE_BYTES = 4
    PLANES = 4

    # WHAT THE PICTURES ARE CALLED, which is the one thing that really does differ from
    # one release to the next — the numbers come from the order the artists' tool packed
    # them in, and each release packed a different set.
    #
    # Read off the six-episode release itself rather than copied from a header. The sizes
    # narrow it down — one 320x40 plate, two 320x200 screens, four 48x24 weapons, ten 8x16
    # numerals, twenty-four 24x32 faces in a row — and then each was drawn out and looked
    # at. The two keys are the same shape and are told apart by their inks: one is drawn
    # out of the palette's yellows and the other out of its greys.
    #
    # The menu's pictures came the same way and were the easier half, because each set has a
    # shape nothing else shares: one pair of 24x16 guns, four 24x32 portraits in a row, six
    # 48x24 numerals in a row. Drawn out, the pair really is a gun and the same gun firing,
    # and the four portraits really are one man getting grimmer.
    WL6_NAMES = {
      # THE MENU'S OWN PICTURES, which come before everything the game itself draws with.
      # The heading plate over the rows; the gun that points at the row you are on, and the
      # same gun with its muzzle flashing, which is what makes the selector blink.
      menu_heading: 7,
      menu_gun: 8, menu_gun_firing: 9,
      status_bar: 83,   # the steel plate along the bottom
      title: 84,        # the title screen
      notice: 85,       # the rating box shown before the title
      credits: 86,      # who made it
      high_scores: 87,
      knife: 88, pistol: 89, machine_gun: 90, chain_gun: 91,
      no_key: 92, gold_key: 93, silver_key: 94,
      blank_digit: 95
    }.merge(
      # THE FOUR PORTRAITS OF THE DIFFICULTY SCREEN, in the order the rows go: BJ looking
      # baby-faced, then steadily grimmer, one for each answer to "how tough are you?".
      %i[baby easy normal hard].each_with_index.to_h { |how, n| [:"difficulty_#{how}", 16 + n] }
    ).merge(
      # ...and a big numeral for each episode, drawn beside its name in the episode list.
      (1..6).to_h { |n| [:"episode_#{n}", 26 + n] }
    ).merge((0..9).to_h { |d| [:"digit_#{d}", 96 + d] })
     .merge(
       # Eight health levels, three looks each — the face that watches you, glancing
       # left, ahead and right.
       (1..8).flat_map { |level| %w[a b c].map { |look| :"face_#{level}#{look}" } }
             .each_with_index.to_h { |name, n| [name, 106 + n] }
     ).freeze

    NAMES = { "WL6" => WL6_NAMES }.freeze

    attr_reader :set

    def self.from(game_data)
      new(graph: game_data.read("VGAGRAPH"), dictionary: game_data.read("VGADICT"),
          head: game_data.read("VGAHEAD"), set: game_data.set)
    end

    def initialize(graph:, dictionary:, head:, set: nil)
      @graph = graph
      @set = set
      @tree = build_tree(dictionary)
      @offsets = read_offsets(head)
      check!
      @pictures = {}
      @fonts = {}
    end

    # How many chunks the release holds. The last VGAHEAD entry marks the end of the
    # file rather than a chunk of its own.
    def chunk_count = @offsets.length - 1

    def picture_count = sizes.length

    # The width and height of a picture, without decoding it.
    def size(which) = sizes.fetch(index_of(which))

    def picture(which)
      n = index_of(which)
      @pictures[n] ||= begin
        width, height = sizes.fetch(n)
        Picture.new(width: width, height: height, planar: chunk(FIRST_PICTURE + n))
      end
    end

    # The alphabets, in the order the release stores them: 0 is the small one the status
    # bar and the menus are written in, 1 the big one the headings use.
    def font(which)
      unless which.between?(0, FONTS - 1)
        raise IndexError, "there is no font #{which}; a release carries #{FONTS}"
      end

      @fonts[which] ||= Font.new(chunk(FIRST_FONT + which))
    end

    def fonts = (0...FONTS).map { |n| font(n) }

    # The names this release knows its pictures by, or none when we have not read that
    # release's order off a copy of it.
    def names = NAMES.fetch(@set, {}).keys

    private

    def sizes
      @sizes ||= chunk(PICTURE_TABLE).unpack("v*").each_slice(2).map { |w, h| [w, h] }
    end

    # A picture by number, or by one of the names this release knows.
    def index_of(which)
      return in_range(which) if which.is_a?(Integer)

      known = NAMES.fetch(@set) do
        raise ArgumentError,
              "the pictures of #{@set} do not have names here. Ask for one by number. " \
              "Names are known for: #{NAMES.keys.join(', ')}."
      end
      known.fetch(which) do
        raise ArgumentError, "there is no picture called #{which.inspect}. " \
                             "#{@set} has: #{known.keys.join(', ')}."
      end
    end

    def in_range(n)
      unless n.between?(0, picture_count - 1)
        raise IndexError, "there is no picture #{n}; this release has #{picture_count}"
      end

      n
    end

    # One chunk, unpacked. Its own first four bytes say how long it comes out.
    def chunk(n)
      from = @offsets.fetch(n) { raise IndexError, "there is no chunk #{n}; this release has #{chunk_count}" }
      raise ArgumentError, "chunk #{n} is not in this release" if from == ABSENT

      packed = @graph[from, next_offset(n) - from].to_s
      length = packed[0, LENGTH_BYTES].to_s.unpack1("V")
      raise ArgumentError, "chunk #{n} is cut short: it is only #{packed.bytesize} bytes" if length.nil?

      @tree.unpack(packed[LENGTH_BYTES..], length)
    end

    # Where the chunk after +n+ starts. A chunk that was never made has no offset of its
    # own, so it is stepped over.
    def next_offset(n)
      at = n + 1
      at += 1 while at < @offsets.length && @offsets[at] == ABSENT
      @offsets.fetch(at) { raise ArgumentError, "chunk #{n} runs off the end of VGAHEAD" }
    end

    def read_offsets(head)
      unless (head.bytesize % OFFSET_BYTES).zero?
        raise ArgumentError,
              "VGAHEAD is #{head.bytesize} bytes, which is not a whole number of " \
              "#{OFFSET_BYTES}-byte offsets. The file is damaged or is not VGAHEAD."
      end

      head.bytes.each_slice(OFFSET_BYTES).map { |low, mid, high| low | (mid << 8) | (high << 16) }
    end

    def build_tree(dictionary)
      unless dictionary.bytesize == DICTIONARY_BYTES
        raise ArgumentError,
              "VGADICT is #{dictionary.bytesize} bytes and must be #{DICTIONARY_BYTES}. " \
              "The file is damaged or is not VGADICT."
      end

      Codec::Huffman::Tree.from_dictionary(dictionary)
    end

    def check!
      unless chunk_count >= FIRST_PICTURE
        raise ArgumentError,
              "VGAHEAD names #{chunk_count} chunks. A release has at least #{FIRST_PICTURE}: " \
              "the picture table and #{FONTS} fonts."
      end

      last = @offsets.reject { |o| o == ABSENT }.max.to_i
      return if last <= @graph.bytesize

      raise ArgumentError,
            "VGAHEAD points at byte #{last} but VGAGRAPH is only #{@graph.bytesize} bytes. " \
            "The two files are from different releases, or one is damaged."
    end

    # A picture, put back together out of its four planes.
    #
    # The display it was drawn for held its memory as four banks side by side, each bank
    # holding every fourth column — so the file holds four quarter-width pictures one
    # after another, and column x of the whole picture lives in bank (x mod 4). Nothing
    # else in this file is scrambled; this is it.
    class Picture
      attr_reader :width, :height

      def initialize(width:, height:, planar:)
        @width = width
        @height = height
        check!(planar)
        @rows = unscramble(planar)
      end

      # Row by row, each a list of palette numbers.
      attr_reader :rows

      def [](x, y) = @rows[y][x]

      # Every pixel in one list, row by row — what a bitmap wants handing to it.
      def pixels = @rows.flatten

      private

      def unscramble(planar)
        quarter = @width / PLANES
        Array.new(@height) do |y|
          Array.new(@width) do |x|
            planar.getbyte(((x % PLANES) * quarter * @height) + (y * quarter) + (x / PLANES))
          end
        end
      end

      def check!(planar)
        unless (@width % PLANES).zero?
          raise ArgumentError,
                "a picture is #{@width} wide, and a width must divide by #{PLANES}. " \
                "The picture table does not match this VGAGRAPH."
        end

        wanted = @width * @height
        return if planar.bytesize == wanted

        raise ArgumentError,
              "a #{@width}x#{@height} picture wants #{wanted} pixels and came out #{planar.bytesize}"
      end
    end

    # An alphabet. Proportional: every character carries its OWN width, and the whole
    # font shares one height.
    #
    # It starts with that height, then where each of the 256 characters begins inside the
    # chunk, then how wide each one is — and a character nobody drew has a width of zero.
    # After all that comes the lettering itself, one byte a pixel, read across the rows;
    # a pixel that is not zero is ink. The colour of the ink is not in here, because the
    # game picks it when it writes.
    class Font
      HEIGHT_BYTES = 2
      CHARACTERS = 256
      LOCATION_BYTES = 2
      HEADER_BYTES = HEIGHT_BYTES + (CHARACTERS * LOCATION_BYTES) + CHARACTERS

      # The characters a font: is likely to be asked for. The rest of what a release
      # carries — the arrows and the cursor the menus draw — is reached by its number.
      PRINTABLE = (32..126)

      attr_reader :height

      def initialize(chunk)
        check!(chunk)
        @chunk = chunk
        @height = chunk[0, HEIGHT_BYTES].unpack1("v")
        @locations = chunk[HEIGHT_BYTES, CHARACTERS * LOCATION_BYTES].unpack("v*")
        @widths = chunk[HEIGHT_BYTES + (CHARACTERS * LOCATION_BYTES), CHARACTERS].bytes
        check_height!
      end

      # Every character code this font actually draws something for.
      def codes = @codes ||= (0...CHARACTERS).select { |c| @widths[c].positive? }

      def width(char) = @widths[code(char)]

      # One character's rows of pixels: 0 where nothing is drawn, the ink's own number
      # where something is. Empty for a character this font does not carry.
      def rows(char)
        c = code(char)
        w = @widths[c]
        return [] if w.zero?

        at = @locations[c]
        Array.new(@height) { |y| @chunk[at + (y * w), w].to_s.bytes }
      end

      # The alphabet as a font can be registered from: each printable character mapped to
      # its rows of pixels. Hand it straight to `font :name, glyphs: ...`.
      def glyphs
        (codes & PRINTABLE.to_a).to_h { |c| [c.chr, rows(c)] }
      end

      private

      def code(char) = char.is_a?(Integer) ? char : char.to_s.bytes.first.to_i

      def check!(chunk)
        return if chunk.bytesize > HEADER_BYTES

        raise ArgumentError,
              "a font is #{chunk.bytesize} bytes and its heading alone is #{HEADER_BYTES}. " \
              "The chunk is cut short, or it is not a font."
      end

      # The lettering after the heading is one byte a pixel, so it has to come to the
      # widths of every character multiplied by the one height. That one sum catches a
      # font read at the wrong offset, which otherwise decodes to plausible rubbish.
      def check_height!
        wanted = @widths.sum * @height
        got = @chunk.bytesize - HEADER_BYTES
        return if wanted == got

        raise ArgumentError,
              "a font #{@height} tall with #{@widths.sum} pixels of width wants #{wanted} " \
              "pixels of lettering and has #{got}. The chunk is not a font."
      end
    end
  end
end
