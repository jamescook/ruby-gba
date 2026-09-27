# frozen_string_literal: true

module RubyGBA
  module DSL
    # What `save_data` hands back: a record of the game's state kept in save memory. Index it
    # for one of its copies — `files[slot]`, where the number may be one the game works out.
    class SaveData
      def initialize(builder, layout)
        @builder = builder
        @layout = layout
      end

      # One copy. A number written in the program has to be one the record has; one the game
      # works out and that names no copy does nothing — it saves nothing, loads nothing, and
      # reads as empty — the same as a map number that names no map.
      def [](copy)
        if copy.is_a?(Integer) && !copy.between?(0, @layout.copies - 1)
          raise ArgumentError, "save_data :#{@layout.name} has #{@layout.copies} " \
                               "#{@layout.copies == 1 ? 'copy' : 'copies'}, counted from 0, so it has " \
                               "no copy #{copy}. To fix this, use a number from 0 to #{@layout.copies - 1}."
        end

        SaveDataCopy.new(@builder, @layout, Value.node_for(copy))
      end

      # Copy one copy over another — the file screen's "copy". Only a good copy is copied, and
      # the one written over keeps its last good save until the whole of the new one is in.
      def copy(from, to:)
        [from, to].each { |copy| self[copy] if copy.is_a?(Integer) } # the written-number check
        @builder.run_save_data_copy(@layout, Value.node_for(from), Value.node_for(to))
      end

      # Put every kept thing back as it was declared — a new game. Only the game's state
      # changes; nothing in save memory does.
      def reset = @builder.run_save_data(@layout, :reset, IR::Build.int(0))

      # Whether the last save, erase or copy did not read back as it should have — the chip did
      # not keep it. It holds until the next one.
      def failed? = Condition.new(@builder, @builder.save_data_failed(@layout))

      # Whether a save, erase or copy of this record is still in hand. Saves are written a piece
      # a pass while the game goes on, so this holds for a few passes after one is asked for:
      # the time to show that the game is saving, however the game likes to show it.
      def saving? = Condition.new(@builder, @builder.save_data_saving(@layout))

      # Whether a save, erase or copy of this record has just been written: true for the one
      # pass after, so a game can say "Saved!" there without keeping count of anything.
      def finished? = Condition.new(@builder, @builder.save_data_finished(@layout))
    end

    # One copy of a record: save the game into it, load it into the game, erase it, and ask
    # what it holds.
    class SaveDataCopy
      Build = IR::Build

      def initialize(builder, layout, copy)
        @builder = builder
        @layout = layout
        @copy = copy
      end

      # Write the game's state into this copy. Until the whole of it is written the copy is
      # still the last good save, so the power going off half way loses nothing.
      def save = @builder.run_save_data(@layout, :save, @copy)

      # Put this copy back into the game's state — when it is good. When it is not, nothing
      # changes, so loading a game's settings at power-on needs no test around it.
      def load = @builder.run_save_data(@layout, :load, @copy)

      # Mark this copy erased. It then reads as erased rather than empty: a game that never
      # saved there and one that saved and threw it away are two different things to know.
      def erase = @builder.run_save_data(@layout, :erase, @copy)

      # What this copy holds: one of the names :empty, :erased, :good or :damaged. Compare it
      # (`files[n].state == :good`), or ask the four questions below.
      def state
        names = NameSet.new("the state of a save_data copy")
        IR::SaveLayout::STATES.each { |name| names.number_for(name) }
        Value.new(@builder, @builder.save_data_state(@layout, @copy), names: names)
      end

      def good? = is?(:good)
      def empty? = is?(:empty)
      def erased? = is?(:erased)
      def damaged? = is?(:damaged)

      # A variable the record keeps, as this copy holds it — read from save memory, with the
      # game's own state left alone. A file-select screen shows each file's hearts this way.
      # A copy that is not good reads as 0.
      #
      # A kept LIST reads the same way, item by item: `files[n].peek(name)[i]` and
      # `files[n].peek(name).length`. An item past what the copy holds reads as 0.
      def peek(thing)
        item = @builder.save_data_kept(@layout, thing.respond_to?(:name) ? thing.name : thing)
        return SaveDataListPeek.new(@builder, @layout, @copy, item) if item.kind == :list

        Value.new(@builder, @builder.save_data_peek(@layout, @copy, item))
      end

      private

      def is?(name)
        Condition.new(@builder, Build.binop(:==, @builder.save_data_state(@layout, @copy),
                                            Build.int(IR::SaveLayout::STATES.index(name))))
      end
    end

    # A kept list as one copy holds it: its items and how many there are, read from save
    # memory, with the game's own list left alone.
    class SaveDataListPeek
      def initialize(builder, layout, copy, item)
        @builder = builder
        @layout = layout
        @copy = copy
        @item = item
      end

      def [](index)
        Value.new(@builder, @builder.save_data_peek(@layout, @copy, @item, index: Value.node_for(index)))
      end

      def length = Value.new(@builder, @builder.save_data_peek(@layout, @copy, @item, length: true))
    end
  end
end
