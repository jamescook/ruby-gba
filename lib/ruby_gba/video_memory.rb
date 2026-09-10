# frozen_string_literal: true

module RubyGBA
  # HOW MUCH ROOM THE PICTURES TOOK, and how much the framework's own choice bought back.
  #
  # A console keeps the pictures it draws in a memory of its own, and it is small and fixed:
  # 32K for the sprites, a block of the same size for the tiles a background is built from.
  # Running out is a build error rather than a slow frame, so the number worth reporting is
  # how much is LEFT — and, because a game grows and nobody watches this until it breaks,
  # it is worth reporting before it breaks.
  #
  # The second half is the part nobody could work out for themselves. The framework stores a
  # picture drawn from few enough colors at half the size, silently, deciding from the art
  # rather than from anything in the program — so how much of the room in hand came from that
  # decision is invisible unless the build says. It is usually most of it.
  VideoMemory = Data.define(:sprites, :tiles) do
    def any? = !sprites.nil? || !tiles.nil?

    def to_h
      { sprites: sprites&.to_h, tiles: tiles&.to_h }.compact
    end
  end

  class VideoMemory
    # One of the two areas. +small+ and +big+ are how many pictures got each storage, and
    # +saved+ is what the small ones would have cost stored the big way — which is their own
    # size again, since the small way is exactly half. +shared+ is how many pictures turned
    # out to be one another and were stored once.
    #
    # +skipped+ is bytes nothing draws from. A background layer names its tiles by counting
    # from a starting point, and a game with more tiles than one layer can count across gets
    # a second starting point — which the console only allows at fixed marks, so lining a
    # layer up with one can leave a gap behind it. Nobody writes any of that, and the gap is
    # otherwise invisible, so it is worth a number.
    Area = Data.define(:used, :capacity, :small, :big, :saved, :shared, :skipped) do
      def initialize(skipped: 0, **rest) = super

      def free = capacity - used
      def share = capacity.zero? ? 0.0 : used.to_f / capacity

      def to_h
        { used: used, capacity: capacity, free: free,
          small: small, big: big, saved: saved, shared: shared, skipped: skipped }
      end
    end
  end
end
