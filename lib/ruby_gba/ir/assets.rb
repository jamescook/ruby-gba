# frozen_string_literal: true

module RubyGBA
  module IR
    # WHAT A DECLARED ASSET IS, read off the node that declares it.
    #
    # A program declares images and recorded sounds, and every backend has to know the same
    # things about them: how big a picture is, which of its colors means "see through",
    # how fast a recording plays. Each backend used to write that down for itself, which is
    # two descriptions of one thing in the two places whose whole contract is that they
    # agree — and nothing but a test to notice when they drifted.
    #
    # These are built from the declaring node by one function, so there is one description
    # and the backends read it. What a backend then DOES with an asset is its own business
    # and stays there: where the GBA packed a table into the cartridge, or which hardware
    # layer a background got, means nothing to an interpreter and is not here.
    module Assets
      # A picture: its size, which color index is see-through (nil if none is), and the
      # pixels themselves.
      Image = Data.define(:width, :height, :transparent, :pixels) do
        def self.of(node)
          new(width: node[:width], height: node[:height],
              transparent: node[:transparent], pixels: node[:pixels])
        end
      end

      # A recorded sound: how many samples a second it was recorded at, how many there are,
      # and the note it was played at when recorded (which is what playing it at another
      # pitch is measured from).
      Sample = Data.define(:rate, :length, :note) do
        def self.of(node)
          new(rate: node[:rate], length: node[:bytes].bytesize, note: node[:note])
        end
      end
    end
  end
end
