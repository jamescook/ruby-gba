# frozen_string_literal: true

module VBlank
  module IR
    # The sentence a game that went wrong is stopped with (ProgramError), one method per way of
    # going wrong, so every backend written in Ruby says it in the same words. The native
    # lowering's C runtime (rg_list.h, rg_screen.c, rg_save.c) and the JavaScript one say these
    # sentences too, word for word, in their own languages; a change here is a change there.
    #
    # A list is named as the game names it, a Symbol, and written the way Ruby writes one.
    module Faults
      module_function

      def index_out_of_range(list, index, length)
        return "index #{index} is out of range: list :#{list} is empty" if length.zero?

        "index #{index} is out of range for list :#{list} (valid indexes are 0..#{length - 1})"
      end

      def list_full(list, capacity)
        "list :#{list} is full (capacity #{capacity}): drop an item first, or give it a larger capacity"
      end

      # +from+ is :front for a shift, :back for a pop.
      def list_empty(list, from)
        "list :#{list} is empty: there is nothing to #{from == :front ? 'shift' : 'pop'}"
      end

      def copy_too_long(list, count, capacity)
        "a copy of #{count} entries does not fit list :#{list} (capacity #{capacity})"
      end

      def copy_past_table(count, table_length)
        "a copy of #{count} entries is longer than its table (#{table_length} entries)"
      end

      def picture_missing(pose, count)
        "a sprite is showing picture #{pose} of its #{count}"
      end

      # The sprite +sprite+ shows +picture+, which the picture groups +groups+ hold only in the
      # groups numbered +holding+, and the groups up are +up+ (their numbers, none or more).
      #
      # The one sentence here the native and JavaScript runtimes never say: a program for a computer
      # or a page keeps every picture in reach whatever is up, so nothing goes wrong there, and their
      # runs are checked against the interpreter, which says it. A console that keeps only the groups
      # up in its sprite memory says it too (the Game Boy Color, GBC::HeadlessRun).
      def picture_not_up(sprite:, picture:, groups:, holding:, up:)
        state = case up.length
                when 0 then "No group of :#{groups} is up"
                when 1 then "Only group #{up.first} of :#{groups} is up"
                else "Only the groups #{up.join(' and ')} of :#{groups} are up"
                end
        which = holding.length == 1 ? "group #{holding.first}" : "groups #{holding.join(' or ')}"
        "The sprite :#{sprite} shows :#{picture}, which is in #{which} of :#{groups}. #{state}. So on " \
          "the console :#{sprite} will show other pictures. To fix this, show #{which} of :#{groups} before " \
          ":#{sprite} shows :#{picture}."
      end

      # The picture groups +groups+ have the groups numbered +up+ up together, which their
      # up_together: does not say they can be. Said by the same backends as #picture_not_up, and
      # for the same reason.
      def groups_not_together(groups:, up:)
        "The groups #{up.join(' and ')} of :#{groups} are up together, and up_together: does not say " \
          "they can be. So on the console their pictures can be in the same place in sprite memory. To fix " \
          "this, add #{up.inspect} to up_together: of :#{groups}."
      end

      # +did+ is "read" or "wrote to"; +size+ is the save memory's bytes.
      def save_outside(did, at, size)
        format("The program %<did>s save memory at 0x%<at>X, and save memory is %<kb>dK, which ends at " \
               "0x%<end>X. A program must keep to the save memory it has.", did: did, at: at, kb: size / 1024, end: size)
      end
    end
  end
end
