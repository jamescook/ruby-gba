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

    attr_reader :face_width, :face_height, :key_width, :key_height

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
