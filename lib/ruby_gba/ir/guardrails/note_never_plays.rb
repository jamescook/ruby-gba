# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A note in a song that the music can never reach.
        #
        # Each part of a song is a list of notes, each on the frame it starts. The player keeps
        # one place in each list and, every frame, looks at the ONE note there: due now, it
        # plays and the place moves on; not due, nothing happens. That is what keeps a long
        # song as cheap as a short one — and it means a part's notes must each start on a later
        # frame than the one before, and before the song comes round again. A note that does
        # not is never due, so the part stops there and stays silent until the song starts over.
        #
        # A song block makes one by a note shorter than a frame — a fast enough tempo rounds it
        # to nothing, so the next note starts on the same frame. A Score cannot: its notes are
        # put in order, one to a frame, before they reach here.
        class NoteNeverPlays
          NAME = :note_never_plays
          PLAIN_NAME = "a song note that the music can never reach"

          def detect(program)
            program.walk.select { |node| node.kind == :song }.flat_map do |song|
              song.voices.each_with_index.filter_map do |part, index|
                problem = first_problem(part.events, song.total_frames)
                next unless problem

                message = "#{SongWords.part(program, song, index).sub(/\A./, &:upcase)} of " \
                          "#{SongWords.song(program, song)} #{describe(problem, song.total_frames)}"
                Finding.new(check: NAME, severity: :error, message: message, node: song)
              end
            end
          end

          private

          # The first note the player cannot reach, and why.
          def first_problem(events, total)
            before = nil
            events.each do |frame, *|
              return [:before_the_start, frame] if frame.negative?
              return [:same_frame, frame] if before == frame
              return [:out_of_order, frame, before] if before && frame < before
              return [:past_the_end, frame] if frame >= total

              before = frame
            end
            nil
          end

          def describe(problem, total)
            kind, frame, before = problem
            too_short = "This error occurs when a note is shorter than one frame (1/#{Score::FRAME_RATE} of a " \
                        "second). To fix this, make the note longer, or make the tempo slower."
            stuck = "The part then stays silent until the song starts again."
            case kind
            when :same_frame
              "has two notes that start on the same frame, #{SongWords.seconds(frame)} into the song. The " \
                "music starts one note of a part on each frame, at most. So the second note never plays. " \
                "#{stuck} #{too_short}"
            when :out_of_order
              "has a note #{SongWords.seconds(frame)} into the song, after a note at " \
                "#{SongWords.seconds(before)}. The music plays the notes of a part in time order. So this note " \
                "never plays. #{stuck} To fix this, put the notes of the part in time order."
            when :before_the_start
              "has a note on frame #{frame}, before the song starts. The music plays a song from frame 0. So " \
                "this note never plays. #{stuck} To fix this, start every note on frame 0 or later."
            when :past_the_end
              "has a note that starts #{SongWords.seconds(frame)} into the song. The song is only " \
                "#{SongWords.seconds(total)} long. It starts again before that note, so that note never " \
                "plays. #{too_short}"
            end
          end
        end
      end
    end
  end
end
