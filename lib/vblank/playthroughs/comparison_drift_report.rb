# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # THE REPORT OF A DRIFT ON A FRAME, for a comparison on the same tape: both cartridges
      # were on that frame, played with the same presses.
      #
      # ONE TAPE, UNLESS THE TWO WERE STARTED DIFFERENTLY. The presses are the same for
      # both, so where both started the same way there is one tape and it plays either of
      # them to that frame again. A tape also says where it starts, though, and a
      # cartridge that was led in is not started as one that was not: then there are two
      # tapes, the same presses under two headings, and each plays its own cartridge.
      #
      # The folder is named for the frame, so the reports of different drifts can share one
      # place and sort in the order the drifts happened.
      #
      # +tapes+ is the presses both were played on, once for each cartridge, each said to
      # start the way that cartridge was started.
      class DriftReport < Report
        TAPE = "to-the-drift.tape"
        FIRST_TAPE = "first-to-the-drift.tape"
        SECOND_TAPE = "second-to-the-drift.tape"

        def initialize(drift, screens, tapes:, **what_any_report_has)
          super(drift, screens, **what_any_report_has)
          @tapes = tapes
          @tape = tapes.first
        end

        private

        def folder_name = format("frame-%06d", @drift.frame)

        def started_alike? = @tapes.uniq.size == 1

        def write_tapes(folder)
          names = started_alike? ? [TAPE] : [FIRST_TAPE, SECOND_TAPE]
          names.zip(@tapes) { |name, tape| tape.up_to(@drift.frame).write(File.join(folder, name)) }
        end

        def where_lines
          ["The two cartridges drifted on frame #{@drift.frame}.", lasted_sentence, moment_sentence, differed_sentence("on that frame")]
        end

        def played_lines = ["the tape: #{@tape.frames} frames, recorded on #{@tape.recorded_on_label}"]

        def presses_lines = ["The presses of the last second", *last_second_of_presses(@tape, @drift.frame).map { |line| "  #{line}" }]

        def contents_lines
          ["#{FIRST_PICTURE} and #{SECOND_PICTURE}: the two screens on frame #{@drift.frame}.",
           *difference_lines,
           tapes_line]
        end

        def tapes_line
          every_press = "every press up to frame #{@drift.frame}"
          if started_alike?
            return "#{TAPE}: #{every_press}. Play it on a cartridge, started as the tape says, to be on that frame again."
          end

          "#{FIRST_TAPE} and #{SECOND_TAPE}: #{every_press}, the same for both. The two cartridges were started differently, " \
            "and each tape says how its own was started. Play each on its own cartridge to be on that frame again."
        end

        # How long the drift lasted and how it ended, which only a comparison that carried
        # on finds out.
        def lasted_sentence
          last = @drift.last_frame
          case @drift.ended
          when :back_in_step then "The drift lasted to frame #{last}. The two were back within the settings on frame #{last + 1}."
          when :not_looked_at then "The drift lasted to frame #{last}. Frame #{last + 1} was not looked at."
          when :tape_ran_out then "The drift lasted to frame #{last}, the last frame of the tape."
          else "The comparison stopped at this drift, so how long it lasted is not known."
          end
        end

        def moment_sentence
          return "No moment was named before that frame." unless @drift.moment

          "The moment named before that frame was #{@drift.moment}, on frame #{@tape.moments.fetch(@drift.moment)}."
        end
      end
    end
  end
end
