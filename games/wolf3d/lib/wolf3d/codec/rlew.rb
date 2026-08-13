# frozen_string_literal: true

module Wolf3D
  module Codec
    # Run-length encoding over 16-bit words. A run becomes the tag word, a count, and the value.
    #
    # The tag is read from MAPHEAD rather than assumed — a mod can change it — so it belongs to
    # the codec, not to every call.
    class RLEW
      # A run costs three words, so four is the first length that pays for itself.
      WORTH_A_RUN = 4

      attr_reader :tag

      def initialize(tag:)
        @tag = tag
      end

      def expand(data)
        words = data.unpack("v*")
        out = []
        i = 0
        while i < words.length
          word = words[i]
          i += 1
          if word == @tag
            count, value = words[i], words[i + 1]
            raise ArgumentError, "a run ran off the end of the data" if count.nil? || value.nil?

            out.concat(Array.new(count, value))
            i += 2
          else
            out << word
          end
        end
        out.pack("v*")
      end

      def compress(data)
        words = data.unpack("v*")
        out = []
        i = 0
        while i < words.length
          run = run_length(words, i)
          # A word equal to the tag has no choice: written plainly it reads back as a run.
          if run >= WORTH_A_RUN || words[i] == @tag
            out << @tag << run << words[i]
            i += run
          else
            out << words[i]
            i += 1
          end
        end
        out.pack("v*")
      end

      private

      def run_length(words, at)
        run = 1
        run += 1 while at + run < words.length && words[at + run] == words[at] && run < 0xFFFF
        run
      end
    end
  end
end
