# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # TWO CARTRIDGES COMPARED AT EACH NAMED MOMENT, after the same script has played each
      # of them on its own.
      #
      # THE OTHER WAY TO COMPARE, AND WHAT IT IS FOR. Fed the same tape, a second cartridge
      # whose door opens a frame late is out of step from that frame on, and every frame
      # after it differs: that is the strict comparison, and the right one for a change
      # that should move nothing. A game being rebuilt to match another is never that
      # close at first. Played by the same SCRIPT, each cartridge presses A when its own
      # text box is up and stops walking at its own door, so each arrives at "the door"
      # however long it took — and the two are compared there. That forgives timing and
      # finds a game that LOOKS different.
      #
      # So there is no frame the two share, and nothing is compared frame by frame: only at
      # the moments the script names, which are the places it says both should be the same.
      #
      # HOW LONG EACH TOOK IS ALWAYS SAID and is only drift when a limit was given: the
      # frame each cartridge reached each moment on comes back with the result, and
      # +frames_apart+ is how far apart they may be, nil for not checked.
      #
      # +sides+ is the two playings, each a Side. +compared+ is what is compared (see
      # Compared), and +left_out+ the moments that are not looked at.
      class AtMoments
        # One cartridge's playing: what playing the script on it handed back, and every
        # named reading as it was at each moment.
        Side = Data.define(:played, :readings)

        def initialize(sides, compared:, frames_apart:, left_out:)
          @first, @second = sides
          @compared = compared
          @frames_apart = frames_apart
          @left_out = left_out
        end

        # The frame each cartridge reached each moment on: each name with the first
        # cartridge's frame and the second's.
        def moments
          @first.played.moments.to_h { |name, frame| [name, [frame, @second.played.moments.fetch(name)]] }
        end

        # How many frames the first cartridge played.
        def first_frames = @first.played.frames

        # Each moment the two differ at, in the order the script names them. The block is
        # handed the drift, the two screens at its moment, and how each cartridge got there
        # (see MomentReport::Reached), and stops the walk by breaking out of it.
        def each_drift
          (moments.keys - @left_out).each do |name|
            differed = differing_at(name)
            next if differed.empty?

            drift = Drift.new(frame: moments.fetch(name).first, moment: name, differed: differed, readings: readings_at(name))
            yield drift, pictures_at(name), reached_at(name)
          end
        end

        # HOW THE TWO WERE COMPARED, AS SENTENCES, for a report a person reads.
        def sentences
          apart = if @frames_apart
                    "The limit on how far apart the two reached a moment was #{frames_in_words(@frames_apart)}."
                  else
                    "How many frames apart the two reached a moment was not checked."
                  end
          said = ["The two were compared at each named moment, after the same script had played each cartridge by itself.", apart]
          said << "These moments were not looked at: #{@left_out.join(', ')}." if @left_out.any?
          said
        end

        private

        def frames_in_words(count) = "#{count} #{count == 1 ? 'frame' : 'frames'}"

        def pictures_at(name) = [@first, @second].map { |side| side.played.pictures.fetch(name) }

        def reached_at(name)
          [@first, @second].map { |side| MomentReport::Reached.new(tape: side.played.tape, frame: side.played.moments.fetch(name)) }
        end

        def readings_at(name)
          @first.readings.fetch(name).to_h { |reading, ours| [reading, [ours, @second.readings.fetch(name).fetch(reading)]] }
        end

        def differing_at(name)
          differed = @compared.differing_between(pictures_at(name), readings_at(name))
          differed << FRAMES_APART if too_far_apart?(name)
          differed
        end

        def too_far_apart?(name)
          ours, theirs = moments.fetch(name)
          !@frames_apart.nil? && (ours - theirs).abs > @frames_apart
        end
      end
    end
  end
end
