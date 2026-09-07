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
  # NOT THE GAME'S OWN ART, yet. Wolfenstein's bar — the steel plate, the face that watches you,
  # the game's own lettering — is packed away in VGAGRAPH. That file is read now (see Vgagraph:
  # the plate, the numerals, the faces and both alphabets all come out of it), but nothing draws
  # with them here. This draws the same fields in the framework's own font on a flat ground, so
  # the game is playable and the layout is settled; the art goes in underneath afterwards without
  # moving a field.
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
    LABEL_ROW = 5
    FIGURE_ROW = 17

    # A key is shown as a block of its own metal rather than as a number, because what a player
    # wants off this bar is whether the gold door will open, which is a yes or a no.
    KEY_W = 8
    KEY_H = 10
    KEY_GAP = 4

    FONT = :default

    # WHERE EACH FIELD SITS, left to right, in the order the original puts them, with the widest
    # number each can ever reach. Kept as one row of facts rather than as a name here and a
    # position there, so nothing can be moved and left half-moved.
    Field = Data.define(:name, :label, :x, :digits)

    # THE ORIGINAL'S OWN ORDER, and the face goes where the original puts it: after LIVES and
    # before HEALTH. Read off the plate rather than remembered — the picture has a vertical
    # rule at each field boundary and a 34-wide well in the middle with nothing drawn in it,
    # which is the face's.
    #
    # THE POSITIONS ARE NOT the original's, and cannot be. Its plate is 320 across and this
    # screen is 240, and squeezing the plate makes the lettering baked into it unreadable
    # (measured: nearest column turns LIVES into noise, and a smoothing filter blurs it rather
    # than fixing it). So the bar is RE-SET at 240 with the same fields in the same order,
    # which is also what the 2002 handheld port did.
    FIELDS = [
      Field.new(name: :floor,  label: "FLOOR",  x: 4,   digits: 1),
      Field.new(name: :score,  label: "SCORE",  x: 40,  digits: 6),
      Field.new(name: :lives,  label: "LIVES",  x: 82,  digits: 1),
      Field.new(name: :face,   label: nil,      x: 116, digits: nil),
      Field.new(name: :health, label: "HEALTH", x: 146, digits: 3),
      Field.new(name: :ammo,   label: "AMMO",   x: 188, digits: 2),
      Field.new(name: :keys,   label: "KEYS",   x: 216, digits: nil)
    ].freeze

    # The fields that carry a name above their figure. The face carries none — it is a picture,
    # and the original labels it with nothing either.
    def self.labelled = FIELDS.reject { |field| field.label.nil? }

    # +shows+ is what to put in each field, by name: a variable for the ones that change and a
    # plain number for the ones that do not. +art+ is Wolfenstein's own pictures for the bar,
    # or nil for a release whose pictures we cannot name — then the bar draws as it drew before
    # there was any art to draw with.
    def initialize(build:, top:, shows:, art: nil)
      @b = build
      @top = top
      @shows = shows
      @art = art
      declare
    end

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
      @b.func(:draw_the_status_bar) { paint }

      # What each live field showed when it was last painted, and how many pages still want the
      # new picture. Both start so that the first frame paints: nothing has been shown yet.
      @changed = @b.var :_bar_changed, 0
      @todo = @b.var :_bar_todo, PAGES
      @face = @b.var :_bar_face, 0
      @remembered = @shows.filter_map do |name, value|
        [name, @b.var(:"_bar_last_#{name}", -1)] unless value.is_a?(Integer)
      end.to_h
    end

    # The faces and the keys, each as ONE wide picture of all of them side by side, so which one
    # to show is a column worked out rather than a choice made.
    def declare_the_art
      return unless @art

      @b.image :bar_faces, width: @art.faces_width, height: @art.face_height,
                           data: @art.faces(Palette.game)
      @b.image :bar_keys, width: @art.keys_width, height: @art.key_height,
                          data: @art.keys(Palette.game)
    end

    def paint
      @b.dma_fill_rect 0, @top, FirstPerson::ACROSS, HEIGHT, colour(ground_index)
      FIELDS.each do |field|
        @b.draw_text field.label, field.x, @top + LABEL_ROW, colour(LABEL), font: FONT if field.label
        case field.name
        when :face then draw_the_face(field)
        when :keys then draw_the_keys(field)
        else draw_a_figure(field)
        end
      end
    end

    # The game's own steel where we have it, and the grey that stood in for it where we do not.
    def ground_index = @art ? @art.ground : GROUND

    def colour(index) = Palette.game[index]
    def font = RubyGBA::Fonts.get(FONT)

    # Centred under its own label, which is what keeps the bar looking arranged as the numbers
    # under it grow and shrink. A figure reserves room for every digit it could reach, so the
    # width is the field's rather than today's value's.
    def draw_a_figure(field)
      room = field.digits * font.cell_w
      x = field.x + ((font.text_width(field.label) - room) / 2)
      @b.draw_number @shows.fetch(field.name), x, @top + FIGURE_ROW, colour(FIGURE),
                     digits: field.digits, font: FONT
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
      wide = @art.face_width
      top = @top + ((HEIGHT - @art.face_height) / 2)

      wide.times do |col|
        @b.draw_column_at :bar_faces, slice: (@face * (wide * LOOKS)) + col,
                                      x: field.x + col, top: top, height: @art.face_height
      end
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
      wide = @art.key_width
      x = field.x + ((font.text_width(field.label) - wide) / 2)

      METALS.each_key.with_index do |name, n|
        slot = @b.var :"_bar_key_#{name}", 0
        slot.set 0
        carrying(keys, name).then { slot.set @art.key_slot(name) }
        y = @top + FIGURE_ROW - 4 + (n * @art.key_height)
        wide.times do |col|
          @b.draw_column_at :bar_keys, slice: (slot * wide) + col,
                                       x: x + col, top: y, height: @art.key_height
        end
      end
    end

    # What the bar showed before there was any art: two blocks side by side, drawn dark, and
    # the one you are carrying painted over in its own metal.
    def draw_the_key_blocks(field)
      keys = @shows.fetch(:keys)
      wide = (METALS.length * KEY_W) + ((METALS.length - 1) * KEY_GAP)
      left = field.x + ((font.text_width(field.label) - wide) / 2)
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
