# frozen_string_literal: true

module Wolf3D
  # THE BAR ALONG THE BOTTOM: which floor you are on, the score, the lives left, how much health
  # and ammunition, and which keys are in your pocket.
  #
  # It is the part of the screen nobody thinks about and everybody would notice missing. It is
  # also what makes the view SHORTER, which is not a detail: this renderer pays for the rows a
  # wall column actually shows, so handing the bottom fifth of the screen to a bar takes about
  # that share off everything drawn above it.
  #
  # IT IS THE GAME'S OWN ART where there is a copy of the game to read it out of (see BarArt):
  # its labels, cut out of the plate; its numerals, which are pictures rather than letters; the
  # face that watches you; and its key pictures. A release whose pictures we cannot name falls
  # back to the framework's own font on a flat ground, which is what this drew before there was
  # any art — and which is what the tests see, because the release we write for ourselves
  # carries none.
  #
  # WHAT IS STILL NOT THE GAME'S: the plate's own steel and its rules between the fields. The
  # ground is a flat fill of the plate's colour rather than the plate itself, because the plate
  # is 320 across and this screen is 240 and squeezing it turns its baked-in lettering to noise.
  # Its texture and rules can be re-set at 240; that is the piece left.
  #
  # IT IS REPAINTED EVERY FRAME, and only one of the two reasons for that is still true.
  #
  # It used to be that a wall column near enough to fill the screen was drawn straight down
  # through where the bar sits, because nothing could be told to stop at a line. That is no
  # longer so: the view is drawn `inside` its own rows and a column too tall for them is clipped,
  # on both backends. Nothing paints over the bar any more.
  #
  # What is left is the screen. It keeps two pages and shows them in turn, so anything painted
  # once is only on one of them — which needs TWO repaints whenever a field changes, not one
  # every frame. Painting it regardless measures about a twentieth of the frame, nearly always
  # to put back a picture identical to the one already there.
  class StatusBar
    # How many rows along the bottom it takes. The original gives its bar a fifth of the screen
    # and so does this.
    HEIGHT = 32

    # COLOURS OUT OF THE GAME'S OWN 256 rather than invented, so the bar is painted from the same
    # box as everything else on screen. Grey ground, dimmer labels, white figures — and the two
    # keys in the metals they are named for.
    GROUND = 28
    LABEL = 23
    FIGURE = 15
    UNLIT = 31
    METALS = { gold: 71, silver: 20 }.freeze

    # Down from the top of the bar: the label on one line, its figure under it.
    #
    # These fit the GAME'S art, which is what has no give in it: its labels are 9 rows tall and
    # its numerals 16, so the pair needs 25 of the bar's 32 and there is little to spare. The
    # framework's own font is 7 and 7, so it sits in the same places with room around it.
    LABEL_ROW = 2
    FIGURE_ROW = 12

    # A key is shown as a block of its own metal rather than as a number, because what a player
    # wants off this bar is whether the gold door will open, which is a yes or a no.
    KEY_W = 8
    KEY_H = 10
    KEY_GAP = 4

    FONT = :default

    # WHERE EACH FIELD SITS, left to right, in the order the original puts them, with the widest
    # number each can ever reach. Kept as one row of facts rather than as a name here and a
    # position there, so nothing can be moved and left half-moved.
    Field = Data.define(:name, :label, :digits)

    # THE ORIGINAL'S OWN ORDER, and the face goes where the original puts it: after LIVES and
    # before HEALTH. Read off the plate rather than remembered — the picture has a vertical
    # rule at each field boundary and a 34-wide well in the middle with nothing drawn in it,
    # which is the face's.
    #
    # NO POSITIONS HERE, and that is the point. The original's cannot be used — its plate is 320
    # across and this screen is 240, and squeezing the plate turns the lettering baked into it
    # into noise (measured: nearest column makes LIVES unreadable, and a smoothing filter blurs
    # it rather than fixing it). And a position typed in here would be wrong half the time
    # anyway, because how wide a field is depends on whether the game's own art is there to
    # draw it with: the game's numerals are 8 across where the framework's are 6, and its
    # labels are narrower than the same words set in a font.
    #
    # So the bar is LAID OUT from the widths of what actually goes in it. See .layout.
    FIELDS = [
      Field.new(name: :floor,  label: "FLOOR",  digits: 1),
      Field.new(name: :score,  label: "SCORE",  digits: 6),
      Field.new(name: :lives,  label: "LIVES",  digits: 1),
      Field.new(name: :face,   label: nil,      digits: nil),
      Field.new(name: :health, label: "HEALTH", digits: 3),
      Field.new(name: :ammo,   label: "AMMO",   digits: 2),
      Field.new(name: :keys,   label: "KEYS",   digits: nil)
    ].freeze

    # The fields that carry a name above their figure. The face carries none — it is a picture,
    # and the original labels it with nothing either.
    def self.labelled = FIELDS.reject { |field| field.label.nil? }

    # WHERE EACH FIELD GOES, worked out from how wide the things in it are and spread evenly
    # across the bar. +art+ is the game's own pictures, or nil to lay the bar out for the
    # framework's own font — the two come out quite differently, which is why this is worked
    # out rather than written down.
    def self.layout(art)
      wide = widths(art)
      gap = (FirstPerson::ACROSS - wide.values.sum) / (FIELDS.length + 1)
      at = gap
      FIELDS.to_h do |field|
        [field.name, at].tap { at += wide.fetch(field.name) + gap }
      end
    end

    # How wide each field has to be: the wider of its label and its figure, so the bar stays
    # arranged whichever of the two is longer. A score is six numerals and the word SCORE is
    # shorter than that; HEALTH is the other way round.
    def self.widths(art)
      FIELDS.to_h { |field| [field.name, art ? field_width(field, art) : plain_width(field)] }
    end

    def self.field_width(field, art)
      case field.name
      when :face then art.face_width
      when :keys then art.key_width
      else [art.label_width(field.name), field.digits * art.digit_width].max
      end
    end

    # Without the art there is no face at all, and the keys are two blocks side by side.
    def self.plain_width(field)
      font = RubyGBA::Fonts.get(FONT)
      case field.name
      when :face then 0
      when :keys then [font.text_width(field.label), (METALS.length * KEY_W) + KEY_GAP].max
      else [font.text_width(field.label), field.digits * font.cell_w].max
      end
    end

    # +shows+ is what to put in each field, by name: a variable for the ones that change and a
    # plain number for the ones that do not. +art+ is Wolfenstein's own pictures for the bar,
    # or nil for a release whose pictures we cannot name — then the bar draws as it drew before
    # there was any art to draw with.
    def initialize(build:, top:, shows:, art: nil)
      @b = build
      @top = top
      @shows = shows
      @art = art
      @at = self.class.layout(art)
      declare
    end

    # Where a field's left edge falls, out of the layout worked out for this bar's art.
    def at(field) = @at.fetch(field.name)

    # HOW MANY TIMES A CHANGED BAR IS PAINTED, and it is two because the screen keeps two pages
    # and shows them in turn. Painted once, half the frames would show the old figure.
    PAGES = 2

    # PAINT IT WHEN IT CHANGED, AND NOT OTHERWISE. Health changes when you are shot, ammunition
    # when you fire, the score when you kill something; the floor and the lives hardly ever. On
    # every other frame the bar is asked to put back a picture identical to the one already
    # there, which measures about a twentieth of the frame.
    #
    # Testing costs a comparison per live field, which is nothing beside the painting.
    # HOW OFTEN IT REALLY PAINTS, for the estimate's sake: about one frame in ten. Firing
    # spends a bullet and being hit spends health, and each of those asks for both pages —
    # so a busy second or two of shooting is a handful of painted frames out of sixty, and
    # walking down a corridor is none at all. Ten is the cautious end of that.
    #
    # Unsaid it would be counted on EVERY frame, which is what this whole arrangement exists
    # to avoid, and the report would show the bar costing what it cost before it was made
    # conditional.
    PAINTS_IN = 10

    def draw
      notice_a_change
      (@todo > 0).then(estimate: { usually: 1, in: PAINTS_IN }) do
        @todo.sub 1
        @b.call(:draw_the_status_bar)
      end
    end

    private

    # Did any field move since it was last painted? Each keeps a copy of what it last showed, and
    # the copy is taken here rather than in the painting — so a change asks for both pages and
    # the second of the two does not think it has found another one.
    def notice_a_change
      @changed.set 0
      @remembered.each do |name, last|
        value = @shows.fetch(name)
        (value != last).then do
          @changed.set 1
          last.set value
        end
      end
      (@changed == 1).then { @todo.set PAGES }
    end

    # PAINTING THE BAR IS A ROUTINE, and it has to be. A live number drawn into a picture is not
    # one instruction: the framework cannot know which digit will be there, so it lays out the
    # pixels of all ten and picks between them, for every digit place of every field. That comes
    # to about eighteen thousand bytes — too big to keep in the console's quick memory, which
    # `rom.explain` now says out loud — and written straight into the game loop it would push the
    # loop itself out of that memory, which costs about two and a half times on every instruction
    # in the game.
    def declare
      declare_the_art
      declare_the_strip_routines if @art
      @b.func(:draw_the_status_bar) { paint }

      # What each live field showed when it was last painted, and how many pages still want the
      # new picture. Both start so that the first frame paints: nothing has been shown yet.
      @changed = @b.var :_bar_changed, 0
      @todo = @b.var :_bar_todo, PAGES
      @face = @b.var :_bar_face, 0
      @looks = @b.var :_bar_look, 0
      @remembered = @shows.filter_map do |name, value|
        [name, @b.var(:"_bar_last_#{name}", -1)] unless value.is_a?(Integer)
      end.to_h
    end

    # The faces and the keys, each as ONE wide picture of all of them side by side, so which one
    # to show is a column worked out rather than a choice made.
    def declare_the_art
      return unless @art

      palette = Palette.game
      @b.image :bar_faces, width: @art.faces_width, height: @art.face_height,
                           data: @art.faces(palette)
      @b.image :bar_keys, width: @art.keys_width, height: @art.key_height,
                          data: @art.keys(palette)
      @b.image :bar_numerals, width: @art.numerals_width, height: @art.digit_height,
                              data: @art.numerals(palette)
      BarArt::LABEL_FIELDS.each do |name|
        cut = @art.label(name, palette)
        @b.image :"bar_label_#{name}", width: cut[:width], height: cut[:height], data: cut[:data]
      end
    end

    def paint
      @b.dma_fill_rect 0, @top, FirstPerson::ACROSS, HEIGHT, colour(ground_index)
      draw_the_plate
      FIELDS.each do |field|
        draw_a_label(field)
        case field.name
        when :face then draw_the_face(field)
        when :keys then draw_the_keys(field)
        else draw_a_figure(field)
        end
      end
    end

    # THE LABEL OVER A FIELD, cut out of the plate where we have it and set in the framework's
    # own font where we do not. The face carries none, and neither does the key slot: the
    # original's is six pixels wide, which is a key and no room for a word.
    def draw_a_label(field)
      return if field.label.nil?
      return @b.draw_text(field.label, at(field), @top + LABEL_ROW, colour(LABEL), font: FONT) unless @art
      return unless BarArt::LABEL_FIELDS.include?(field.name)

      @b.blit :"bar_label_#{field.name}", at(field), @top + LABEL_ROW
    end

    # The game's own steel where we have it, and the grey that stood in for it where we do not.
    def ground_index = @art ? @art.ground : GROUND

    # THE PLATE'S EDGE AND ITS RULES, re-set at 240.
    #
    # The plate itself cannot be used — it is 320 across and squeezing it turns the lettering
    # baked into it to noise — but what makes it look like a plate is not its texture. Its middle
    # is one flat colour for two thirds of every row; what reads as steel is the LINE round the
    # outside and the grooves between the fields. Both are lines, and a line can be re-set at any
    # width without losing anything.
    #
    # A rule is two columns of different colours, which is what makes it a groove in the metal
    # rather than a stripe on it, and it is drawn a column at a time because one column is an odd
    # width and the block fills on this screen want an even one.
    def draw_the_plate
      return unless @art

      top = @art.top_edge
      bottom = @art.bottom_edge
      top.each_with_index { |ink, i| @b.dma_fill_rect 0, @top + i, FirstPerson::ACROSS, 1, colour(ink) }
      bottom.each_with_index do |ink, i|
        @b.dma_fill_rect 0, @top + HEIGHT - bottom.length + i, FirstPerson::ACROSS, 1, colour(ink)
      end

      boundaries.each do |x|
        # HALF THE COLUMN, DOUBLED, and not the column itself. A picture on this screen must
        # start on an even column, and the framework will only draw one where it can PROVE the
        # column is even — a variable it cannot see into is refused rather than drawn in the
        # wrong place. Twice anything is even, so this is the way to say it, and it is the way
        # the refusal itself suggests.
        @rule_half.set(x / 2)
        @b.call :_bar_rule
      end
    end

    # Where the grooves go: midway between the end of one field and the start of the next, which
    # is where the plate puts its own. The face gets one on each side for free, which is what its
    # well is. Rounded to an even column, because that is where a picture can be drawn.
    def boundaries
      wide = self.class.widths(@art)
      FIELDS.each_cons(2).map do |before, after|
        ends = at(before) + wide.fetch(before.name)
        middle = ends + (((at(after) - ends) - @art.rule_width) / 2)
        middle - (middle % 2)
      end
    end

    def colour(index) = Palette.game[index]
    def font = RubyGBA::Fonts.get(FONT)

    # Centred under its own label, which is what keeps the bar looking arranged as the numbers
    # under it grow and shrink. A figure reserves room for every digit it could reach, so the
    # width is the field's rather than today's value's.
    def draw_a_figure(field)
      return draw_a_figure_in_numerals(field) if @art

      room = field.digits * font.cell_w
      x = at(field) + ((font.text_width(field.label) - room) / 2)
      @b.draw_number @shows.fetch(field.name), x, @top + FIGURE_ROW, colour(FIGURE),
                     digits: field.digits, font: FONT
    end

    # THE FIGURE IN THE GAME'S OWN NUMERALS, which are pictures rather than letters — the
    # original keeps ten of them, all one size, and an eleventh that is blank.
    #
    # Each digit place works out its own digit and shows the numeral that many along the row of
    # them, so nothing is chosen: the column is `slot * width + column`, the same arithmetic the
    # face uses. A place the number has not reached yet shows the blank one instead, which is
    # what drops the leading noughts; the ones place always shows, so a value of nothing still
    # reads as 0.
    def draw_a_figure_in_numerals(field)
      value = @shows.fetch(field.name)
      wide = @art.digit_width
      left = at(field) + ((label_width(field) - (field.digits * wide)) / 2)
      slot = @b.var :"_bar_digit_#{field.name}", 0

      field.digits.times do |i|
        place = 10**(field.digits - 1 - i)
        digit = place == 1 ? value % 10 : (value / place) % 10
        if place == 1
          slot.set(digit + 1)
        else
          slot.set BarArt::BLANK
          (value >= place).then { slot.set(digit + 1) }
        end
        draw_from_strip(:_bar_numeral, slot, left + (i * wide), @top + FIGURE_ROW)
      end
    end

    # How wide the field's own label is, which is what a figure is centred under.
    def label_width(field)
      return font.text_width(field.label) unless @art && BarArt::LABEL_FIELDS.include?(field.name)

      @art.label_width(field.name)
    end

    # ONE PICTURE OUT OF A ROW OF THEM, walked column by column. The row holds every picture the
    # thing can show side by side, so which one is `slot * width + column` — arithmetic instead
    # of a choice, which is what keeps one drawing in the cartridge instead of one per picture.
    #
    # AND THE WALK IS A ROUTINE, which is not a tidiness — it is the difference between a bar
    # that fits in the console's quick memory and one that does not. Written as a helper called
    # from each place that draws, the walk is EMITTED at each of them: thirteen digit places, a
    # face and two keys come to a hundred and forty-four column draws laid out in the cartridge,
    # and the bar's painting routine measured 57K. Emitted once per strip and called instead, it
    # is forty. The cost at run time is the same walk either way.
    def draw_from_strip(routine, slot, x, top)
      @col_slot.set slot
      @col_x.set x
      @col_y.set top
      @b.call routine
    end

    # One routine per strip, because which picture a walk reads from is settled while building
    # and only WHICH ONE ALONG IT is worked out as the game runs.
    def declare_the_strip_routines
      @col_x = @b.var :_bar_col_x, 0
      @col_y = @b.var :_bar_col_y, 0
      @col_slot = @b.var :_bar_col_slot, 0

      strip_routine(:_bar_numeral, :bar_numerals, @art.digit_width, @art.digit_height)
      strip_routine(:_bar_key, :bar_keys, @art.key_width, @art.key_height)
      # THE FACE IS WALKED IN GROUPS rather than in one go, for the same reason the walk is a
      # routine at all. A routine 24 columns wide is 24 column draws in the cartridge and
      # measured 11.2K, which is more than was left of the console's quick memory; three groups
      # of eight is one routine of 8, called three times, and fits. A group is just a narrower
      # picture — the strip's columns do not care where one picture ends and the next begins, so
      # 24 pictures of 24 columns and 72 of 8 are the same columns counted differently.
      strip_routine(:_bar_face, :bar_faces, FACE_GROUP, @art.face_height)
      declare_the_rule
    end

    # The groove between two fields, as a picture and a routine that draws it wherever the
    # column variable says. One drawing in the cartridge, called once per boundary.
    def declare_the_rule
      cut = @art.rule(inside_height, Palette.game)
      @b.image :bar_rule, width: cut[:width], height: cut[:height], data: cut[:data]
      @rule_half = @b.var :_bar_rule_half, 0

      half = @rule_half
      build = @b
      top = inside_top
      build.func(:_bar_rule) { build.blit :bar_rule, half * 2, top }
    end

    # The part of the bar inside the plate's edge, which is what a groove runs down.
    def inside_top = @top + @art.top_edge.length
    def inside_height = HEIGHT - @art.top_edge.length - @art.bottom_edge.length

    # How wide a bite of the face the walk takes at a time, and therefore how many bites a face
    # is. It has to divide the face's width exactly.
    FACE_GROUP = 8

    def strip_routine(name, picture, wide, height)
      col_x = @col_x
      col_y = @col_y
      col_slot = @col_slot
      build = @b
      build.func(name) do
        wide.times do |col|
          build.draw_column_at picture, slice: (col_slot * wide) + col,
                                        x: col_x + col, top: col_y, height: height
        end
      end
    end

    # THE FACE THAT WATCHES YOU, and the only thing on the bar that is a picture chosen as the
    # game runs. Eight of them, worst last, picked by how much health is left.
    #
    # It is drawn column by column out of the one wide picture that holds all twenty-four,
    # because that turns "which face" into arithmetic — `pose * 24 + column` — and the game can
    # do arithmetic. Choosing between twenty-four pictures instead would be twenty-four tests
    # and twenty-four copies of a drawing in the cartridge.
    #
    # Only the eight bands, and not yet the three looks each band has: the looks change on
    # their own every second or so, and the bar is painted only when something changes, so
    # winking would repaint the whole bar to move two eyes.
    def draw_the_face(field)
      return unless @art

      @face.set(((@shows.fetch(:health) * BANDS) / (FirstPerson::START_HEALTH + 1)))
      @face.set(BANDS - 1 - @face)
      @face.clamp 0, BANDS - 1
      # The three looks of a band sit together in the row, so a band is three pictures along —
      # and counted in groups of eight columns rather than in whole faces, which is how the walk
      # reads them: a face is `@art.face_width / FACE_GROUP` groups.
      groups = @art.face_width / FACE_GROUP
      @looks.set(@face * LOOKS * groups)
      top = @top + ((HEIGHT - @art.face_height) / 2)
      groups.times { |g| draw_from_strip(:_bar_face, @looks + g, at(field) + (g * FACE_GROUP), top) }
    end

    # HOW MANY FACES there are for how hurt you are, and how many looks each of them has. Both
    # are the release's own arrangement, not a choice.
    BANDS = BarArt::BANDS
    LOOKS = BarArt::LOOKS

    # The keys, one above the other in a slot of their own, which is how the original shows
    # them: an empty socket, or the key in the metal it is named for. Drawn out of the one wide
    # picture that holds the empty one and both metals, so which to show is worked out.
    def draw_the_keys(field)
      return draw_the_key_blocks(field) unless @art

      keys = @shows.fetch(:keys)
      top = @top + ((HEIGHT - (METALS.length * @art.key_height)) / 2)

      METALS.each_key.with_index do |name, n|
        slot = @b.var :"_bar_key_#{name}", 0
        slot.set BarArt::BLANK
        carrying(keys, name).then { slot.set @art.key_slot(name) }
        draw_from_strip(:_bar_key, slot, at(field), top + (n * @art.key_height))
      end
    end

    # What the bar showed before there was any art: two blocks side by side, drawn dark, and
    # the one you are carrying painted over in its own metal.
    def draw_the_key_blocks(field)
      keys = @shows.fetch(:keys)
      wide = (METALS.length * KEY_W) + ((METALS.length - 1) * KEY_GAP)
      left = at(field) + ((font.text_width(field.label) - wide) / 2)
      y = @top + FIGURE_ROW - 2

      METALS.each_with_index do |(name, metal), n|
        x = left + (n * (KEY_W + KEY_GAP))
        @b.dma_fill_rect x, y, KEY_W, KEY_H, colour(UNLIT)
        carrying(keys, name).then { @b.dma_fill_rect x, y, KEY_W, KEY_H, colour(metal) }
      end
    end

    # The keys are kept as one number with a bit per key, which is how the doors ask about them.
    def carrying(keys, name) = ((keys / FirstPerson::KEY_BITS.fetch(name)) % 2) == 1
  end
end
