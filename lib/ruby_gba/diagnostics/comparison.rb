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
    # AND NAMED READINGS, where it is given any: numbers read off both running cartridges
    # after every frame, each its own way (see Readings). Which of the two is compared —
    # the picture, the readings, or both — is a list said where the comparison is made (see
    # Compared).
    #
    # +first+ and +second+ are the two cartridges.
    class Comparison
      # Where the two stopped being alike: the first frame of a stretch of differing frames
      # long enough to count. +moment+ is the last moment named before that frame was played,
      # for a person to place the frame by: nil when none had been. A moment that names the
      # very frame is not before it. +differed+ is what differed from that frame for as
      # long as it took to count: `:picture`, and the name of each reading that did.
      # +readings+ is every named reading on both cartridges on that frame, whether it
      # differed or not — each name with its pair of values, the first cartridge's and the
      # second's. +report+ is the folder a report of
      # it was written into (see DriftReport), or nil when the comparison was given nowhere
      # to write one.
      Drift = Data.define(:frame, :moment, :differed, :readings, :report) do
        def initialize(frame:, moment:, differed:, readings:, report: nil) = super
      end

      # What a comparison found. +frames+ is how many frames were played, and +drift+ where
      # the two stopped being alike — nil when they never did.
      Result = Data.define(:frames, :drift) do
        def drift? = !drift.nil?
      end

      # What the picture is called wherever what differed is listed, beside the names of
      # the readings.
      PICTURE = :picture

      # A READING'S OWN BLOCK STOPPED WITH AN ERROR, part way through the playing. The
      # message says which reading and which cartridge; the block's own error is its cause.
      class ReadingFailed < StandardError; end

      # A DRIFT WAS FOUND AND ITS REPORT COULD NOT BE WRITTEN. The place is looked at before
      # a frame is played, so this is the rare case of a disk that filled, or something that
      # changed while the two were playing. The finding is the part that cost the playing,
      # so the error still holds it: +drift+ is where the two stopped being alike.
      class ReportNotWritten < StandardError
        attr_reader :drift

        def initialize(drift, folder, why)
          @drift = drift
          super("The two cartridges drifted on frame #{drift.frame}. The report of that drift could not be written " \
                "in #{folder}: #{why}. Give `reports_in:` the path of a folder that can be written to.")
        end
      end

      # +moments+ is the names of the moments the playthrough declares, in order: what the
      # script or the tape says they are, and not a setting a caller can give.
      # +ignoring_frames+ is the stretches of it that are not looked at (see IgnoredFrames),
      # and +how_alike+ what a Likeness takes: how alike two pictures have to be. +readings+
      # is the named readings (see Readings) and +comparing+ the list of what is compared
      # (see Compared), nil for nothing said. +reports_in+ is a folder to write a report of
      # the drift into (see DriftReport), or nil for none. All of it is read here, so a
      # setting that makes no sense is refused before a frame is played.
      def initialize(first, second, moments, ignoring_frames: [], readings: {}, comparing: nil, reports_in: nil, **how_alike)
        refuse_unknown_settings!(how_alike.keys)
        @ignored = IgnoredFrames.new(ignoring_frames, moments)
        @likeness = Likeness.new(**how_alike)
        @readings = Readings.new(readings)
        @compared = Compared.new(comparing, @likeness, @readings)
        @reports_in = DriftReport.place_for(reports_in)
        @handed_over = [first, second]
      end

      # THE TWO CARTRIDGES, each one the build made or a cartridge file read from its path.
      # They are looked at together, the first time either is wanted, so a second cartridge
      # that is not there is found before the first is played and not after — and after the
      # settings, which need no cartridge to be wrong. A reading that is a variable's name
      # is looked up on them here too, since that is the first moment there is a cartridge
      # to look it up on.
      def cartridges
        @cartridges ||= @handed_over.map { |given| Playthrough.cartridge_from(given) }
                                    .tap { |pair| @readings.refuse_unreadable_on!(pair) }
      end

      # The first cartridge: the one a script is played on alone, to make the tape both are
      # then played on.
      def first = cartridges.first

      # Play both on +tape+ and compare them, and say what was found.
      def run(tape)
        ignored = @ignored.frame_ranges_on(tape)
        consoles = cartridges.map { |cartridge| Playthrough.power_on(cartridge) }
        pair = SideBySide.new(*consoles, @compared, ignored, keeping_pictures: !@reports_in.nil?)
        tape.steps.each do |step|
          step.play(pair)
          break if pair.drift
        end
        Result.new(frames: pair.frames, drift: drift_with_report(pair, tape))
      end

      # The drift the pair found, with a report of it written if there is somewhere to
      # write one, and the folder it went into noted on the drift.
      private def drift_with_report(pair, tape)
        drift = pair.drift
        return drift unless drift && @reports_in

        report = DriftReport.new(drift, pair.pictures_at_drift, tape: tape, cartridges: cartridges,
                                                               pixels_differing: @likeness.differing_places(*pair.pictures_at_drift),
                                                               settings: @compared.sentences + @ignored.sentences(tape))
        drift.with(report: report.write_in(@reports_in))
      end

      # Every setting a comparison has: the ones that say how alike, and the ones of its own.
      def self.settings = [*Likeness::SETTINGS, :ignoring_frames, :readings, :comparing, :reports_in]

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
          @ignored_rectangles = ignoring_rectangles.map { |corner_and_size| Rectangle.new(*corner_and_size) }
          @looked_at = pixels_outside(@ignored_rectangles)
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

        # Where two pictures differ, of the places that are looked at. This is for two
        # screens that were kept, each a screenful of colours a row at a time, and what
        # comes back is where in that list the two hold different colours. (Two consoles
        # still running are asked through `alike?`, which does not copy their screens out.)
        def differing_places(first, second)
          (0...first.size).select { |at| @looked_at[at] && first[at] != second[at] }
        end

        # HOW ALIKE THE PICTURES HAD TO BE, AS SENTENCES, for a report a person reads.
        def picture_sentences
          looked_at = @pixels_looked_at == WIDTH * HEIGHT ? "pixels" : "pixels that were looked at"
          words = if @share_may_differ.zero?
                    ["A frame differed when one of the #{looked_at} was a different colour."]
                  else
                    ["A frame differed when more than #{percent_allowed} percent of the #{looked_at} were a different colour."]
                  end
          words << "These parts of the screen were not looked at: #{@ignored_rectangles.map(&:in_words).join('; ')}." if @ignored_rectangles.any?
          words
        end

        # How many differing frames in a row it took, as a sentence, where that was more
        # than one. It is its own sentence because it holds whatever is compared, a reading
        # as much as the picture.
        def run_length_sentences
          @frames_in_a_row > 1 ? ["#{@frames_in_a_row} frames in a row had to differ before it was drift."] : []
        end

        WIDTH = Console::Hardware::SCREEN_WIDTH
        HEIGHT = Console::Hardware::SCREEN_HEIGHT
        private_constant :WIDTH, :HEIGHT

        # A part of the screen, by its top left corner and its size.
        Rectangle = Data.define(:x, :y, :width, :height) do
          def columns = x...(x + width)
          def rows = y...(y + height)
          def on_screen? = x >= 0 && y >= 0 && columns.end <= WIDTH && rows.end <= HEIGHT
          def in_words = "#{width} by #{height} pixels from column #{x}, row #{y}"
        end
        private_constant :Rectangle

        private

        def strict? = @share_may_differ.zero? && @pixels_looked_at == WIDTH * HEIGHT

        # The share as a percentage a person reads: `1`, `0.5`, and for one pixel of the
        # screen `0.0026041667`. It is written out in full and never with an exponent,
        # which is how a very small number is otherwise printed.
        def percent_allowed = format("%.10f", @share_may_differ * 100.0).sub(/\.?0+\z/, "")

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
      # at a time, and the two are compared after each. It stops playing on the frame that
      # makes a drift of it, part way through a hold if that is where it falls.
      #
      # EACH THING THAT IS COMPARED COUNTS ITS OWN FRAMES IN A ROW — the picture, and each
      # reading. Asking for several frames in a row is asking that one frame of flicker is
      # not called drift, and a picture that flickers for one frame followed by a count
      # that is out for the next is two flickers and no drift. Counted together they would
      # be two frames in a row.
      class SideBySide
        attr_reader :frames, :drift

        # The two screens on the frame the drift began, each a screenful of colours. Nil
        # unless the pair was told to keep them: copying two screens out is only worth
        # doing for a report.
        attr_reader :pictures_at_drift

        # THE FRAME A THING BEGAN TO DIFFER ON, and what is kept from it: the moment before,
        # every reading, and the two screens when they are kept. All of it is taken on that
        # frame, because by the time the thing has differed long enough to be called drift
        # both consoles have played on and the frame cannot be asked for again.
        Beginning = Data.define(:frame, :moment, :readings, :pictures)
        private_constant :Beginning

        # +compared+ is what is compared on each frame, and +ignored+ the stretches that are
        # not looked at, as ranges of frame numbers.
        def initialize(first, second, compared, ignored, keeping_pictures:)
          @first = first
          @second = second
          @compared = compared
          @ignored = ignored
          @keeping_pictures = keeping_pictures
          @frames = 0
          @moment = nil
          @began = {}
          @pictures_at_drift = nil
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

        # A thing that differs is remembered from the frame it began to, and is the drift
        # once it has differed on every frame since for long enough. A frame on which it is
        # alike again ends its stretch, and so does a frame that is not looked at: nothing
        # is known about that one, so the frames either side of it are not in a row.
        private def extend_or_end_differing_stretch
          seen = @compared.seen_on(@first, @second) unless ignored_frame?
          differed = seen ? seen.differed : []
          @began.keep_if { |thing, _beginning| differed.include?(thing) }
          start_differing_stretches(differed - @began.keys, seen)
          record_drift_of(@began.select { |_thing, beginning| @compared.drift_after?(@frames - beginning.frame + 1) })
        end

        # Things that begin to differ on one frame share what is kept from it.
        private def start_differing_stretches(things, seen)
          return if things.empty?

          pictures = [@first.frame_gba, @second.frame_gba] if @keeping_pictures
          beginning = Beginning.new(frame: @frames, moment: @moment, readings: seen.readings, pictures: pictures)
          things.each { |thing| @began[thing] = beginning }
        end

        # +lasted+ is the things that have now differed for long enough, each with the frame
        # it began on. They all began on the same frame: one that began sooner would have
        # been the drift a frame ago.
        private def record_drift_of(lasted)
          beginning = lasted.values.first or return

          @drift = Drift.new(frame: beginning.frame, moment: beginning.moment, differed: lasted.keys, readings: beginning.readings)
          @pictures_at_drift = beginning.pictures
        end

        private def ignored_frame? = @ignored.any? { |stretch| stretch.cover?(@frames) }
      end
      private_constant :SideBySide
    end
  end
end
