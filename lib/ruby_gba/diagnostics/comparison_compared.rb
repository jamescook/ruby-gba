# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    class Comparison
      # WHAT A COMPARISON COMPARES ON EACH FRAME: the picture, the named readings, or both.
      #
      # It is a list, said where the comparison is made, and with nothing said it is the
      # picture and whatever readings were given. The picture is compared by how alike it
      # has to be (see Likeness); a reading has to be the same on both.
      #
      # WHY THE PICTURE CAN BE LEFT OUT. Somebody rebuilding a game gets its numbers right
      # long before its pictures: the hero walks at the right speed weeks before the scenery
      # is drawn. Comparing the readings alone says whether the game underneath has drifted
      # while every frame of the picture still differs.
      #
      # WHY READINGS CAN BE GIVEN AND NOT COMPARED. They are still read, and a drift says
      # what each was on both cartridges — which is often the quickest way to see what a
      # difference in the picture comes from.
      #
      # +comparing+ is the list as it was written, or nil for nothing said.
      class Compared
        KINDS = [PICTURE, :readings].freeze

        # What two running cartridges showed on one frame: +differed+ is what was not the
        # same — `:picture`, and the name of each compared reading that was not — and
        # +readings+ every named reading on both, each name with its pair of values.
        Seen = Data.define(:differed, :readings)

        def initialize(comparing, likeness, readings)
          @likeness = likeness
          @readings = readings
          refuse_senseless_list!(comparing)
          @kinds = comparing || [PICTURE, *(:readings if readings.any?)]
        end

        # Look at two running cartridges on the frame they have just played. Every reading
        # is read, once, whether or not readings are compared: a drift says them all, and a
        # block that cannot read its cartridge is found on the first frame and not on the
        # frame of a drift.
        def seen_on(first, second)
          readings = @readings.values_on(first, second)
          differed = []
          differed << PICTURE if picture? && !@likeness.alike?(first, second)
          differed.concat(Readings.differing(readings)) if readings?
          Seen.new(differed: differed, readings: readings)
        end

        # The same question of two cartridges that are not running side by side, asked of
        # what was kept from each: +pictures+ is their two screens, and +readings+ every
        # named reading as its pair of values.
        def differing_between(pictures, readings)
          differed = []
          differed << PICTURE if picture? && !@likeness.pictures_alike?(*pictures)
          differed.concat(Readings.differing(readings)) if readings?
          differed
        end

        # Whether +frames+ differing frames, one after another, are drift.
        def drift_after?(frames) = @likeness.drift_after?(frames)

        # WHAT WAS COMPARED AND HOW ALIKE IT HAD TO BE, AS SENTENCES, for a report a person
        # reads. A comparison's numbers mean nothing read against the wrong settings, so it
        # says them every time. +point+ is what the two were compared at: `A frame`, or
        # `A moment` for a comparison on the same script.
        def sentences(point = "A frame")
          [
            *(picture? ? @likeness.picture_sentences(point) : "The picture was not compared."),
            *readings_sentences(point),
            *@likeness.run_length_sentences,
          ]
        end

        private

        def picture? = @kinds.include?(PICTURE)
        def readings? = @kinds.include?(:readings)

        def readings_sentences(point)
          return [] unless @readings.any?
          return ["The readings were read and were not compared."] unless readings?

          ["#{point} differed when one of these readings was not the same on the two cartridges: #{@readings.names.join(', ')}."]
        end

        def refuse_senseless_list!(comparing)
          return if comparing.nil?

          unless comparing.is_a?(Array)
            raise ArgumentError, "`comparing:` was #{comparing.inspect}. It must be a list of what to compare: `:picture`, " \
                                 "`:readings`, or both. Write it like `comparing: [:readings]`."
          end
          if comparing.empty?
            raise ArgumentError, "`comparing:` was []. A comparison must compare at least one thing. " \
                                 "Give `:picture`, `:readings`, or both."
          end
          unknown = comparing - KINDS
          unless unknown.empty?
            raise ArgumentError, "`comparing:` holds #{unknown.map(&:inspect).join(' and ')}. A comparison can compare " \
                                 "`:picture` and `:readings`."
          end
          return unless comparing.include?(:readings) && !@readings.any?

          raise ArgumentError, "`comparing:` holds `:readings`, and the comparison was given no readings. " \
                               "Give them with `readings:`, like `readings: { hero_x: :px }`."
        end
      end
      private_constant :Compared
    end
  end
end
