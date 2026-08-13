# frozen_string_literal: true

module Wolf3D
  module Codec
    # The packing VGAGRAPH uses. The tree lives in its own file (VGADICT) as exactly 255 nodes of
    # two 16-bit branches each: a branch below 256 is a byte to emit, anything higher is another
    # node, 256 above its index. Walking starts at the last node and bits are read from the low
    # end of each byte upward.
    #
    # 255 nodes means all 256 byte values are leaves, whether a file uses them or not — so
    # building a tree gives every value a weight of at least one.
    module Huffman
      ROOT = 254
      NODE_COUNT = 255
      DICTIONARY_BYTES = 1024

      # The tree itself: built from data we are about to pack, or read back from a dictionary
      # somebody else wrote. Either way it can do both directions.
      class Tree
        def self.for(data) = new(nodes: build(weigh(data)))

        def self.from_dictionary(dictionary)
          new(nodes: dictionary.unpack("v*").each_slice(2).first(NODE_COUNT))
        end

        # Every byte value is a leaf whether the data uses it or not, so every weight starts at
        # one — that is what makes the tree exactly 255 nodes.
        def self.weigh(data)
          weights = Array.new(256, 1)
          data.each_byte { |byte| weights[byte] += 1 }
          weights
        end

        def self.build(weights)
          pending = weights.each_with_index.map { |weight, byte| [weight, byte] }
          nodes = []
          NODE_COUNT.times do
            pending.sort_by! { |weight, _| weight }
            low = pending.shift
            high = pending.shift
            pending << [low.first + high.first, 256 + nodes.length]
            nodes << [low.last, high.last]
          end
          nodes
        end

        def initialize(nodes:)
          @nodes = nodes
        end

        def dictionary = @nodes.flatten.pack("v*").ljust(DICTIONARY_BYTES, "\x00")

        def pack(data)
          bits = data.each_byte.flat_map { |byte| codes.fetch(byte) }
          bits.each_slice(8).map { |slice| slice.each_with_index.sum { |bit, i| bit << i } }.pack("C*")
        end

        # Length-driven, like the original: the packed data does not say where it stops, the
        # picture table does.
        def unpack(data, length)
          out = []
          node = ROOT

          data.each_byte do |byte|
            8.times do |bit|
              branch = @nodes.dig(node, (byte >> bit) & 1)
              raise ArgumentError, "the tree has no branch there" if branch.nil?

              if branch < 256
                out << branch
                return out.pack("C*") if out.length == length

                node = ROOT
              else
                node = branch - 256
              end
            end
          end

          raise ArgumentError, "the data ran out after #{out.length} of #{length} bytes"
        end

        private

        def codes
          @codes ||= {}.tap { |found| walk(256 + ROOT, [], found) }
        end

        def walk(branch, bits, found)
          return found[branch] = bits if branch < 256

          left, right = @nodes[branch - 256]
          walk(left, bits + [0], found)
          walk(right, bits + [1], found)
        end
      end
    end
  end
end
