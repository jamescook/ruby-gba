# frozen_string_literal: true

module Wolf3D
  module Codec
    # Back-references over 16-bit words, named for the man who wrote it.
    #
    # A word whose HIGH byte is one of the two markers is not data, it is a pointer: its low byte
    # is how many words to copy, and what follows says from where. Near copies from a byte's
    # worth of words back; far copies from an absolute word index. A count of zero is the escape
    # that lets a real word carry a marker byte in its high half.
    #
    # The first word of the stream is how many BYTES it expands to.
    module Carmack
      NEAR = 0xA7
      FAR = 0xA8
      MARKERS = [NEAR, FAR].freeze
      MAX_COUNT = 0xFF

      def self.expand(data) = Expansion.new(data).result
      def self.compress(data) = Compression.new(data).result

      class Expansion
        def initialize(data)
          @data = data
          @pos = 2
          @out = []
          @wanted = data[0, 2].unpack1("v").to_i / 2
        end

        def result
          take_one while @out.length < @wanted
          @out.pack("v*")
        end

        private

        def take_one
          word = next_word
          raise ArgumentError, "the stream ended before it expanded" if word.nil?

          marker = word >> 8
          count = word & 0xFF

          if MARKERS.include?(marker) && count.zero?
            @out << ((marker << 8) | next_byte)
          elsif marker == NEAR
            copy(@out.length - next_byte, count)
          elsif marker == FAR
            copy(next_word, count)
          else
            @out << word
          end
        end

        # A copy may overlap what it is still writing — the original copies one word at a time,
        # so a run can quote itself. Reading the output as it grows reproduces that.
        def copy(from, count)
          raise ArgumentError, "a copy points before the start of the data" if from.negative?

          count.times do |n|
            word = @out[from + n]
            raise ArgumentError, "a copy points past what has been written" if word.nil?

            @out << word
          end
        end

        def next_word
          word = @data[@pos, 2]
          @pos += 2
          word&.bytesize == 2 ? word.unpack1("v") : nil
        end

        def next_byte
          byte = @data.getbyte(@pos)
          raise ArgumentError, "the stream ended mid-pointer" if byte.nil?

          @pos += 1
          byte
        end
      end

      class Compression
        def initialize(data)
          @words = data.unpack("v*")
        end

        def result
          out = +"".b
          out << [@words.length * 2].pack("v")

          i = 0
          while i < @words.length
            length, from = longest_match(i)
            near = i - from

            if length >= 2 && near <= MAX_COUNT
              out << [(NEAR << 8) | length].pack("v") << [near].pack("C")
            elsif length >= 3 && from <= 0xFFFF
              out << [(FAR << 8) | length].pack("v") << [from].pack("v")
            else
              out << literal(@words[i])
              length = 1
            end
            i += length
          end
          out
        end

        private

        # A word carrying a marker in its high half cannot be written plainly; it would be read
        # back as a pointer. Zero count says "the next byte is really the low half of a word".
        def literal(word)
          return [word].pack("v") unless MARKERS.include?(word >> 8)

          [word & 0xFF00].pack("v") << [word & 0xFF].pack("C")
        end

        # Searches all the way back, not just the near window — a far pointer reaches any word
        # already written, and stopping at 255 would never find one.
        def longest_match(at)
          best_length = 0
          best_from = 0

          (0...at).each do |from|
            length = 0
            length += 1 while length < MAX_COUNT && at + length < @words.length &&
                             @words[from + length] == @words[at + length]
            if length > best_length
              best_length = length
              best_from = from
            end
          end

          [best_length, best_from]
        end
      end
    end
  end
end
