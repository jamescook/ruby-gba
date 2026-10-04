# frozen_string_literal: true

module RubyGBA
  class Builder
    # `save_var` ON FLASH: the game's saved variables kept as one record of their own, which
    # saves itself.
    #
    # On the 32K memory a save_var writes its number into save memory the moment it changes,
    # and that is the whole of it. Flash cannot do that: it takes a byte only once between two
    # wipes, and it wipes 4K at a time, so writing a number in place would mean wiping a block
    # on every change — slow enough to stall a frame, and a chip only lasts so many wipes. So on
    # flash the saved variables become a record with one copy, hidden from the game, and every
    # change to one of them only notes that something changed. Once a pass the note is read,
    # and a save of the record is asked for — the same background save a `save_data` record
    # makes, with its two halves, so a power cut part way through keeps the save before it.
    #
    # A number that changes every frame — a play clock — would otherwise ask for a save every
    # pass, and every save wipes the blocks of one half. So a save is asked for at most once in
    # PASSES_BETWEEN_SAVES passes: the first change after a quiet spell is saved on the next
    # pass, and a run of changes at most that often, its last change included. The halves take
    # turns, so a block is wiped at most once in twice that many, which a chip rated for a
    # hundred thousand wipes takes for hundreds of hours of a number changing every frame. A
    # save is also asked for only while no other save is in hand, so it never queues behind a
    # game's own save and pushes a third into finishing on the spot.
    #
    # AN UPDATE THAT ADDS A save_var KEEPS THE ONES SAVED. A record whose shape changes reads
    # its old saves as empty, and a shape made from the save_vars would change with every one
    # added. So this record's shape is a fixed run of words: how many save_vars the save was
    # made with, then each number in its slot (the order they were declared, as on the 32K
    # memory). One added later starts at its default, since the save says it had no slot then.
    # The run is SLOTS words, or room for every save_var a game can have once it outgrows that.
    #
    # Nothing in the game says any of this. On the 32K memory there is no record, and a
    # save_var writes through as it always did.
    module SaveVarRecord
      # The record's name. One underscore in front, which no `save_data` name can have.
      SAVE_VAR_RECORD = IR::SaveLayout::SAVE_VAR_RECORD

      # How many passes go between two saves the saved variables ask for: five seconds, for a
      # game running at full speed.
      PASSES_BETWEEN_SAVES = 300

      # How many words the record holds, the count included, for a game with fewer save_vars.
      SLOTS = 64

      # What an error calls the record, which the game never named.
      SAVE_VAR_RECORD_WORDS = "the record that keeps the save_var numbers on flash"

      # The statement that notes a saved variable changed, put where the game changed it.
      def save_var_changed_node = Build.set(@save_data.fetch(SAVE_VAR_RECORD).scratch(:changed), sd_int(1))

      # Whether the saved variables are kept as a record, which loads them at power-on.
      def save_vars_in_record? = @save_data.key?(SAVE_VAR_RECORD)

      private

      # Declare the record of the saved variables +saved_vars+ (IR::SavedVar), laid out beside
      # the records already laid out — if the game has any and its save memory is flash.
      # +memory+ is the save memory the cartridge has, in kilobytes (see IR::SaveLayout.chosen);
      # records that fit no memory at all are refused next, whatever this does.
      def lay_out_save_var_record(saved_vars, memory)
        return if saved_vars.empty? || !IR::SaveLayout.memory(memory).flash?

        layout = new_record_layout(SAVE_VAR_RECORD, copies: 1, when_busy: :wait)
        %i[changed spacing count].each { |what| ensure_var(layout.scratch(what)) }
        word = ->(name) { SaveRecords::Kept.new(kind: :var, name: name, at: 0, width: :word, count: 1) }
        @save_data_keeping[SAVE_VAR_RECORD] = [word.call(layout.scratch(:count)), *saved_vars.map { |var| word.call(var.name) }]
        words = saved_vars.size < SLOTS ? SLOTS : IR::SaveLayout::SAVE_VARS + 1
        body = words * SaveRecords::WORD
        @save_data[SAVE_VAR_RECORD] = layout_with_kept(layout).with(
          body: body, half: IR::SaveLayout.half_bytes(body),
          shape: IR::SaveLayout.shape([[:list, SAVE_VAR_RECORD, :word, words]]),
        )
      end

      # Load the saved variables at power-on, once the record's copy has been looked over, and
      # ask for a save once a pass when one changed (see the module comment). Each starts at
      # its default, and one the save had no slot for goes back to it after the load.
      def declare_save_var_saving
        layout = @save_data[SAVE_VAR_RECORD] or return

        count = layout.scratch(:count)
        saved_vars.each { |var| at_boot(Build.set(var.name, sd_int(var.default))) }
        [[count, saved_vars.size], [layout.scratch(:changed), 0], [layout.scratch(:spacing), 0],
         [layout.scratch(:copy), 0]].each { |name, value| at_boot(Build.set(name, sd_int(value))) }
        at_boot(Build.call(layout.routine(:load)))
        saved_vars.each do |var|
          at_boot(Build.if_(Build.binop(:<=, sd_var(count), sd_int(var.slot)),
                            Build.set(var.name, sd_int(var.default))))
        end
        at_boot(Build.set(count, sd_int(saved_vars.size)))
        declare_func(layout.routine(:autosave)) { emit_save_var_autosave(layout) }
        run_each_pass(layout.routine(:autosave))
      end

      def emit_save_var_autosave(layout)
        spacing = layout.scratch(:spacing)
        changed = layout.scratch(:changed)
        idle = @jobs.idle
        sd_when(Build.binop(:>, sd_var(spacing), sd_int(0))) do
          record(Build.set(spacing, Build.binop(:-, sd_var(spacing), sd_int(1))))
        end.else do
          sd_when(sd_and(sd_eq(sd_var(changed), sd_int(1)), idle)) do
            record(Build.set(changed, sd_int(0)))
            record(Build.set(spacing, sd_int(PASSES_BETWEEN_SAVES - 1)))
            emit_save_data_call(layout, :save, sd_int(0))
          end
        end
      end
    end
  end
end
