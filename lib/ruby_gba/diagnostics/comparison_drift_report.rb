# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    class Comparison
      # THE REPORT OF A DRIFT ON A FRAME, for a comparison on the same tape: both cartridges
      # were on that frame, played with the same presses, so there is one tape, and it plays
      # either of them to that frame again.
      #
      # The folder is named for the frame, so the reports of different drifts can share one
      # place and sort in the order the drifts happened.
      #
      # +tape+ is the presses both cartridges were played on.
      class DriftReport < Report
        TAPE = "to-the-drift.tape"

        def initialize(drift, pictures, tape:, **what_any_report_has)
          super(drift, pictures, **what_any_report_has)
          @tape = tape
        end

        private

        def folder_name = format("frame-%06d", @drift.frame)

        def write_tapes(folder) = @tape.up_to(@drift.frame).write(File.join(folder, TAPE))

        def where_lines
          ["The two cartridges drifted on frame #{@drift.frame}.", lasted_sentence, moment_sentence, differed_sentence("on that frame")]
        end

        def played_lines = ["the tape: #{@tape.frames} frames, recorded on #{@tape.recorded_on_label}"]

        def presses_lines = ["The presses of the last second", *last_second_of_presses(@tape, @drift.frame).map { |line| "  #{line}" }]

        def contents_lines
          ["#{FIRST_PICTURE} and #{SECOND_PICTURE}: the two screens on frame #{@drift.frame}.",
           "#{DIFFERENCE}: the first screen in grey, with each pixel that differed in magenta.",
           "#{TAPE}: every press up to frame #{@drift.frame}. Play it on a cartridge to be on that frame again."]
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
