# frozen_string_literal: true

module Wolf3D
  # THE BAR ALONG THE BOTTOM: the score, the lives left, how much health and ammunition, which
  # keys are in your pocket, and the gun in your hands.
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
  # IT IS PAINTED WHEN A FIELD CHANGES, AND NOT OTHERWISE, which is two decisions.
  #
  # Nothing paints over it, so a picture left there stays: the view above is drawn `inside` its
  # own rows, and a wall column near enough to fill the screen is clipped at the line where the
  # bar starts rather than running down through it.
  #
  # And a change reaching the whole screen takes more than one paint, because the screen keeps
  # more than one picture and shows them in turn. How many is `keep_showing`'s business (see
  # #declare), not this file's. What this file decides is whether a field moved at all —
  # painting regardless measures about a twentieth of the frame, nearly always to put back a
  # picture identical to the one already there.
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

    # THE ORIGINAL'S OWN ORDER, and the face and the weapon go where the original puts them: the
    # face after LIVES and before HEALTH, the weapon last of all, past the keys. Read off the
    # plate rather than remembered — the picture has a vertical rule at each field boundary and a
    # 34-wide well in the middle with nothing drawn in it, which is the face's.
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
    #
    # THE FLOOR NUMBER IS THE ONE FIELD THE ORIGINAL HAS AND THIS DOES NOT, and it is arithmetic
    # rather than judgement. Measured on this release, the seven fields the bar carried before
    # the weapon came to 190 of the 240 columns, which left 6 between each pair — and a groove is
    # two columns and wants a clear one on each side of it, so there was nothing to give. There
    # is no size at all a weapon could be drawn at that fits beside all seven: even a gun 24
    # columns wide leaves gaps of 2, and two columns cannot hold a groove. So one field goes, and
    # the floor is the one that can: 26 columns for a number that is set when a floor starts and
    # never moves again, where everything else on the bar answers to what the player is doing.
    FIELDS = [
      Field.new(name: :score,  label: "SCORE",  digits: 6),
      Field.new(name: :lives,  label: "LIVES",  digits: 1),
      Field.new(name: :face,   label: nil,      digits: nil),
      Field.new(name: :health, label: "HEALTH", digits: 3),
      Field.new(name: :ammo,   label: "AMMO",   digits: 2),
      Field.new(name: :keys,   label: "KEYS",   digits: nil),
      Field.new(name: :weapon, label: nil,      digits: nil)
    ].freeze

    # The fields that carry a name above their figure. The face carries none — it is a picture,
    # and the original labels it with nothing either.
    def self.labelled = FIELDS.reject { |field| field.label.nil? }

    # THE LEAST ROOM TO LEAVE AT EACH END OF THE BAR. The plate's own frame is ten columns and
    # there is no room for that here; two is enough that the first field does not start against
    # the edge of the screen.
    EDGE = 2

    # WHERE EACH FIELD GOES, worked out from how wide the things in it are. +art+ is the game's
    # own pictures, or nil to lay the bar out for the framework's own font — the two come out
    # quite differently, which is why this is worked out rather than written down.
    #
    # THE ROOM GOES BETWEEN THE FIELDS AND THE ROW IS THEN CENTRED, rather than one share per gap
    # including the two at the ends, because the two kinds of gap are not carrying the same
    # thing: between two fields there is a groove cut down the middle, and at the edge of the
    # screen there is nothing at all.
    #
    # AND IT IS SPREAD IN TWOS, because every field has to START ON AN EVEN COLUMN — a picture on
    # this screen does, and a label is a picture cut out of the plate. Widths are even for the
    # same reason, so an even gap and an even first field keep every field after it even too.
    # That also settles the groove: in a gap of six it lands two columns clear of each side (see
    # #boundaries), which is the clearance the plate's own rules have.
    def self.layout(art)
      wide = widths(art)
      between = FIELDS.length - 1
      gap = even((FirstPerson::ACROSS - wide.values.sum - (2 * EDGE)) / between)
      at = even((FirstPerson::ACROSS - wide.values.sum - (gap * between)) / 2)
      FIELDS.to_h do |field|
        [field.name, at].tap { at += wide.fetch(field.name) + gap }
      end
    end

    def self.even(columns) = columns - (columns % 2)

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
      when :weapon then art.weapon_width
      else [art.label_width(field.name), field.digits * art.digit_width].max
      end
    end

    # Without the art there is no face and no weapon at all, and the keys are two blocks side by
    # side.
    def self.plain_width(field)
      font = RubyGBA::Fonts.get(FONT)
      case field.name
      when :face, :weapon then 0
      when :keys then [font.text_width(field.label), (METALS.length * KEY_W) + KEY_GAP].max
      else [font.text_width(field.label), field.digits * font.cell_w].max
      end
    end

    # WHERE A THING SITS INSIDE ITS FIELD: in the middle of it, on an even column. Both the name
    # and the figure are placed this way, so neither can lean out of its own box and across the
    # groove beside it — which the score's six numerals used to do, being centred under a word
    # ten columns narrower than they are.
    def self.centred(field, wide, art)
      layout(art).fetch(field.name) + even((widths(art).fetch(field.name) - wide) / 2)
    end

    # WHERE THE GROOVES GO: midway between the end of one field and the start of the next, which
    # is where the plate puts its own. The face gets one on each side for free, which is what its
    # well is. Rounded to an even column, because that is where a picture can be drawn — and that
    # rounding is why a gap of six is the smallest that works: in a gap of four the only even
    # columns are the two that touch a field.
    def self.boundaries(art)
      at = layout(art)
      wide = widths(art)
      FIELDS.each_cons(2).map do |before, after|
        ends = at.fetch(before.name) + wide.fetch(before.name)
        even(ends + ((at.fetch(after.name) - ends - art.rule_width) / 2))
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

    # ...and where something +wide+ columns across sits inside that field.
    def centred(field, wide) = self.class.centred(field, wide, @art)

    # PAINT IT WHEN IT CHANGED, AND NOT OTHERWISE. Health changes when you are shot, ammunition
    # when you fire, the score when you kill something; the lives and the gun in your hands
    # hardly ever. On every other frame the bar would be asked to put back a picture identical
    # to the one already there, which measures about a twentieth of the frame.
    #
    # Testing costs a comparison per live field, which is nothing beside the painting.
    def draw
      notice_a_change
      @bar.draw
    end

    private

    # Did any field move since it was last painted? Each keeps a copy of what it last showed, and
    # the copy is taken here rather than in the painting — so one change is noticed one time,
    # however many paints it then takes to reach the whole screen.
    def notice_a_change
      @changed.set 0
      @remembered.each do |name, last|
        value = @shows.fetch(name)
        (value != last).then do
          @changed.set 1
          last.set value
        end
      end
      (@changed == 1).then { @bar.changed }
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

      # The bar itself: painted when a field moves and then left alone. How many times a
      # change has to be painted is `keep_showing`'s business, not this file's — the screen
      # this game draws on keeps two pictures and shows them in turn, and a bar painted once
      # would reach only half the frames.
      @bar = @b.keep_showing(:status_bar) { paint }
      # Asked for at the top level, so it happens once at power-on: nothing has been shown
      # yet, so the first frames paint.
      @bar.changed

      # What each live field showed when it was last painted, so a change can be noticed.
      @changed = @b.var :_bar_changed, 0
      @face = @b.var :_bar_face, 0
      @looks = @b.var :_bar_look, 0
      @gun = @b.var :_bar_gun, 0
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
      @b.image :bar_weapons, width: @art.weapons_width, height: @art.weapon_height,
                             data: @art.weapons(palette)
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
        when :weapon then draw_the_weapon(field)
        else draw_a_figure(field)
        end
      end
    end

    # THE LABEL OVER A FIELD, cut out of the plate where we have it and set in the framework's
    # own font where we do not. The face carries none, and neither does the weapon or the key
    # slot: the original's key slot is six pixels wide, which is a key and no room for a word.
    def draw_a_label(field)
      return if field.label.nil?

      unless @art
        return @b.draw_text(field.label, centred(field, font.text_width(field.label)),
                            @top + LABEL_ROW, colour(LABEL), font: FONT)
      end
      return unless BarArt::LABEL_FIELDS.include?(field.name)

      @b.blit :"bar_label_#{field.name}", centred(field, @art.label_width(field.name)),
              @top + LABEL_ROW
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

    def boundaries = self.class.boundaries(@art)

    def colour(index) = Palette.game[index]
    def font = RubyGBA::Fonts.get(FONT)

    # Centred in its own field, which is what keeps the bar looking arranged as the numbers grow
    # and shrink. A figure reserves room for every digit it could reach, so the width is the
    # field's rather than today's value's.
    def draw_a_figure(field)
      return draw_a_figure_in_numerals(field) if @art

      @b.draw_number @shows.fetch(field.name), centred(field, field.digits * font.cell_w),
                     @top + FIGURE_ROW, colour(FIGURE), digits: field.digits, font: FONT
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
      left = centred(field, field.digits * wide)
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
      strip_routine(:_bar_weapon, :bar_weapons, WEAPON_GROUP, @art.weapon_height)
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

    # ...and the same for the guns, which are 36 columns drawn and so want a bite that divides
    # 36 rather than 24. Six, for the same reason the face's is eight: small enough that one
    # routine of that many column draws is a small routine.
    WEAPON_GROUP = 6

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

    # THE GUN IN YOUR HANDS, and this is the field the shoulder buttons move. The four are laid
    # side by side in one picture like the faces, so which one to show is the number the player
    # is already holding — no test per weapon, and one drawing in the cartridge rather than four.
    #
    # IT IS ON THE BAR AS WELL AS IN YOUR HANDS ON PURPOSE. The gun drawn over the view says the
    # same thing, but it says it in the middle of the corridor you are looking down; the original
    # puts a second copy on the bar because that is where a player looks to check.
    def draw_the_weapon(field)
      return unless @art

      groups = @art.weapon_width / WEAPON_GROUP
      @gun.set(@shows.fetch(:weapon) * groups)
      top = @top + ((HEIGHT - @art.weapon_height) / 2)
      groups.times do |g|
        draw_from_strip(:_bar_weapon, @gun + g, at(field) + (g * WEAPON_GROUP), top)
      end
    end

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
      left = centred(field, wide)
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
