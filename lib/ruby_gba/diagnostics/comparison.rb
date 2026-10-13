# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # TWO CARTRIDGES PLAYED SIDE BY SIDE ON THE SAME PRESSES, and where their pictures stop
    # being the same.
    #
    #   result = walk.compare(ours, theirs)
    #   result.drift?         # did they ever differ?
    #   result.drift.frame    # the first frame they did
    #   result.drift.moment   # the named moment before it
    #
    # WHAT IT IS FOR. Somebody rebuilding an existing game wants to know where their cartridge
    # has drifted from the original; a framework change that moves something a frame early
    # wants catching without two people squinting at two screens. Both are the same question:
    # given the same game to play, on which frame do these two first show something different?
    #
    # THE SAME PRESSES ON THE SAME FRAMES. What is compared is a tape: which buttons were down
    # on each frame. A script is played on the first cartridge alone to make one, so where the
    # script watches the game — "walk right until the door" — it is the first cartridge it
    # watched, and the second is handed exactly the walk the first one took. That is the
    # strict comparison: a second cartridge whose door is a frame further off is still walking
    # when the first has stopped, and the two differ from that frame on.
    #
    # EVERY PIXEL OF EVERY FRAME, unless told how alike is alike enough (see Likeness), and it
    # stops at the first drift. One frame out is nearly always every frame after it out too,
    # so the first is the one worth having.
    #
    # +first+ and +second+ are the two cartridges.
    class Comparison
      # Where the two stopped being alike: the first frame of a stretch of differing frames
      # long enough to count. +moment+ is the last moment named before that frame was played,
      # for a person to place the frame by: nil when none had been. A moment that names the
      # very frame is not before it.
      Drift = Data.define(:frame, :moment)

      # What a comparison found. +frames+ is how many frames were played, and +drift+ where
      # the two stopped being alike — nil when they never did.
      Result = Data.define(:frames, :drift) do
        def drift? = !drift.nil?
      end

      # +moments+ is the names of the moments the playthrough declares, in order: what the
      # script or the tape says they are, and not a setting a caller can give.
      # +ignoring_frames+ is the stretches of it that are not looked at (see IgnoredFrames),
      # and +how_alike+ what a Likeness takes: how alike two pictures have to be. All of it is
      # read here, so a setting that makes no sense is refused before a frame is played.
      def initialize(first, second, moments, ignoring_frames: [], **how_alike)
        refuse_unknown_settings!(how_alike.keys)
        @first = first
        @second = second
        @ignored = IgnoredFrames.new(ignoring_frames, moments)
        @likeness = Likeness.new(**how_alike)
      end

      # Play both on +tape+ and compare them, and say what was found.
      def run(tape)
        ignored = @ignored.frame_ranges_on(tape)
        pair = SideBySide.new(Playthrough.power_on(@first), Playthrough.power_on(@second), @likeness, ignored)
        tape.steps.each do |step|
          step.play(pair)
          break if pair.drift
        end
        Result.new(frames: pair.frames, drift: pair.drift)
      end

      # Every setting a comparison has: the ones that say how alike, and the one of its own.
      def self.settings = [*Likeness::SETTINGS, :ignoring_frames]

      private def refuse_unknown_settings!(given)
        unknown = given - Likeness::SETTINGS
        return if unknown.empty?

        raise ArgumentError, "A comparison has no setting named #{unknown.map(&:inspect).join(' or ')}. " \
                             "Its settings are #{Comparison.settings.map { |name| "`#{name}:`" }.join(', ')}."
      end

      # HOW ALIKE TWO PICTURES HAVE TO BE to count as the same. With nothing said, every pixel
      # has to be the same colour: the strict comparison.
      #
      # That is the right question of a framework change, and the wrong one of a game being
      # rebuilt to match another, where one stray pixel several minutes in would otherwise
      # hide everything after it.
      #
      # +ignoring_rectangles+ is parts of the screen, each [x, y, width, height], whose pixels
      # are not looked at: a part that has not been drawn yet. +share_may_differ+ is the share
      # of the pixels that ARE looked at that may be a different colour, from 0 to 1, before a
      # frame counts as differing. +frames_in_a_row+ is how many frames running have to differ
      # before it is drift, so that one frame of flicker is not.
      class Likeness
        SETTINGS = %i[share_may_differ frames_in_a_row ignoring_rectangles].freeze

        def initialize(share_may_differ: 0, frames_in_a_row: 1, ignoring_rectangles: [])
          refuse_share_outside_range!(share_may_differ)
          refuse_invalid_run_length!(frames_in_a_row)
          refuse_malformed_rectangles!(ignoring_rectangles)
          @share_may_differ = share_may_differ
          @frames_in_a_row = frames_in_a_row
          @looked_at = pixels_outside(ignoring_rectangles.map { |corner_and_size| Rectangle.new(*corner_and_size) })
          @pixels_looked_at = @looked_at.count(true)
        end

        # Whether the two running cartridges are showing pictures alike enough.
        #
        # Two pictures that are the same are known to be in one comparison, and two that are
        # not are known to differ in the same one when nothing may: only a comparison that
        # was told some of the screen may differ, or need not be looked at, has to go and
        # count what is out.
        def alike?(first, second)
          return true if first.same_picture_as?(second)
          return false if strict?

          share_differing(first, second) <= @share_may_differ
        end

        # Whether +frames+ differing frames, one after another, are drift.
        def drift_after?(frames) = frames >= @frames_in_a_row

        WIDTH = Console::Hardware::SCREEN_WIDTH
        HEIGHT = Console::Hardware::SCREEN_HEIGHT
        private_constant :WIDTH, :HEIGHT

        # A part of the screen, by its top left corner and its size.
        Rectangle = Data.define(:x, :y, :width, :height) do
          def columns = x...(x + width)
          def rows = y...(y + height)
          def on_screen? = x >= 0 && y >= 0 && columns.end <= WIDTH && rows.end <= HEIGHT
        end
        private_constant :Rectangle

        private

        def strict? = @share_may_differ.zero? && @pixels_looked_at == WIDTH * HEIGHT

        # The share of the pixels looked at that are a different colour in the two pictures.
        # It is the shares that are compared and never a count worked back out of one: a
        # share written as a decimal, multiplied back up by the pixels, can come out a hair
        # under the count it was worked out from.
        def share_differing(first, second)
          return 0 if @pixels_looked_at.zero?

          first.pixels_differing_from(second).count { |x, y| @looked_at[(y * WIDTH) + x] }.fdiv(@pixels_looked_at)
        end

        # Every pixel of the screen, a row at a time, as whether it lies outside all of
        # +rectangles+. Worked out once: rectangles can overlap, and how many pixels are left
        # is what a share is a share of.
        def pixels_outside(rectangles)
          rectangles.each { |rectangle| refuse_rectangle_off_screen!(rectangle) }
          Array.new(WIDTH * HEIGHT, true).tap do |outside|
            rectangles.each do |rectangle|
              rectangle.rows.each { |row| rectangle.columns.each { |column| outside[(row * WIDTH) + column] = false } }
            end
          end
        end

        # A share is a plain number from 0 to 1. The comparisons are written out because the
        # things that are not one — a number that is not a number, a complex one — answer
        # neither, where asking whether they lie between 0 and 1 would stop with an error
        # of Ruby's own.
        def refuse_share_outside_range!(share)
          return if share.is_a?(Numeric) && share.real? && share >= 0 && share <= 1

          raise ArgumentError, "`share_may_differ:` was #{share.inspect}. It must be a number from 0 to 1. " \
                               "It is the share of the pixels that can differ: 0.01 is one pixel in a hundred."
        end

        def refuse_invalid_run_length!(frames)
          return if frames.is_a?(Integer) && frames >= 1

          raise ArgumentError, "`frames_in_a_row:` was #{frames.inspect}. It must be a whole number, 1 or more. " \
                               "It is how many frames in a row must differ before the comparison calls it drift."
        end

        # The whole of what was given is quoted back, because the commonest slip is one
        # rectangle written with no list around it.
        def refuse_malformed_rectangles!(given)
          return if given.is_a?(Array) && given.all? { |written| well_formed_rectangle?(written) }

          raise ArgumentError, "`ignoring_rectangles:` was #{given.inspect}. It must be a list of rectangles. " \
                               "Each rectangle is four whole numbers: [x, y, width, height]. The width and the height " \
                               "must be 1 or more. One rectangle is written like `ignoring_rectangles: [[0, 128, 240, 32]]`."
        end

        def well_formed_rectangle?(written)
          written.is_a?(Array) && written.size == 4 && written.all?(Integer) && written.last(2).all?(&:positive?)
        end

        def refuse_rectangle_off_screen!(rectangle)
          return if rectangle.on_screen?

          raise ArgumentError, "`ignoring_rectangles:` holds #{rectangle.to_h.values.inspect}. A part of that rectangle is " \
                               "off the screen. The screen is #{WIDTH} pixels wide and #{HEIGHT} pixels high. " \
                               "Give a rectangle that is on the screen."
        end
      end

      # TWO RUNNING CARTRIDGES PLAYED AS ONE. The lines of a tape play themselves on this as
      # they do on a single playing: a hold goes to both with the same buttons down, a frame
      # at a time, and the two pictures are compared after each. It stops playing on the
      # frame that makes a drift of it, part way through a hold if that is where it falls.
      class SideBySide
        attr_reader :frames, :drift

        # +ignored+ is the stretches that are not looked at, as ranges of frame numbers.
        def initialize(first, second, likeness, ignored)
          @first = first
          @second = second
          @likeness = likeness
          @ignored = ignored
          @frames = 0
          @moment = nil
          @differing_since = nil
          @drift = nil
        end

        def hold(buttons, frames)
          keys = Playthrough.key_mask(buttons)
          frames.times do
            @first.step(1, keys: keys)
            @second.step(1, keys: keys)
            @frames += 1
            extend_or_end_differing_stretch
            return if @drift
          end
        end

        def mark(name) = @moment = name

        # A stretch of differing frames is remembered from its first frame — where it began,
        # and the moment before that — and is the drift once it has lasted long enough. A
        # frame alike again ends the stretch, and so does a frame that is not looked at:
        # nothing is known about that one, so the frames either side of it are not in a row.
        private def extend_or_end_differing_stretch
          return @differing_since = nil if ignored_frame? || @likeness.alike?(@first, @second)

          @differing_since ||= Drift.new(frame: @frames, moment: @moment)
          @drift = @differing_since if @likeness.drift_after?(@frames - @differing_since.frame + 1)
        end

        private def ignored_frame? = @ignored.any? { |stretch| stretch.cover?(@frames) }
      end
      private_constant :SideBySide
    end
  end
end
