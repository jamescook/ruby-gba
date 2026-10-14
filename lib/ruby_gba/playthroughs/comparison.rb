# frozen_string_literal: true

module RubyGBA
  module Playthroughs
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
    # stops at the first drift unless it is told to carry on. One frame out is nearly always
    # every frame after it out too, so the first is the one worth having — and where it is
    # not, `carrying_on: true` plays to the end and `result.drifts` lists every stretch of
    # drift, which says whether the two came back into step.
    #
    # OR THE SAME SCRIPT ON EACH, asked for with `same: :script`: each cartridge played by
    # the script on its own, and the two compared at each named moment (see AtMoments).
    # That forgives timing, and finds a game that looks different where the same tape finds
    # one that is a frame late.
    #
    # AND NAMED READINGS, where it is given any: numbers read off both running cartridges
    # after every frame, each its own way (see Readings). Which of the two is compared —
    # the picture, the readings, or both — is a list said where the comparison is made (see
    # Compared).
    #
    # AND ONE FRAME OF THE TWO AS A PICTURE, for a person to look at: the two screens side by
    # side with what differs marked (see ScreenPair). A report of a drift holds one, and one
    # can be asked for by itself, of any frame (see PictureRequest).
    #
    # +first+ and +second+ are the two cartridges.
    class Comparison
      # Where the two stopped being alike: the first frame of a stretch of differing frames
      # long enough to count. +moment+ is the last moment named before that frame was played,
      # for a person to place the frame by: nil when none had been. A moment that names the
      # very frame is not before it.
      #
      # (A comparison on the same script has no frame the two share, and finds its drifts
      # AT moments. There +moment+ is the moment the two differed at, +frame+ the frame the
      # first cartridge reached it on, and a drift has no last frame, being one point.) +differed+ is what differed for long enough to count
      # while the drift lasted, in the order each began to: `:picture`, and the name of
      # each reading that did. +readings+ is every named reading on both cartridges on the
      # frame it began, whether it differed or not — each name with its pair of values,
      # the first cartridge's and the second's.
      #
      # +last_frame+ is the last frame of the stretch and +ended+ how it ended, for a
      # comparison that carried on: `:back_in_step` when the next frame was one on which
      # the two were within the settings again, `:not_looked_at` when the next frame was
      # one the comparison was told to leave out, and `:tape_ran_out` when it was still
      # going on the last frame of the tape. A comparison that stops at its first drift
      # never finds out how long it lasted, and there both are nil.
      #
      # +report+ is the folder a report of it was written into (see DriftReport), or nil
      # when the comparison was given nowhere to write one.
      Drift = Data.define(:frame, :last_frame, :ended, :moment, :differed, :readings, :report) do
        def initialize(frame:, moment:, differed:, readings:, last_frame: nil, ended: nil, report: nil) = super

        # The frames of the stretch as a range, first to last, or nil where the last is
        # not known.
        def stretch = last_frame && (frame..last_frame)

        # Whether the two came back within the settings after it.
        def back_in_step? = ended == :back_in_step
      end

      # What a comparison found. +frames+ is how many frames were played, and +drifts+ every
      # stretch of drift that was found, in the order they happened: none when the two
      # never differed, and one at most unless the comparison was asked to carry on.
      #
      # +moments+ is the frame each cartridge reached each named moment on: each name with
      # the first cartridge's frame and the second's. On the same tape those are the same
      # frame, and only the moments reached before the comparison stopped are there. On
      # the same script they are how long each took, and +frames+ is the first cartridge's.
      Result = Data.define(:frames, :moments, :drifts) do
        def drift? = drifts.any?

        # Where the two FIRST stopped being alike — nil when they never did.
        def drift = drifts.first
      end

      # What the picture is called wherever what differed is listed, beside the names of
      # the readings — and what a difference in how long the two took to reach a moment is
      # called there, for a comparison on the same script. No reading can have either name.
      PICTURE = :picture
      FRAMES_APART = :frames_apart

      # A READING'S OWN BLOCK STOPPED WITH AN ERROR, part way through the playing. The
      # message says which reading and which cartridge; the block's own error is its cause.
      class ReadingFailed < StandardError; end

      # A DRIFT WAS FOUND AND ITS REPORT COULD NOT BE WRITTEN. The place is looked at before
      # a frame is played, so this is the rare case of a disk that filled, or something that
      # changed while the two were playing. The finding is the part that cost the playing,
      # so the error still holds it: +drift+ is where the two stopped being alike, and
      # +earlier+ the drifts a comparison that carried on had found before that one, whose
      # reports were written.
      class ReportNotWritten < StandardError
        attr_reader :drift, :earlier

        # +where+ is the sentence that says where the drift was, as its report would have.
        def initialize(drift, where, folder, why)
          @drift = drift
          @earlier = []
          super("#{where} The report of that drift could not be written in #{folder}: #{why}. " \
                "Give `reports_in:` the path of a folder that can be written to.")
        end

        # The same error, holding the drifts found before the one it is about.
        def after(earlier) = tap { @earlier = earlier }
      end

      # +moments+ is the names of the moments the playthrough declares, in order: what the
      # script or the tape says they are, and not a setting a caller can give.
      # +ignoring_frames+ is the stretches of it that are not looked at (see IgnoredFrames),
      # and +how_alike+ what a Likeness takes: how alike two pictures have to be. +readings+
      # is the named readings (see Readings) and +comparing+ the list of what is compared
      # (see Compared), nil for nothing said. +carrying_on+ says whether to play on past the
      # first drift and list every stretch of it. +reports_in+ is a folder to write a
      # report of each drift into (see DriftReport), or nil for none. All of it is read
      # here, so a setting that makes no sense is refused before a frame is played.
      #
      # +same+ says how the second cartridge is fed: `:tape`, the same presses on the same
      # frames as the first, or `:script`, the same script playing each by itself (see
      # AtMoments). +frames_apart+ is for the same script only: how many frames apart the
      # two may reach a moment, nil for not checked.
      #
      # +save+ and +lead_ins+ are where the two start, so that they start in step: one
      # save both cartridges hold as their consoles are switched on, and a lead-in for
      # each — a playthrough played on it first and not counted (see
      # Playthrough.power_on_and_lead_in) — the first cartridge's and then the second's,
      # either of them nil for none.
      def initialize(first, second, moments, ignoring_frames: [], readings: {}, comparing: nil, carrying_on: false,
                     same: :tape, frames_apart: nil, save: nil, lead_ins: nil, reports_in: nil, **how_alike)
        refuse_unknown_settings!(how_alike.keys)
        @moments = moments
        @save = Playthrough.save_from(save)
        refuse_malformed_lead_ins!(lead_ins)
        @lead_ins = lead_ins || [nil, nil]
        @ignored = IgnoredFrames.new(ignoring_frames, moments)
        @likeness = Likeness.new(**how_alike)
        @readings = Readings.new(readings)
        @compared = Compared.new(comparing, @likeness, @readings)
        refuse_non_boolean_carrying_on!(carrying_on)
        @carrying_on = carrying_on
        @same = same
        @frames_apart = frames_apart
        @reports_in = Report.place_for(reports_in)
        refuse_settings_wrong_for_same!(how_alike)
        @handed_over = [first, second]
      end

      # Whether each cartridge is played by the script on its own.
      def same_script? = @same == :script

      # Compare the two on +playthrough+, the way that was asked for: its script played on
      # the first cartridge to learn the presses and both then played on those, or its
      # script played on each by itself.
      def run_playthrough(playthrough)
        return run_script(playthrough) if same_script?

        run(starts.first.played_by(playthrough).tape)
      end

      # WHERE ONE OF THE TWO CARTRIDGES STARTS: the cartridge, the save it holds as its
      # console is switched on, and the lead-in played on it first — the save one that
      # fits this cartridge, and a copy of its own. +which+ is `first` or `second`, for an
      # error to say which of the two it was about.
      Start = Data.define(:which, :cartridge, :save, :lead_in) do
        # A console switched on with the cartridge in it, and led in.
        def console = saying_which_cartridge { Playthrough.power_on_and_lead_in(cartridge, save: save, lead_in: lead_in) }

        # The cartridge played by +playthrough+ from this start.
        def played_by(playthrough, &at_each_moment)
          saying_which_cartridge { playthrough.play(cartridge, save: save, lead_in: lead_in, &at_each_moment) }
        end

        # +tape+ as it is said to start for this cartridge, which is how the tape has to
        # be played to be where the comparison was.
        def tape_said(tape) = tape.started_from(save: save, led_in: !lead_in.nil?)

        # A script that gives up says which of the two cartridges it gave up on: its own
        # error has no way to know there were two.
        private def saying_which_cartridge
          yield
        rescue GaveUp => e
          raise e.exception("On the #{which} cartridge of the comparison: #{e.message}")
        end
      end
      private_constant :Start

      # WHERE THE TWO STARTED, AS SENTENCES, for a report a person reads: nothing at all
      # when both started from power-on with nothing played first.
      private def starting_sentences
        said = []
        said << "Both cartridges started from the same save." if @save
        led_in = starts.select(&:lead_in)
        case led_in.size
        when 2 then said << "Each cartridge was led in before frame 1, by these playthroughs: #{led_in.map { |start| start.lead_in.name }.join(', ')}."
        when 1 then said << "The #{led_in.first.which} cartridge was led in before frame 1, by the playthrough #{led_in.first.lead_in.name}."
        end
        said
      end

      # THE TWO CARTRIDGES, each one the build made or a cartridge file read from its path.
      def cartridges = starts.map(&:cartridge)

      # The first cartridge: the one a script is played on alone, to make the tape both are
      # then played on.
      def first = cartridges.first

      # WHERE EACH OF THE TWO STARTS. The cartridges are looked at together, the first time
      # anything is wanted of either, so a second cartridge that is not there is found
      # before the first is played and not after — and after the settings, which need no
      # cartridge to be wrong. What needs a cartridge to be looked at is looked at here
      # too: a reading that is a variable's name, and a save, which has to fit each.
      private def starts
        @starts ||= begin
          pair = @handed_over.map { |given| Playthrough.cartridge_from(given) }
          @readings.refuse_unreadable_on!(pair)
          pair.zip(%w[first second], @lead_ins).map do |cartridge, which, lead_in|
            Start.new(which: which, cartridge: cartridge, save: save_fitted_to(cartridge, which), lead_in: lead_in)
          end
        end
      end

      # A copy of the save both start from, made to fit +cartridge+, or nil for none.
      private def save_fitted_to(cartridge, which)
        @save && Playthrough.save_fitted_to(cartridge, @save.dup)
      rescue ArgumentError => e
        raise ArgumentError, "The #{which} cartridge of the comparison cannot start from the save. #{e.message}"
      end

      # Play both on +tape+ and compare them, and say what was found.
      def run(tape)
        ignored = @ignored.frame_ranges_on(tape)
        consoles = starts.map(&:console)
        reporter = ->(drift, pictures) { drift_with_report(drift, pictures, tape) } if @reports_in
        pair = SideBySide.new(*consoles, @compared, ignored, carrying_on: @carrying_on, reporter: reporter)
        # A pair that has stopped plays no more frames, and is still told a moment that
        # names the very frame it stopped on: that one it reached. +due+ is the frame the
        # tape is on after each step, so a step is past where the pair stopped when it is
        # due later than the pair has played — a moment after a hold that was cut short
        # included.
        due = 0
        tape.steps.each do |step|
          due += step.frames
          break if pair.stopped? && due > pair.frames

          step.play(pair)
        end
        pair.end_playing
        Result.new(frames: pair.frames, moments: pair.moments, drifts: pair.drifts)
      rescue ReportNotWritten => e
        raise e.after(pair.drifts)
      end

      # THE SETTINGS OF A COMPARISON THAT A PICTURE OF ONE FRAME HAS A USE FOR, each meaning
      # what it means of a comparison: the parts of the screen that are not looked at,
      # which are never marked, and where the two cartridges start.
      PICTURE_SETTINGS = %i[ignoring_rectangles save lead_ins].freeze

      # The comparison that plays the two for a picture of one frame (see PictureRequest),
      # which takes those settings and no others.
      def self.for_picture(first, second, moments, **settings)
        unknown = settings.keys - PICTURE_SETTINGS
        return new(first, second, moments, **settings) if unknown.empty?

        known = [:at, :difference, *PICTURE_SETTINGS].map { |name| "`#{name}:`" }.join(", ")
        raise ArgumentError, "A side-by-side picture has no setting named #{unknown.map(&:inspect).join(' or ')}. " \
                             "Its settings are #{known}."
      end

      # Play each cartridge on +tape+ as far as the frame +request+ asks for, a
      # PictureRequest, and write the picture: their two screens on that frame and where
      # the two differ. Nothing is compared on the way there. The path of the file is
      # handed back.
      def write_picture_of_tape(tape, request)
        to_the_frame = tape.up_to(request.frame_on(tape))
        request.write(screen_pair(starts.map { |start| start.played_by(start.tape_said(to_the_frame)).game.frame_gba }))
      end

      # The same of +playthrough+'s script, played on the first cartridge alone to learn its
      # presses. A moment the script does not name is refused before that; a frame past
      # its end cannot be, since how long a script plays is not known until it has.
      def write_picture_of_playthrough(playthrough, request)
        request.refuse_moment_not_among!(@moments)
        write_picture_of_tape(starts.first.played_by(playthrough).tape, request)
      end

      # Two screens that were kept, with where they differ of the places that are looked at.
      private def screen_pair(pictures) = ScreenPair.new(*pictures, @likeness.differing_places(*pictures))

      # Play +playthrough+'s script on each cartridge by itself, compare the two at each
      # named moment, and say what was found.
      def run_script(playthrough)
        at_moments = AtMoments.new(sides_played_by(playthrough), compared: @compared, frames_apart: @frames_apart,
                                                                 left_out: @ignored.moments_left_out(@moments))
        drifts = []
        at_moments.each_drift do |drift, pictures, reached|
          drifts << (@reports_in ? drift_with_moment_report(drift, pictures, reached, at_moments.sentences) : drift)
          break unless @carrying_on
        end
        Result.new(frames: at_moments.first_frames, moments: at_moments.moments, drifts: drifts)
      rescue ReportNotWritten => e
        raise e.after(drifts)
      end

      # Each cartridge played by the script on its own, the first and then the second.
      # Every reading is read at each moment as the cartridge reaches it, since by the end
      # of the playing it has moved on.
      private def sides_played_by(playthrough)
        starts.each_with_index.map do |start, side|
          readings = {}
          played = start.played_by(playthrough) { |moment, game| readings[moment] = @readings.values_from(game, side) }
          AtMoments::Side.new(played: played, readings: readings)
        end
      end

      # A drift with its report written, and the folder it went into noted on it.
      # +pictures+ is the two screens on the frame it began. The tape is handed over once
      # for each cartridge, said to start the way that cartridge was started.
      private def drift_with_report(drift, pictures, tape)
        report = DriftReport.new(drift, screen_pair(pictures), tapes: starts.map { |start| start.tape_said(tape) },
                                                               **what_any_report_has(@compared.sentences + @ignored.sentences(tape)))
        drift.with(report: report.write_in(@reports_in))
      end

      # The same of a drift at a moment. +reached+ is how each cartridge got there, and
      # +at_moments+ the sentences that say how the two were compared.
      private def drift_with_moment_report(drift, pictures, reached, at_moments)
        report = MomentReport.new(drift, screen_pair(pictures), reached: reached,
                                                                **what_any_report_has(@compared.sentences("A moment") + at_moments))
        drift.with(report: report.write_in(@reports_in))
      end

      private def what_any_report_has(settings) = { cartridges: cartridges, settings: settings + starting_sentences }

      private def refuse_malformed_lead_ins!(given)
        return if given.nil?
        return if given.is_a?(Array) && given.size == 2 && given.all? { |lead_in| lead_in.nil? || lead_in.is_a?(Playthrough) }

        raise ArgumentError, "`lead_ins:` was #{given.inspect}. It must be a list of two, one for each cartridge. Each is a " \
                             "playthrough to play on that cartridge first, or nil for none. " \
                             "Write it like `lead_ins: [nil, past_the_logos]`."
      end

      # Every setting a comparison has: the ones that say how alike, and the ones of its own.
      def self.settings
        [*Likeness::SETTINGS, :ignoring_frames, :readings, :comparing, :carrying_on, :same, :frames_apart, :save, :lead_ins,
         :reports_in]
      end

      # What the two ways of feeding the second cartridge each make no sense with. On the
      # same script there is no frame the two share, so nothing can be said in frames in a
      # row or in frame numbers; and with no moment named there is nowhere to compare. On
      # the same tape the two are always on the same frame, so they cannot be frames apart.
      private def refuse_settings_wrong_for_same!(how_alike)
        unless %i[tape script].include?(@same)
          raise ArgumentError, "`same:` was #{@same.inspect}. It must be `:tape` or `:script`. `:tape` gives both cartridges " \
                               "the same presses on the same frames. `:script` plays the script on each cartridge by itself."
        end
        return refuse_frames_apart_on_tape! unless same_script?

        refuse_invalid_frames_apart!
        refuse_script_with_no_moment!
        refuse_frame_counts_on_script!(how_alike)
        refuse_every_moment_left_out!
        refuse_moments_sharing_one_folder! if @reports_in
      end

      # Leaving out every moment leaves nowhere to compare, the same as naming none, and
      # would find no drift whatever the two cartridges did.
      private def refuse_every_moment_left_out!
        return unless (@moments - @ignored.moments_left_out(@moments)).empty?

        raise ArgumentError, "`ignoring_frames:` leaves out every moment the script names, and the comparison is on the same " \
                             "script. The two cartridges are compared at each named moment, so there is nowhere left to " \
                             "compare them. Leave out fewer moments."
      end

      # A drift at a moment is reported in a folder named for the moment, and many disks do
      # not tell a capital letter from a small one: there, two moments that differ only in
      # their capitals are one folder, and the second report would be written over the first.
      private def refuse_moments_sharing_one_folder!
        first, second = @moments.group_by { |name| name.to_s.downcase }.values.find { |alike| alike.size > 1 }
        return unless first

        raise ArgumentError, "The moments #{first.inspect} and #{second.inspect} differ only in their capital letters. " \
                             "Their reports would be the same folder on a disk that does not tell capital letters from " \
                             "small letters. To write reports, give one of the two moments a different name."
      end

      private def refuse_frames_apart_on_tape!
        return if @frames_apart.nil?

        raise ArgumentError, "`frames_apart:` was given, and the comparison is on the same tape. On the same tape the two " \
                             "cartridges are always on the same frame. To use `frames_apart:`, give `same: :script` too."
      end

      private def refuse_invalid_frames_apart!
        return if @frames_apart.nil? || (@frames_apart.is_a?(Integer) && !@frames_apart.negative?)

        raise ArgumentError, "`frames_apart:` was #{@frames_apart.inspect}. It must be a whole number, 0 or more. It is how " \
                             "many frames apart the two cartridges can reach a moment."
      end

      private def refuse_script_with_no_moment!
        return if @moments.any?

        raise ArgumentError, "The comparison is on the same script, and the script names no moment. On the same script the two " \
                             "cartridges are compared at each named moment, so there is nowhere to compare them. " \
                             "Name a moment in the script, like `moment :at_the_door`."
      end

      private def refuse_frame_counts_on_script!(how_alike)
        if how_alike.key?(:frames_in_a_row)
          raise ArgumentError, "`frames_in_a_row:` was given, and the comparison is on the same script. On the same script the " \
                               "two cartridges are compared at each named moment and not on each frame. Remove `frames_in_a_row:`."
        end
        return unless @ignored.frame_numbers?

        raise ArgumentError, "`ignoring_frames:` holds a range of frame numbers, and the comparison is on the same script. " \
                             "Each cartridge counts its own frames there, so a frame number means a different place on each. " \
                             "Give a range of moments, like `ignoring_frames: [:title..:in_the_world]`."
      end

      private def refuse_non_boolean_carrying_on!(given)
        return if [true, false].include?(given)

        raise ArgumentError, "`carrying_on:` was #{given.inspect}. It must be true or false. Give `carrying_on: true` to " \
                             "play on past the first drift and list each one."
      end

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
          @pixels_looked_at = @looked_at.count(LOOKED_AT)
        end

        # Whether the two running cartridges are showing pictures alike enough.
        #
        # Two pictures that are the same are known to be in one comparison, and two that are
        # not are known to differ in the same one when nothing may: only a comparison that
        # was told some of the screen may differ, or need not be looked at, has to go and
        # count what is out. The emulator does the counting, in one pass over the two
        # pictures, so that costs little more than the frame did.
        def alike?(first, second)
          return true if first.same_picture_as?(second)
          return false if strict?

          share_differing(first, second) <= @share_may_differ
        end

        # The same question of two screens that were kept, each a screenful of colours: the
        # two cartridges are not running side by side, so there is nothing to ask but the
        # pictures themselves.
        def pictures_alike?(first, second)
          return true if first == second || @pixels_looked_at.zero?

          differing_places(first, second).size.fdiv(@pixels_looked_at) <= @share_may_differ
        end

        # Whether +frames+ differing frames, one after another, are drift.
        def drift_after?(frames) = frames >= @frames_in_a_row

        # Where two pictures differ, of the places that are looked at. This is for two
        # screens that were kept, each a screenful of colours a row at a time, and what
        # comes back is where in that list the two hold different colours. (Two consoles
        # still running are asked through `alike?`, which does not copy their screens out.)
        def differing_places(first, second)
          (0...first.size).select { |at| @looked_at.getbyte(at) != 0 && first[at] != second[at] }
        end

        # HOW ALIKE THE PICTURES HAD TO BE, AS SENTENCES, for a report a person reads.
        # +point+ is what the two were compared at, `A frame` or `A moment`.
        def picture_sentences(point)
          looked_at = @pixels_looked_at == WIDTH * HEIGHT ? "pixels" : "pixels that were looked at"
          words = if @share_may_differ.zero?
                    ["#{point} differed when one of the #{looked_at} was a different colour."]
                  else
                    ["#{point} differed when more than #{percent_allowed} percent of the #{looked_at} were a different colour."]
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

        # What a pixel's byte says in the list of what is looked at.
        LOOKED_AT = "\x01".b.freeze
        LEFT_OUT = "\x00".b.freeze
        private_constant :WIDTH, :HEIGHT, :LOOKED_AT, :LEFT_OUT

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

          difference = first.difference_from(second, looked_at: @looked_at)
          (difference ? difference[:count] : 0).fdiv(@pixels_looked_at)
        end

        # Every pixel of the screen, a row at a time, as whether it lies outside all of
        # +rectangles+: a byte for each, the form the emulator takes it in when it is asked
        # to count what differs. Worked out once: rectangles can overlap, and how many pixels
        # are left is what a share is a share of.
        def pixels_outside(rectangles)
          rectangles.each { |rectangle| refuse_rectangle_off_screen!(rectangle) }
          outside = LOOKED_AT * (WIDTH * HEIGHT)
          rectangles.each do |rectangle|
            rectangle.rows.each { |row| outside[(row * WIDTH) + rectangle.x, rectangle.width] = LEFT_OUT * rectangle.width }
          end
          outside.freeze
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
      # at a time, and the two are compared after each. Unless it is carrying on, it stops
      # playing on the frame that makes a drift of it, part way through a hold if that is
      # where it falls.
      #
      # EACH THING THAT IS COMPARED COUNTS ITS OWN FRAMES IN A ROW — the picture, and each
      # reading. Asking for several frames in a row is asking that one frame of flicker is
      # not called drift, and a picture that flickers for one frame followed by a count
      # that is out for the next is two flickers and no drift. Counted together they would
      # be two frames in a row.
      #
      # CARRYING ON. Unless it is told to carry on, the pair stops at its first drift. Told
      # to, it plays on, and that drift is under way for as long as something goes on
      # differing that has differed for long enough: the frame on which nothing has is the
      # frame the two are back within the settings, and the drift's last frame is the one
      # before it.
      #
      # NO FRAME IS IN TWO DRIFTS. A thing that began to differ while a drift was under
      # way, or on the very frame after it, and goes on long enough to count, is the same
      # drift going on and not a second one that began inside the first. That cannot be
      # known on the frame the first thing stops, so a drift is not ended there: its last
      # frame is noted, and it is ended once nothing that could still join it is differing.
      class SideBySide
        attr_reader :frames

        # Every drift that has ended, in the order they happened.
        attr_reader :drifts

        # The frame each moment that has been reached was named on, as a pair: both
        # cartridges are on the same frame here, and a result says it for each.
        attr_reader :moments

        # THE FRAME A THING BEGAN TO DIFFER ON, and what is kept from it: the moment before,
        # every reading, and the two screens when they are kept. All of it is taken on that
        # frame, because by the time the thing has differed long enough to be called drift
        # both consoles have played on and the frame cannot be asked for again.
        Beginning = Data.define(:frame, :moment, :readings, :pictures)

        # A drift that has not ended, with the two screens on the frame it began.
        UnderWay = Struct.new(:drift, :pictures)

        # Where a drift under way seems to have ended, and how: the frame before the one on
        # which nothing had differed for long enough.
        Lull = Data.define(:last_frame, :ended)
        private_constant :Beginning, :UnderWay, :Lull

        # +compared+ is what is compared on each frame, and +ignored+ the stretches that are
        # not looked at, as ranges of frame numbers. +reporter+ is handed each drift as it
        # ends, with the two screens on the frame it began, and hands the drift back with
        # its report noted — or is nil, and then no screen is copied out, which is only
        # worth doing for a report.
        def initialize(first, second, compared, ignored, carrying_on:, reporter:)
          @first = first
          @second = second
          @compared = compared
          @ignored = ignored
          @carrying_on = carrying_on
          @reporter = reporter
          @frames = 0
          @moment = nil
          @began = {}
          @under_way = nil
          @lull = nil
          @drifts = []
          @moments = {}
        end

        def hold(buttons, frames)
          keys = Playthrough.key_mask(buttons)
          frames.times do
            @first.step(1, keys: keys)
            @second.step(1, keys: keys)
            @frames += 1
            extend_or_end_differing_stretches
            return if stopped?
          end
        end

        def mark(name)
          @moment = name
          @moments[name] = [@frames, @frames]
        end

        # Whether the pair plays no further: it has its first drift, and was not told to
        # carry on.
        def stopped? = !@carrying_on && @drifts.any?

        # The tape has run out: end the drift that is under way, if one is. It ended where
        # it had seemed to, or it was still going and ran to the last frame that was played.
        def end_playing
          return end_drift_under_way(@lull.last_frame, @lull.ended) if @lull

          end_drift_under_way(@frames, :tape_ran_out)
        end

        # A thing that differs is remembered from the frame it began to, and is drift once
        # it has differed on every frame since for long enough. A frame on which it is
        # alike again ends its stretch, and so does a frame that is not looked at: nothing
        # is known about that one, so the frames either side of it are not in a row.
        private def extend_or_end_differing_stretches
          seen = @compared.seen_on(@first, @second) unless ignored_frame?
          differed = seen ? seen.differed : []
          @began.keep_if { |thing, _beginning| differed.include?(thing) }
          start_differing_stretches(differed - @began.keys, seen)
          lasted = @began.select { |_thing, beginning| @compared.drift_after?(@frames - beginning.frame + 1) }
          return start_drift_of(lasted) unless @under_way

          lasted.empty? ? end_drift_once_settled : carry_drift_on(lasted.keys)
        end

        # The drift goes on, and whatever has now differed for long enough is part of it —
        # which is also how a drift that had seemed to end turns out not to have.
        private def carry_drift_on(things)
          @lull = nil
          @under_way.drift = @under_way.drift.with(differed: @under_way.drift.differed | things)
        end

        # Nothing has differed for long enough on this frame, so the drift seems to have
        # ended on the frame before. It is ended for good once nothing is still differing
        # that began before this frame was over: such a thing may yet count, and then it
        # was one drift all along.
        private def end_drift_once_settled
          @lull ||= Lull.new(last_frame: @frames - 1, ended: ignored_frame? ? :not_looked_at : :back_in_step)
          return if @began.any? { |_thing, beginning| beginning.frame <= @lull.last_frame + 1 }

          end_drift_under_way(@lull.last_frame, @lull.ended)
        end

        # Things that begin to differ on one frame share what is kept from it.
        private def start_differing_stretches(things, seen)
          return if things.empty?

          pictures = [@first.frame_gba, @second.frame_gba] if @reporter
          beginning = Beginning.new(frame: @frames, moment: @moment, readings: seen.readings, pictures: pictures)
          things.each { |thing| @began[thing] = beginning }
        end

        # +lasted+ is the things that have now differed for long enough, each with the frame
        # it began on. With no drift under way they all began on the same frame: one that
        # began sooner would have been the drift a frame ago.
        private def start_drift_of(lasted)
          beginning = lasted.values.first or return

          drift = Drift.new(frame: beginning.frame, moment: beginning.moment, differed: lasted.keys, readings: beginning.readings)
          @under_way = UnderWay.new(drift, beginning.pictures)
          end_drift_under_way(nil, nil) unless @carrying_on
        end

        # +last_frame+ is the last frame of the drift and +ended+ how it ended — both nil
        # for a pair that stops at its first drift and so never finds out.
        private def end_drift_under_way(last_frame, ended)
          open = @under_way or return

          @under_way = nil
          @lull = nil
          drift = open.drift.with(last_frame: last_frame, ended: ended)
          @drifts << (@reporter ? @reporter.call(drift, open.pictures) : drift)
        end

        private def ignored_frame? = @ignored.any? { |stretch| stretch.cover?(@frames) }
      end
      private_constant :SideBySide
    end
  end
end
