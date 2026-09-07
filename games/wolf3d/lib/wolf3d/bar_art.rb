# frozen_string_literal: true

module Wolf3D
  # WOLFENSTEIN'S OWN ART FOR THE BAR ALONG THE BOTTOM, out of VGAGRAPH and ready to hand to
  # the framework.
  #
  # THE FACE IS THE PIECE WITH BEHAVIOUR. There are twenty-four of them — eight for how badly
  # hurt you are, three looks each — and which one to show is worked out as the game runs. That
  # would normally mean the game choosing between twenty-four pictures, which is twenty-four
  # tests and twenty-four copies of a drawing in the cartridge.
  #
  # It does not, because of the same trick the walls use: the faces are laid SIDE BY SIDE in one
  # picture, and a column of that picture is `which_face * width + which_column`. Multiplying is
  # something the game can do, so nothing is chosen at all — the face is drawn by walking its
  # columns out of one wide picture, exactly as a wall is.
  #
  # The keys are ordinary pictures, drawn or not drawn, so they need none of that.
  class BarArt
    # The faces, in the order the release packs them: eight bands of health, worst last, and
    # three looks inside each band.
    BANDS = 8
    LOOKS = 3

    # Which row of the plate to read its ground colour off. Any row through the middle of it
    # will do; this one is clear of the lettering along the top and the figures below.
    GROUND_ROW = 20

    # THE FIGURES ARE PICTURES, not letters. The original does not write its numbers in either
    # of its alphabets — it keeps ten numeral pictures, all the same size, and an eleventh that
    # is blank for a leading nought. That is worth following rather than working around: the
    # alphabet's own digits are NOT all the same width (its "1" is narrow), and a number drawn
    # in a font whose digits differ costs far more to draw, because the framework has to lay
    # out all ten of them at every digit place instead of calling one routine.
    NUMERALS = ([:blank_digit] + (0..9).map { |d| :"digit_#{d}" }).freeze
    BLANK = 0

    # THE LABELS ARE CUT OUT OF THE PLATE. They are not in either alphabet either — they are
    # painted into the picture in a condensed face of their own, narrower than anything
    # VGAGRAPH carries loose. Cutting them out and moving them keeps them exact, where setting
    # the same words in the alphabet would need 195 pixels of the 240 and leave no room for the
    # face.
    #
    # In the order the plate's own fields run, left to right. It has no label over its keys —
    # the slot is six pixels wide, which is a key and no room for a word.
    LABEL_FIELDS = %i[floor score lives health ammo].freeze

    # The rows of the plate the labels are painted on. Above them is a rule that runs the whole
    # width, below them the figures.
    LABEL_ROWS = (6..14)

    # How dark a column has to be, down the middle of the plate, to be one of the rules it
    # divides its fields with rather than part of a field.
    RULE_ROWS = (5...36)
    RULE_INK = 25

    attr_reader :face_width, :face_height, :key_width, :key_height, :digit_width, :digit_height

    # +vgagraph+ is a release whose pictures have names. Nil for a release we cannot name, and
    # then the bar draws the way it drew before there was any art.
    def self.of(vgagraph)
      new(vgagraph) if vgagraph && vgagraph.names.include?(:face_1a)
    end

    def initialize(vgagraph)
      @vg = vgagraph
      first = @vg.picture(:face_1a)
      @face_width = first.width
      @face_height = first.height
      key = @vg.picture(:no_key)
      @key_width = key.width
      @key_height = key.height
      digit = @vg.picture(:blank_digit)
      @digit_width = digit.width
      @digit_height = digit.height
    end

    def poses = BANDS * LOOKS

    # The twenty-four faces in one row, as palette numbers turned into colours.
    def faces(palette)
      strip(faces_in_order, @face_width, @face_height, palette)
    end

    def faces_width = @face_width * poses

    # A key slot: the empty one, then each metal. Also one row, for the same reason — which key
    # to show is worked out as the game runs.
    def keys(palette) = strip(key_names, @key_width, @key_height, palette)

    def keys_width = @key_width * key_names.length

    def key_names = [:no_key] + Level::KEYS.values.map { |metal| :"#{metal}_key" }

    # Where a metal sits along that row, counting pictures.
    def key_slot(metal) = key_names.index(:"#{metal}_key")

    # The blank numeral and the ten digits, in one row, so which to show is worked out. A digit
    # is at `digit + 1`, because the blank is first.
    def numerals(palette) = strip(NUMERALS, @digit_width, @digit_height, palette)

    def numerals_width = @digit_width * NUMERALS.length

    # ONE LABEL, CUT OUT OF THE PLATE, as a picture the framework can draw.
    #
    # Widened to an even number of columns where it needs to be, because the screen it lands on
    # takes two pixels at a time and will not take one. The extra column is the plate's own
    # ground beside the word, so widening it shows nothing that was not already there.
    def label(name, palette)
      x, y, w, h = label_box(name)
      w += 1 if w.odd?
      plate = @vg.picture(:status_bar)
      { width: w, height: h,
        data: h.times.flat_map { |dy| w.times.map { |dx| palette[plate[x + dx, y + dy]] } } }
    end

    def label_width(name) = label_box(name)[2].then { |w| w.odd? ? w + 1 : w }
    def label_height(name) = label_box(name)[3]

    # Where each label sits in the plate, found by reading the plate rather than by remembering
    # numbers: its fields are divided by rules, and a label is the ink inside a field.
    def label_box(name)
      label_boxes.fetch(name)
    end

    # THE COLOUR THE PLATE IS PAINTED IN, read out of the plate itself rather than picked, so
    # the bar is the game's own and not one somebody matched by eye. It is a dark BLUE, which
    # is worth knowing before looking at it: the face sits in a window of the same blue, and
    # against anything else the top of that window reads as a stray line rather than as part
    # of the picture.
    #
    # Taken as the commonest colour along a row rather than from a spot, because the plate's
    # frame runs ten columns in and a spot inside it lands on the frame's shadow — which is
    # very nearly black, and which is exactly the mistake this replaced.
    def ground = @vg.picture(:status_bar).rows[GROUND_ROW].tally.max_by { |_, count| count }.first

    private

    # THE PLATE'S OWN FIELDS, read off it. Every boundary on it is a column that is dark for
    # nearly the whole height — the frame down each side, a rule between each pair of fields,
    # and the well the face sits in, which is dense enough to read as one too. So the fields
    # are simply what lies BETWEEN those, in order.
    def plate_fields
      @plate_fields ||= begin
        plate = @vg.picture(:status_bar)
        g = ground
        dense = (0...plate.width).select do |x|
          RULE_ROWS.count { |y| plate[x, y] != g } > RULE_INK
        end
        dense.slice_when { |a, b| b > a + 1 }.to_a
             .each_cons(2).map { |before, after| [before.last + 1, after.first - 1] }
      end
    end

    # ...and the label inside each of them: the columns and rows the lettering actually
    # touches, so a label is its own word and not the field it sits in.
    def label_boxes
      @label_boxes ||= begin
        plate = @vg.picture(:status_bar)
        g = ground
        LABEL_FIELDS.each_with_index.to_h do |name, n|
          from, to = plate_fields.fetch(n)
          inked = (from..to).select { |x| LABEL_ROWS.any? { |y| plate[x, y] != g } }
          raise "the plate has no #{name} label between #{from} and #{to}" if inked.empty?

          rows = LABEL_ROWS.select { |y| inked.any? { |x| plate[x, y] != g } }
          [name, [inked.first, rows.first, inked.last - inked.first + 1, rows.last - rows.first + 1]]
        end
      end
    end

    def faces_in_order
      BANDS.times.flat_map { |band| %w[a b c].first(LOOKS).map { |look| :"face_#{band + 1}#{look}" } }
    end

    # Several same-size pictures laid out side by side, row by row, so a column of the result
    # picks one of them.
    def strip(names, width, height, palette)
      pictures = names.map { |name| @vg.picture(name) }
      height.times.flat_map do |y|
        pictures.flat_map { |picture| width.times.map { |x| palette[picture[x, y]] } }
      end
    end
  end
end
