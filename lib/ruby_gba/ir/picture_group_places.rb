# frozen_string_literal: true

module RubyGBA
  module IR
    # WHERE A SET OF PICTURE GROUPS' PICTURES GO IN SPRITE MEMORY (see Builder::PictureGroups),
    # for a machine that keeps only the groups up in the memory it draws sprites from.
    #
    # A scene of many rooms shows one room's things at a time, two while the screen slides,
    # so its things need not all be in sprite memory at once: a room's pictures are copied in
    # as the game says the room is up. Each picture is given ONE place for as long as its
    # scene is up, and is copied there every time one of its groups comes up. Then a picture
    # never moves while it is shown, and the table each sprite reads to find its pictures is
    # written once, when the cartridge is built.
    #
    # TWO PICTURES CAN SHARE A PLACE when no group of the one can ever be up with a group of
    # the other: when it comes up, the other has gone. A picture in two groups is up while
    # either is, so it keeps clear of both. Which groups can be up at once is what
    # up_together: says; a group is always up with itself.
    #
    # This is the problem of giving each live value a register, laid out in a line: the
    # pictures are the values, being up together is being live at once, and the place is
    # the register. The biggest picture is placed first, each at the lowest place clear of
    # everything already placed that it can be up with. That is not always the least room
    # there could be, and it is never more than every picture side by side; what the scene
    # needs is where the last of them ends.
    #
    # The places are counted in whatever units the machine keeps pictures in, a tile's worth or
    # less; each lowering says how many a picture takes.
    class PictureGroupPlaces
      # One picture to place: +key+ says which (a lowering may use its bytes, so two sprites that
      # store a picture alike share it), +units+ how many units it takes, +even_start+ whether the
      # machine reads it only from an even unit, and +groups+ the numbers of its groups.
      Picture = Data.define(:key, :units, :even_start, :groups)

      def initialize(pictures, together:)
        @together = together
        @offsets = {}
        @placed = []
        pictures.each_with_index.sort_by { |picture, index| [-picture.units, index] }.each { |picture, _| place(picture) }
      end

      # How far into the room the picture's place starts, in units.
      def offset(key) = @offsets.fetch(key)

      # The room all of them need, in units.
      def units = @placed.map { |picture, at| at + picture.units }.max || 0

      # THE WORST SET OF GROUPS UP AT ONCE, and what their pictures come to together, in units:
      # the least room there could be. The room the places take is never less, and is more where
      # the pictures could not be fitted round each other any tighter.
      def worst_units = worst_set_and_units.last
      def worst_set = worst_set_and_units.first

      private

      # Every set up_together: names and every group alone, with its pictures' room.
      def worst_set_and_units
        sets = @together + @placed.flat_map { |picture, _| picture.groups }.uniq.zip
        sets.map { |set| [set.uniq.sort, @placed.sum { |picture, _| picture.groups.intersect?(set) ? picture.units : 0 }] }
            .max_by(&:last) || [[], 0]
      end

      # The lowest place clear of every picture placed already that this one can be up with:
      # the start of the room, or just past the end of one of those.
      def place(picture)
        beside = @placed.select { |other, _| up_with?(picture, other) }
        starts = [0, *beside.map { |other, at| at + other.units }].map { |at| aligned(at, picture) }.sort
        at = starts.find { |start| beside.none? { |other, other_at| overlap?(start, picture.units, other_at, other.units) } }
        @placed << [picture, at]
        @offsets[picture.key] = at
      end

      def aligned(at, picture) = !picture.even_start || at.even? ? at : at + 1

      def overlap?(at, units, other_at, other_units) = at < other_at + other_units && other_at < at + units

      # Can the two be up at the same moment: a group they share, or two of theirs that
      # up_together: says can be up at once.
      def up_with?(one, other)
        one.groups.intersect?(other.groups) ||
          one.groups.product(other.groups).any? { |pair| @together.any? { |set| (pair - set).empty? } }
      end
    end
  end
end
