# frozen_string_literal: true

module RubyGBA
  module DSL
    # What `save_data` hands back: a record of the game's state kept in save memory. Index it
    # for one of its copies — `files[slot]`, where the number may be one the game works out.
    class SaveData
      def initialize(builder, saves, layout)
        @builder = builder # what the numbers and conditions handed back build program through
        @saves = saves     # the record's routines and state (see Builder::Saves)
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

        SaveDataCopy.new(@builder, @saves, @layout, Value.node_for(copy))
      end

      # Add to what the record keeps: variables and lists, after the ones it already keeps.
      # Written by the code that owns them, anywhere in the program — so a file screen can be
      # declared first and use the record, and the gameplay declared after it says what goes in.
      # The order things are kept in is the record's shape, and a save made with another shape
      # reads as empty.
      def keep(*things)
        @saves.save_data_keep(@layout.name, things)
        self
      end

      # Copy one copy over another — the file screen's "copy". Only a good copy is copied, and
      # the one written over keeps its last good save until the whole of the new one is in.
      def copy(from, to:)
        [from, to].each { |copy| self[copy] if copy.is_a?(Integer) } # the written-number check
        @saves.run_save_data_copy(@layout, Value.node_for(from), Value.node_for(to))
      end

      # Put every kept thing back as it was declared — a new game. Only the game's state
      # changes; nothing in save memory does.
      def reset = @saves.run_save_data(@layout, :reset, IR::Build.int(0))

      # Whether the last save, erase or copy did not read back as it should have — the chip did
      # not keep it. It holds until the next one.
      def failed? = Condition.new(@builder, @saves.save_data_failed(@layout))

      # Whether a save, erase or copy of this record is still in hand. Saves are written a piece
      # a pass while the game goes on, so this holds for a few passes after one is asked for:
      # the time to show that the game is saving, however the game likes to show it.
      def saving? = Condition.new(@builder, @saves.save_data_saving(@layout))

      # Whether a save, erase or copy of this record has just been written: true for the one
      # pass after, so a game can say "Saved!" there without keeping count of anything.
      def finished? = Condition.new(@builder, @saves.save_data_finished(@layout))
    end

    # One copy of a record: save the game into it, load it into the game, erase it, and ask
    # what it holds.
    class SaveDataCopy
      Build = IR::Build

      def initialize(builder, saves, layout, copy)
        @builder = builder
        @saves = saves
        @layout = layout
        @copy = copy
      end

      # Write the game's state into this copy. Until the whole of it is written the copy is
      # still the last good save, so the power going off half way loses nothing.
      def save = @saves.run_save_data(@layout, :save, @copy)

      # Put this copy back into the game's state — when it is good. When it is not, nothing
      # changes, so loading a game's settings at power-on needs no test around it.
      def load = @saves.run_save_data(@layout, :load, @copy)

      # Mark this copy erased. It then reads as erased rather than empty: a game that never
      # saved there and one that saved and threw it away are two different things to know.
      def erase = @saves.run_save_data(@layout, :erase, @copy)

      # What this copy holds: one of the names :empty, :erased, :good or :damaged. Compare it
      # (`files[n].state == :good`), or ask the four questions below.
      def state
        names = NameSet.new("the state of a save_data copy")
        IR::SaveLayout::STATES.each { |name| names.number_for(name) }
        Value.new(@builder, @saves.save_data_state(@layout, @copy), names: names)
      end

      def good? = state_is?(:good)
      def empty? = state_is?(:empty)
      def erased? = state_is?(:erased)
      def damaged? = state_is?(:damaged)

      # A variable the record keeps, as this copy holds it — read from save memory, with the
      # game's own state left alone. A file-select screen shows each file's hearts this way.
      # A copy that is not good reads as 0.
      #
      # A kept LIST reads the same way, item by item: `files[n].peek(name)[i]` and
      # `files[n].peek(name).length`. An item past what the copy holds reads as 0.
      #
      # The thing can be named before the record keeps it — `peek(:hearts)` on a file screen
      # declared ahead of the gameplay that keeps the hearts — and is checked once the whole
      # program is declared.
      def peek(thing)
        SaveDataPeek.new(@builder, @saves, @layout, @copy, thing.is_a?(Symbol) ? thing : thing.name)
      end

      private

      def state_is?(name)
        Condition.new(@builder, Build.binop(:==, @saves.save_data_state(@layout, @copy),
                                            Build.int(IR::SaveLayout::STATES.index(name))))
      end
    end

    # A kept thing as one copy holds it, read from save memory with the game's own state left
    # alone. A kept variable is this number; a kept list is read through it, item by item and
    # its length. Which of the two the thing is may not be known yet where the game reads it,
    # so it is both, and a reading of the wrong one is a friendly error once it is known.
    class SaveDataPeek < Value
      def initialize(builder, saves, layout, copy, name)
        @saves = saves
        @layout = layout
        @copy = copy
        @kept_name = name
        super(builder, saves.save_data_peek_site(layout, copy, name, :number))
      end

      def [](index) = peek_list_value(:item, index: Value.node_for(index))

      def length = peek_list_value(:length)

      private

      # Read as a list, the number this stands for is not the reading, so it is no expression
      # somebody forgot to keep.
      def peek_list_value(shape, index: nil)
        @builder.expressions.delete(self) if @builder.respond_to?(:expressions)
        Value.new(@builder, @saves.save_data_peek_site(@layout, @copy, @kept_name, shape, index: index))
      end
    end
  end
end
