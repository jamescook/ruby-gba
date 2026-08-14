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
  # the game's own lettering — is packed away in VGAGRAPH, which nothing here reads. This draws
  # the same fields in the framework's own font on a flat ground, so the game is playable and the
  # layout is settled; the art goes in underneath afterwards without moving a field.
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

    FIELDS = [
      Field.new(name: :floor,  label: "FLOOR",  x: 6,   digits: 1),
      Field.new(name: :score,  label: "SCORE",  x: 45,  digits: 6),
      Field.new(name: :lives,  label: "LIVES",  x: 84,  digits: 1),
      Field.new(name: :health, label: "HEALTH", x: 123, digits: 3),
      Field.new(name: :ammo,   label: "AMMO",   x: 168, digits: 2),
      Field.new(name: :keys,   label: "KEYS",   x: 201, digits: nil)
    ].freeze

    # +shows+ is what to put in each field, by name: a variable for the ones that change and a
    # plain number for the ones that do not.
    def initialize(build:, top:, shows:)
      @b = build
      @top = top
      @shows = shows
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
    def draw
      notice_a_change
      (@todo > 0).then do
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
      bar = self
      @b.func(:draw_the_status_bar) { bar.send(:paint) }

      # What each live field showed when it was last painted, and how many pages still want the
      # new picture. Both start so that the first frame paints: nothing has been shown yet.
      @changed = @b.var :_bar_changed, 0
      @todo = @b.var :_bar_todo, PAGES
      @remembered = @shows.filter_map do |name, value|
        [name, @b.var(:"_bar_last_#{name}", -1)] unless value.is_a?(Integer)
      end.to_h
    end

    def paint
      @b.dma_fill_rect 0, @top, FirstPerson::ACROSS, HEIGHT, colour(GROUND)
      FIELDS.each do |field|
        @b.draw_text field.label, field.x, @top + LABEL_ROW, colour(LABEL), font: FONT
        field.name == :keys ? draw_the_keys(field) : draw_a_figure(field)
      end
    end

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

    # The keys, as two blocks side by side under their label. Both are drawn dark and the one you
    # are carrying is painted over in its own metal, so the bar always shows two slots and a
    # player learns where to look rather than watching things appear and move.
    def draw_the_keys(field)
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
