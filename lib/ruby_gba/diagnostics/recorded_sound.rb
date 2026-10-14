# frozen_string_literal: true

# Required here and not where it is used: see the note at the top of verifier.rb.
require "tempfile"

module RubyGBA
  module Diagnostics
    # THE SOUND A RUNNING CARTRIDGE MADE, a frame at a time, for as long as it has run.
    #
    # WHY IT IS NOT SIMPLY A STRING. The console makes tens of thousands of samples a second
    # on each of two channels, so the sound of a run is megabytes a minute. A test that plays
    # a few seconds never notices. A playthrough of several minutes, or two of them side by
    # side in a comparison, would hold hundreds of megabytes of sound that for the most part
    # nobody asks about.
    #
    # So only so many frames are held in memory. Once more than +frames_in_memory+ of them
    # are, they are all written to the end of one scratch file and memory starts again from
    # nothing. What is read back is the file and then the memory, so a reader gets the whole
    # run whichever of the two a frame is in.
    #
    # HOW MUCH THAT HOLDS. No more than +frames_in_memory+ frames once `keep` has returned,
    # and for a moment as many again as it was just handed. What stays in memory for a frame
    # in the file is its length, one number, and a second once somebody has asked how loud
    # the run was (see #energy_by_frame).
    #
    # A RUN NO LONGER THAN THAT WRITES NO FILE. Making one is not worth it for a run that fits,
    # and nearly every run does.
    #
    # The file is a Tempfile, so it goes when this object is collected and, failing that, when
    # the program ends. It is made in the machine's temporary files unless +folder+ says
    # where — which matters on a machine that keeps its temporary files in memory, where
    # writing the sound there moves it nowhere.
    #
    # One of these is one run's sound: a reader is handed its own (`Verifier.new(rom, sound:)`).
    class RecordedSound
      # A minute of play, at the console's sixty frames a second.
      FRAMES_IN_MEMORY = 3600

      # How many frames of sound are held in memory before they are written to the file.
      attr_reader :frames_in_memory

      def initialize(frames_in_memory: FRAMES_IN_MEMORY, folder: nil)
        refuse_frames_not_count!(frames_in_memory)
        @frames_in_memory = frames_in_memory
        @folder = folder
        @recent = []
        @written_lengths = []
        @file = nil
        @energies = []
      end

      # Keep the sound of the frames just played: one String of samples for each, in order.
      def keep(frames)
        @recent.concat(frames)
        write_recent_frames if @recent.size > @frames_in_memory
        self
      end

      # Each frame's sound in turn, oldest first, without holding the frames in the file all
      # at once: the way to ask something of every frame of a long run.
      def each_frame(&)
        return enum_for(:each_frame) unless block_given?

        each_frame_from(0, &)
      end

      # HOW LOUD EACH FRAME WAS, oldest first: a frame's samples added up with their signs
      # dropped, so 0 is a frame of silence.
      #
      # WORKED OUT ONCE FOR EACH FRAME, AND KEPT. The only sound gone through on an asking is
      # the frames played since the last one, so a test that asks after every frame of a long
      # run reads one frame's sound each time and never the recording from its start.
      #
      # Nothing is worked out until somebody asks, so a run nobody asks about pays nothing.
      # The first asking of a long run reads what is in the file, once.
      #
      # What is handed back is the caller's own list, to cut up as it likes: a copy, which is
      # one number for each frame of the run and the only part of an asking that grows with it.
      def energy_by_frame
        each_frame_from(@energies.size) { |frame| @energies << frame.unpack("s<*").sum(&:abs) }
        @energies.dup
      end

      # The sound of the whole run as one String of samples, which for a long run is all of
      # it in memory at once.
      def bytes = (@file ? File.binread(@file.path) : "".b) << @recent.join

      private

      def refuse_frames_not_count!(given)
        return if given.is_a?(Integer) && given.positive?

        raise ArgumentError, "`frames_in_memory:` was #{given.inspect}. It is how many frames of sound are held in " \
                             "memory, so it must be a whole number, 1 or more. " \
                             "`frames_in_memory: #{FRAMES_IN_MEMORY}` is one minute of play."
      end

      # A frame is found in the file by its length, since frames are not all the same size:
      # the console's sound clock and its picture clock do not divide evenly.
      def write_recent_frames
        @file ||= Tempfile.new(["sound", ".raw"], @folder).tap(&:close)
        File.open(@file.path, "ab") { |file| @recent.each { |frame| file.write(frame) } }
        @written_lengths.concat(@recent.map(&:bytesize))
        @recent = []
      end

      # Each frame's sound from frame +from+ on, counted from 0: those of them in the file,
      # then those of them in memory.
      def each_frame_from(from, &)
        each_written_frame_from(from, &)
        @recent.drop([from - @written_lengths.size, 0].max).each(&)
      end

      # The file is opened only when a frame that is wanted is in it, and read from that
      # frame on: where a frame starts is the lengths of the frames before it added up.
      def each_written_frame_from(from)
        return unless @file && from < @written_lengths.size

        File.open(@file.path, "rb") do |file|
          file.seek(@written_lengths.first(from).sum)
          @written_lengths.drop(from).each { |length| yield file.read(length) }
        end
      end
    end
  end
end
