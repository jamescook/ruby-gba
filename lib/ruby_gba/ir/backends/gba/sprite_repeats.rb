# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # SEVERAL SPRITES THAT ONE WRITE SERVES (see SpriteRepeats, which finds them).
        #
        # +sprite+ is the write they share: the first one's record, reading the variable
        # SpriteRepeats::INDEX where its own entry number was. +first_index+ and +index_step+
        # say what that variable holds for the first sprite and how it changes to the next;
        # +first_row+ and +row_step+ say the same of the address its row is written at.
        SpriteRepeat = Data.define(:sprite, :names, :first_index, :index_step, :first_row, :row_step) do
          # What the variable holds once the last of them has been written.
          def index_after = first_index + (index_step * names.length)
        end

        # WHICH SPRITES ARE ONE SPRITE WRITTEN OUT SEVERAL TIMES, and so can be written by
        # going round one write instead of by a copy of it each.
        #
        # A pool that draws declares a sprite for every thing it can hold. They show the same
        # pictures from the same place in sprite memory, in the same colours, at the same
        # depth; each reads where it stands and what it shows out of the same lists, and all
        # that tells one from the next is WHICH entry of those lists it reads and which row
        # of the console's table it writes. Written a copy apiece, that is a few hundred
        # bytes of code for every thing a room can hold, in the routine a frame spends its
        # time in — and a room of forty-five had forty-five ways of saying one thing.
        #
        # HOW THEY ARE FOUND: by looking, never by being told. Two neighbouring sprites are
        # laid side by side. Everything settled while building has to be the same, and the
        # numbers each works out as the game runs have to be the same sums, differing only
        # in one whole number written into them — the entry read. That number becomes a
        # variable, and the repeat is extended for as long as the next sprite is the same
        # write with the next number, a fixed step further along the table.
        #
        # WHY THAT IS SAFE, and not a guess about what a pool declares: the write with the
        # variable in it is checked against every sprite it is to serve, by putting that
        # sprite's own number back and comparing it with what the sprite was declared with. A
        # sprite it does not reproduce exactly is written on its own, as it always was. So a
        # repeat can be missed, and can never draw anything a copy apiece would not have.
        #
        # WHAT IS STILL A COPY APIECE: a sprite somebody declared by hand. Each of those keeps
        # where it stands and whether it is shown in variables of its own, so two of them are
        # not one sum with another number in it — they are two sums. Going round them would
        # take a table of where each one's variables are and a write that reads everything
        # through it, and that is not built. A room's crowd is its pools.
        class SpriteRepeats
          # The entry number the sprite being written reads, while a repeat is gone round.
          INDEX = :__sprite_repeat_index

          # +sprites+ is each sprite's record by name. +row_of+ gives the address a sprite's
          # first row is written at. +alone+ says whether a sprite has to be written on its
          # own whatever it looks like.
          def initialize(sprites:, row_of:, alone:)
            @sprites = sprites
            @row_of = row_of
            @alone = alone
          end

          # +names+ as the sprites to write in turn: a name where a sprite is written on its
          # own, and a SpriteRepeat where the sprites from there on are one write.
          def among(names)
            parts = []
            at = 0
            while at < names.length
              repeat = starting_at(names, at)
              parts << (repeat || names[at])
              at += repeat ? repeat.names.length : 1
            end
            parts
          end

          private

          # The repeat that begins with the sprite at +at+, or nil when it and the next are
          # not one write.
          def starting_at(names, at)
            first, second = names[at, 2]
            return nil if second.nil? || @alone.call(first)

            first_row = @row_of.call(first)
            pattern = Pattern.between(@sprites.fetch(first), @sprites.fetch(second),
                                      row_step: @row_of.call(second) - first_row) or return nil
            served = names[at..].each_with_index.take_while do |name, place|
              !@alone.call(name) && @row_of.call(name) == first_row + (place * pattern.row_step) &&
                pattern.fits?(@sprites.fetch(name), place)
            end
            return nil if served.length < 2

            SpriteRepeat.new(sprite: pattern.sprite, names: served.map(&:first), first_index: pattern.first_index,
                             index_step: pattern.index_step, first_row: first_row, row_step: pattern.row_step)
          end

          # WHAT TWO NEIGHBOURING SPRITES HAVE IN COMMON, worked out from the pair and then
          # held up against every sprite after them.
          #
          # +first+ is the first sprite's record. +sites+ says, for each number it works out,
          # where in that sum its entry number is written — counted the way a walk of the sum
          # meets its parts.
          class Pattern
            attr_reader :first_index, :index_step, :row_step

            # The pattern +first+ and +second+ share, or nil when they are not one write: when
            # something settled while building differs, when they differ in more than a whole
            # number, or when the numbers they differ in are not one number stepping by one.
            def self.between(first, second, row_step:)
              return nil unless first.shared_fields == second.shared_fields && !row_step.zero?

              sites = Sprite.worked_out_fields.to_h do |part|
                [part, differing_numbers(first.public_send(part), second.public_send(part))]
              end
              return nil if sites.value?(nil)

              pairs = sites.values.flatten(1).map { |_at, ours, theirs| [ours, theirs] }.uniq
              return nil unless pairs.length == 1 && (pairs[0][1] - pairs[0][0]).abs == 1

              new(first, sites.transform_values { |found| found.map(&:first) },
                  first_index: pairs[0][0], index_step: pairs[0][1] - pairs[0][0], row_step: row_step)
            end

            # Where two sums differ in a whole number written into them, as [place, the first's
            # number, the second's]; nil when they are not the same sum part for part. A
            # difference that is not a whole number is left for #fits? to refuse.
            #
            # A SUM THAT IS NOTHING BUT THE NUMBER IS REFUSED TOO. A number standing on its
            # own is settled while building, and the write is free to treat a settled number
            # another way than one it has to read — a picture number past the last picture is
            # held to the first when it is written down, and read as it stands when it is
            # worked out. Making such a number a variable could change what is drawn.
            def self.differing_numbers(ours, theirs)
              return ours.nil? && theirs.nil? ? [] : nil if ours.nil? || theirs.nil?

              mine = ours.walk.to_a
              yours = theirs.walk.to_a
              return nil unless mine.map(&:kind) == yours.map(&:kind)

              found = mine.each_index.select { |at| mine[at].kind == :int && mine[at].value != yours[at].value }
              return nil if found.include?(0)

              found.map { |at| [at, mine[at].value, yours[at].value] }
            end

            def initialize(first, sites, first_index:, index_step:, row_step:)
              @first = first
              @sites = sites
              @first_index = first_index
              @index_step = index_step
              @row_step = row_step
            end

            # The write every sprite of the repeat shares: the first one's, reading the
            # variable where its own entry number was.
            def sprite
              @first.with(**Sprite.worked_out_fields.to_h { |part| [part, with_entry(part) { Build.var_ref(INDEX) }] })
            end

            # Whether +sprite+ is this write with the entry number +place+ steps on from the
            # first: checked by putting that number back and comparing with what the sprite
            # was declared with, which is the whole of what makes going round one write safe.
            # The sums compared are a handful of parts each.
            def fits?(sprite, place)
              index = @first_index + (place * @index_step)
              sprite.shared_fields == @first.shared_fields && Sprite.worked_out_fields.all? do |part|
                expected = with_entry(part) { Build.int(index) }
                declared = sprite.public_send(part)
                expected.nil? ? declared.nil? && @first.public_send(part).nil? : expected.same_shape?(declared)
              end
            end

            private

            # One of the first sprite's sums, copied, with what the block gives in each place
            # its entry number was written. nil when there is no such sum, or when a place
            # cannot be written to — which no sprite then fits, the first included.
            def with_entry(part)
              sum = @first.public_send(part) or return nil
              copy = sum.copy
              parts = copy.walk.to_a
              written = @sites.fetch(part).all? { |at| parts[at].parent&.replace_operand(parts[at], yield) }
              written ? copy : nil
            end
          end
        end
      end
    end
  end
end
