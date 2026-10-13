# frozen_string_literal: true

module RubyGBA
  module Playthroughs
    class Comparison
      # THE STRETCHES OF A PLAYTHROUGH A COMPARISON DOES NOT LOOK AT. Both cartridges are
      # still played through them, since the game has to get to the other side; what differs
      # between the two inside one is simply not counted.
      #
      # What it is for is a part of a game known to differ and not worth being told about: an
      # opening the rebuilt game does not have yet, a screen that shows the time of day.
      #
      # A STRETCH IS A RANGE, of frame numbers (`1..120`) or of the names of two moments
      # (`:title..:in_the_world`). The named form is the one to reach for, because frame
      # numbers all move the day a script gains a step and the moments move with the game.
      #
      # A MOMENT STANDS FOR THE FRAME IT NAMES, so a range of two is the range of those two
      # frames: both of them and every frame between. Both, because of how a moment usually
      # comes to be: a script waits until the title is up and names that frame, which is the
      # first frame OF the title. Leaving it in would report the title as drift on the one
      # frame of it that was not left out.
      #
      # It is a Ruby range and means what one means: three dots leave its last frame out,
      # and an end left open runs to the end of the playthrough, or from its start.
      #
      # +given+ is the stretches as they were written, and +moments+ the names of the moments
      # the playthrough declares, in the order it declares them — so a name it does not have
      # is refused here, before a frame is played.
      class IgnoredFrames
        def initialize(given, moments)
          refuse_malformed_stretches!(given)
          @numbered, @named = given.partition { |stretch| ends_of(stretch).all?(Integer) }
          @numbered.each do |stretch|
            refuse_frames_below_one!(stretch)
            refuse_stretch_holding_no_frame!(stretch, stretch)
          end
          @named.each do |stretch|
            refuse_undeclared_moments!(stretch, moments)
            refuse_moments_out_of_order!(stretch, moments)
          end
        end

        # The stretches as ranges of frame numbers of +tape+, whose moments say which frame
        # each name stands for.
        #
        # Two moments can name the same frame, and three dots between those leave out the
        # only frame there is. That is not known until the frames are, so it is refused here.
        def frame_ranges_on(tape)
          named = tape.moments
          @numbered + @named.map do |stretch|
            between(stretch) { |name| named.fetch(name) }.tap { |frames| refuse_stretch_holding_no_frame!(stretch, frames) }
          end
        end

        # Whether any stretch was written in frame numbers.
        def frame_numbers? = @numbered.any?

        # THE MOMENTS THAT ARE NOT LOOKED AT, for a comparison that only looks at moments:
        # each one a stretch written in moments covers. +moments+ is the playthrough's
        # moments in the order it names them, which is the order the stretches are in.
        def moments_left_out(moments)
          @named.flat_map do |stretch|
            first = stretch.begin ? moments.index(stretch.begin) : 0
            last = stretch.end ? moments.index(stretch.end) : moments.size - 1
            moments[Range.new(first, last, stretch.end && stretch.exclude_end?)]
          end.uniq
        end

        # THE STRETCHES AS SENTENCES, for a report a person reads, and in words a person
        # says: `frames 1 to 120`, and for one written in moments the moments and then the
        # frames those came to on +tape+. A list of one sentence, or of none when no
        # stretch was left out.
        def sentences(tape)
          named = tape.moments
          stretches = @numbered.map { |frames| frames_in_words(frames) } + @named.map do |stretch|
            "#{moments_in_words(stretch)} (#{frames_in_words(between(stretch) { |name| named.fetch(name) })})"
          end
          return [] if stretches.empty?

          ["These stretches of the playthrough were not looked at: #{stretches.join('; ')}."]
        end

        private

        def ends_of(stretch) = [stretch.begin, stretch.end].compact

        # A range of frames as a person says it. Three dots leave the last frame out, so
        # the last frame said is the one before it.
        def frames_in_words(frames)
          first = frames.begin || 1
          return "frame #{first} to the end" unless frames.end

          last = frames.exclude_end? ? frames.end - 1 : frames.end
          first == last ? "frame #{first}" : "frames #{first} to #{last}"
        end

        def moments_in_words(stretch)
          from = stretch.begin ? "the moment #{stretch.begin}" : "the start"
          return "from #{from} to the end" unless stretch.end

          "from #{from} to #{'just before ' if stretch.exclude_end?}the moment #{stretch.end}"
        end

        # A range of moment names as the same range of numbers: the block says what number a
        # name stands for, and an end left open stays open.
        def between(stretch, &number_of)
          first, last = [stretch.begin, stretch.end].map { |name| name && number_of.call(name) }
          Range.new(first, last, stretch.exclude_end?)
        end

        # A stretch runs between two frame numbers or between two moments. One end can be
        # left open; with both open it would be every frame there is, and a comparison that
        # looks at none finds nothing. The whole of what was given is quoted back, because
        # the commonest slip is one range written with no list around it.
        def refuse_malformed_stretches!(given)
          return if given.is_a?(Array) && given.all? { |stretch| range_of_frames_or_moments?(stretch) }

          raise ArgumentError, "`ignoring_frames:` was #{given.inspect}. It must be a list of ranges. Each range is of " \
                               "frame numbers, or of the names of two moments. " \
                               "Write it like `ignoring_frames: [1..120, :title..:in_the_world]`."
        end

        def range_of_frames_or_moments?(stretch)
          stretch.is_a?(Range) && ends_of(stretch).any? && [Integer, Symbol].any? { |kind| ends_of(stretch).all?(kind) }
        end

        def refuse_frames_below_one!(stretch)
          return if ends_of(stretch).all?(&:positive?)

          raise ArgumentError, "`ignoring_frames:` holds #{stretch.inspect}. Frames are counted from 1, so a range of " \
                               "frames cannot go below 1. Use frame numbers of 1 or more."
        end

        def refuse_undeclared_moments!(stretch, moments)
          unknown = ends_of(stretch) - moments
          return if unknown.empty?

          there_are = moments.empty? ? "The playthrough names no moments." : "Its moments are #{moments.map(&:inspect).join(', ')}."
          raise ArgumentError, "`ignoring_frames:` holds #{stretch.inspect}. The playthrough has no moment named " \
                               "#{unknown.map(&:inspect).join(' or ')}. #{there_are}"
        end

        # Which of two moments comes first is known from where the playthrough declares
        # them, before either has a frame. The wrong way round holds nothing, and neither
        # does one moment to itself with three dots, which leave that one frame out.
        def refuse_moments_out_of_order!(stretch, moments)
          first, last = [stretch.begin, stretch.end].map { |name| name && moments.index(name) }
          return if first.nil? || last.nil? || first < last || (first == last && !stretch.exclude_end?)

          raise_holding_no_frame!(stretch, if first > last
                                             backwards_range_message(stretch)
                                           else
                                             "Three dots leave the last frame out, and both ends are the moment " \
                                               "#{stretch.end.inspect}. Use two dots."
                                           end)
        end

        # +stretch+ is the range as it was written and +frames+ the same range in frame
        # numbers. The wrong way round holds nothing, and neither does one whose two ends
        # are the same frame when three dots leave that frame out.
        def refuse_stretch_holding_no_frame!(stretch, frames)
          first = frames.begin || 1
          last = frames.end or return
          return if first < last || (first == last && !frames.exclude_end?)

          raise_holding_no_frame!(stretch, if first > last
                                             backwards_range_message(stretch)
                                           else
                                             "Three dots leave the last frame out, and here that is the only frame: " \
                                               "frame #{last}. Use two dots."
                                           end)
        end

        def backwards_range_message(stretch)
          "It ends before it starts. Write the earlier end first, like " \
            "#{Range.new(stretch.end, stretch.begin, stretch.exclude_end?).inspect}."
        end

        def raise_holding_no_frame!(stretch, advice)
          raise ArgumentError, "`ignoring_frames:` holds #{stretch.inspect}. That range holds no frame. #{advice}"
        end
      end
    end
  end
end
