# frozen_string_literal: true

module RubyGBA
  class Builder
    # WHERE EACH `save_data` RECORD LIVES IN SAVE MEMORY, decided at power-on from the table of
    # places kept at the front of it (see IR::SaveLayout).
    #
    # A cartridge that shipped holds the player's saves, and the next build of the game has to
    # find them. Working a record's place out from the records declared before it cannot: add a
    # setting to the first record and every record after it moves, and their saves read as
    # empty with nothing said. So the place is written down in save memory instead, next to
    # the saves, and each build reads it back. A record this build did not change is found
    # where it was, whatever happened to the others.
    #
    # At power-on, before any record is looked at:
    #
    #   1. The table is read. A record that now keeps other things has a new shape, so nothing
    #      the last build saved in it can be read — its room is free. A record with fewer
    #      copies gives up the room past the ones it keeps.
    #   2. Each record finds its row, by the number worked out from its name. With no row (a
    #      record new in this build, or one whose room was just freed) it is given room and a
    #      row. With more copies than its row says, it grows where it is when the room after it
    #      is free, and otherwise its copies are moved, byte for byte, to room big enough.
    #   3. The table is written back if anything changed.
    #
    # ROOM is looked for in three steps, each only when the one before found none: room nothing
    # holds; then room held by a record this build no longer declares (kept until then, so a
    # game can drop a record and bring it back in a later build); then the records are slid
    # down together to put all the free room in one piece at the end. The build has already
    # checked that every record fits at once, so the last step always finds it.
    #
    # THE POWER GOING OFF while this runs loses nothing, with one exception. Moving a record's
    # copies writes them into room the table says is free, and the table is written the moment
    # they are in — so until then the table still points at the old place, which nothing has
    # touched. The exception is the last resort, when save memory is nearly full and the free
    # room is in pieces: the records are slid down together, and then, for a record given more
    # copies, the ones above it are lifted to let it grow. A record slid or lifted by less than
    # its own size overwrites itself as it goes, so a cut half way through either leaves that
    # record damaged. It is also the one slow step — a few frames at power-on, once.
    #
    # All of it is ordinary program built from the three save-memory steps, like the records'
    # own routines, so the interpreter and the console cannot disagree about any of it.
    module SavePlaces
      ROWS = IR::SaveLayout::TABLE_ROWS

      SCRATCH = %i[changed key half copies need room found row fits probe skip cursor pick
                   low limit from to length up extra place first].freeze

      private

      def table_list(column) = Messages::MadeNames.make(:save_table, column: column)
      def places_name(what) = Messages::MadeNames.make(:save_places, piece: what)
      def place_var(what) = sd_var(places_name(what))
      def set_place_var(what, value) = record(Build.set(places_name(what), value.is_a?(Integer) ? sd_int(value) : value))
      def sp_call(what) = record(Build.call(places_name(what)))
      def sp_op(op, lhs, rhs) = Build.binop(op, lhs, rhs)

      def cell(column, row) = Build.list_get(table_list(column), row)
      def set_cell(column, row, value) = record(Build.list_set(table_list(column), row, value))
      def row_in_use(row) = sp_op(:!=, cell(:key, row), sd_int(0))
      def row_size(row) = sp_op(:*, cell(:half, row), sp_op(:*, cell(:copies, row), sd_int(2)))
      def row_end(row) = sd_add(cell(:at, row), row_size(row))

      # Declared once the records are laid out: the table itself, kept the way a record is, and
      # the routine that places every record, run at power-on before any record is looked at.
      def declare_save_places
        kept = IR::SaveLayout::TABLE_COLUMNS.map do |column|
          at_boot(Build.list_new(table_list(column), ROWS, width: :word))
          SaveRecords::Kept.new(kind: :list, name: table_list(column), at: 0, width: :word, count: ROWS)
        end
        @save_table = lay_out_save_data(:__table, 1, kept, place: IR::SaveLayout::TABLE_AT)
        declare_save_data_vars(@save_table)
        declare_save_data_lists(@save_table)
        declare_save_data_routines(@save_table, %i[scan save load])
        SCRATCH.each { |what| ensure_var(places_name(what)) }
        %i[boot place_record find_room fits reclaim compact grow move clear commit].each do |job|
          declare_func(places_name(job)) { send(:"save_places_#{job}") }
        end
        at_boot(Build.call(places_name(:boot)))
      end

      def save_places_boot
        record(Build.set(@save_table.scratch(:copy), sd_int(0)))
        record(Build.call(@save_table.routine(:scan)))
        record(Build.call(@save_table.routine(:load)))
        # A table never written, or written with fewer rows, is filled out with empty ones.
        IR::SaveLayout::TABLE_COLUMNS.each do |column|
          short = sp_op(:-, sd_int(ROWS), Build.list_len(table_list(column)))
          repeat(DSL::Value.new(handle, short)) { |_| record(Build.list_push(table_list(column), sd_int(0))) }
        end
        set_place_var(:changed, 0)
        repeat(ROWS) { |i| save_places_reconcile_row(i.node) }
        @save_data.each_value do |layout|
          set_place_var(:key, layout.key)
          set_place_var(:half, layout.half)
          set_place_var(:copies, layout.copies)
          sp_call(:place_record)
          record(Build.set(layout.place, place_var(:place)))
        end
        sd_when(sd_eq(place_var(:changed), sd_int(1))) { sp_call(:commit) }
      end

      # One row against the records this build declares: a record that keeps other things now
      # frees its room, and one with fewer copies gives up the room past them.
      def save_places_reconcile_row(row)
        @save_data.each_value do |layout|
          sd_when(sd_eq(cell(:key, row), sd_int(layout.key))) do
            sd_when(sp_op(:!=, cell(:half, row), sd_int(layout.half))) do
              set_cell(:key, row, sd_int(0))
              set_place_var(:changed, 1)
            end
            sd_when(sp_op(:>, cell(:copies, row), sd_int(layout.copies))) do
              set_cell(:copies, row, sd_int(layout.copies))
              set_place_var(:changed, 1)
            end
          end
        end
      end

      # PLACE ONE RECORD, named by the key, half and copies scratch; leaves where it starts
      # in the place scratch.
      def save_places_place_record
        set_place_var(:need, sp_op(:*, place_var(:half), sp_op(:*, place_var(:copies), sd_int(2))))
        set_place_var(:found, -1)
        repeat(ROWS) { |i| sd_when(sd_eq(cell(:key, i.node), place_var(:key))) { set_place_var(:found, i.node) } }
        sd_when(sd_eq(place_var(:found), sd_int(-1))) { save_places_new_row }
          .else do
            sd_when(sp_op(:<, cell(:copies, place_var(:found)), place_var(:copies))) { sp_call(:grow) }
          end
        set_place_var(:place, cell(:at, place_var(:found)))
      end

      # A record with no row: a free row, and room for all its copies.
      #
      # The row is kept in the found scratch, which is this record's row from here on. Not in
      # the row scratch it is found in: sliding the records together to make room moves each
      # one by naming it there, so a row left in it would be the last record slid, and the new
      # record would be written over that record's row.
      def save_places_new_row
        save_places_free_row
        sd_when(sd_eq(place_var(:row), sd_int(-1))) do
          sp_call(:reclaim)
          save_places_free_row
        end
        set_place_var(:found, place_var(:row))
        set_place_var(:skip, -1)
        sp_call(:find_room)
        sd_when(sd_eq(place_var(:room), sd_int(-1))) do
          sp_call(:reclaim)
          sp_call(:find_room)
        end
        sd_when(sd_eq(place_var(:room), sd_int(-1))) do
          sp_call(:compact)
          set_place_var(:room, place_var(:cursor))
        end
        { key: place_var(:key), at: place_var(:room), half: place_var(:half), copies: place_var(:copies) }.each do |column, value|
          set_cell(column, place_var(:found), value)
        end
        set_place_var(:first, 0)
        sp_call(:clear)
        set_place_var(:changed, 1)
      end

      def save_places_free_row
        set_place_var(:row, -1)
        repeat(ROWS) do |i|
          free = sd_and(sd_eq(cell(:key, i.node), sd_int(0)), sd_eq(place_var(:row), sd_int(-1)))
          sd_when(free) { set_place_var(:row, i.node) }
        end
      end

      # A RECORD WITH MORE COPIES THAN ITS ROW SAYS keeps the ones it had. It grows where it is
      # when the room after it is free; otherwise its copies move to room big enough for all of
      # them, and the table is written once they are there. With no such room anywhere the
      # records are slid down together, and those above this one are then lifted by as much as
      # it grows.
      def save_places_grow
        found = place_var(:found)
        set_place_var(:first, cell(:copies, found))
        set_place_var(:probe, cell(:at, found))
        set_place_var(:skip, found)
        sp_call(:fits)
        sd_when(sd_eq(place_var(:fits), sd_int(0))) do
          set_place_var(:skip, -1)
          sp_call(:find_room)
          sd_when(sd_eq(place_var(:room), sd_int(-1))) do
            sp_call(:reclaim)
            sp_call(:find_room)
          end
          sd_when(sp_op(:!=, place_var(:room), sd_int(-1))) do
            set_place_var(:row, found)
            set_place_var(:to, place_var(:room))
            sp_call(:move)
          end.else do
            sp_call(:compact)
            save_places_lift_above(found)
          end
        end
        set_cell(:copies, found, place_var(:copies))
        sp_call(:clear)
        set_place_var(:changed, 1)
      end

      # WIPE WHAT A RECORD HAS JUST BEEN GIVEN: the copies from the first scratch up to the
      # copies scratch, of the record in the found row. Room a record did not own a moment ago
      # can hold anything — a copy a build before this one dropped, or another record's save
      # that keeps the same things — and a half there with the right marker, shape and
      # checksum would read as a real save. So each half's marker is written over, which makes
      # it read as never saved. It runs before the table is written, into room the table on
      # the chip does not give to anything, so the power going off here costs nothing.
      def save_places_clear
        place = cell(:at, place_var(:found))
        count = sp_op(:-, place_var(:copies), place_var(:first))
        repeat(DSL::Value.new(handle, count)) do |k|
          copy_at = sd_add(place, sp_op(:*, sd_add(place_var(:first), k.node), sp_op(:*, place_var(:half), sd_int(2))))
          2.times do |half|
            marker = sd_add(copy_at, sd_add(sp_op(:*, place_var(:half), sd_int(half)), sd_int(IR::SaveLayout::MARKER_AT)))
            record(Build.save_write(marker, sd_int(0)))
          end
        end
      end

      # Lift every record above +row+ by how much it grows, the highest first so none is
      # written over before it has moved.
      def save_places_lift_above(row)
        set_place_var(:extra, sp_op(:-, place_var(:need), row_size(row)))
        set_place_var(:limit, sd_int(IR::SaveLayout::SIZE))
        repeat(ROWS) do
          set_place_var(:pick, -1)
          set_place_var(:low, cell(:at, row))
          repeat(ROWS) do |i|
            higher = sd_and(sd_and(row_in_use(i.node), sp_op(:>, cell(:at, i.node), place_var(:low))),
                            sp_op(:<, cell(:at, i.node), place_var(:limit)))
            sd_when(higher) do
              set_place_var(:pick, i.node)
              set_place_var(:low, cell(:at, i.node))
            end
          end
          sd_when(sp_op(:!=, place_var(:pick), sd_int(-1))) do
            set_place_var(:limit, cell(:at, place_var(:pick)))
            set_place_var(:row, place_var(:pick))
            set_place_var(:to, sd_add(cell(:at, place_var(:pick)), place_var(:extra)))
            sp_call(:move)
          end
        end
      end

      # ROOM FOR +need+ bytes, in the room scratch, or -1: the start of save data, or the end
      # of any record, whichever comes first with nothing in the way.
      def save_places_find_room
        set_place_var(:room, -1)
        set_place_var(:probe, IR::SaveLayout::DATA_START)
        sp_call(:fits)
        sd_when(sd_eq(place_var(:fits), sd_int(1))) { set_place_var(:room, place_var(:probe)) }
        repeat(ROWS) do |i|
          candidate = sd_and(sd_and(sd_eq(place_var(:room), sd_int(-1)), row_in_use(i.node)), sp_op(:!=, i.node, place_var(:skip)))
          sd_when(candidate) do
            set_place_var(:probe, row_end(i.node))
            sp_call(:fits)
            sd_when(sd_eq(place_var(:fits), sd_int(1))) { set_place_var(:room, place_var(:probe)) }
          end
        end
      end

      # Whether +need+ bytes from +probe+ are inside save memory and clear of every record but
      # the one in +skip+.
      def save_places_fits
        ends = sd_add(place_var(:probe), place_var(:need))
        set_place_var(:fits, sp_op(:<=, ends, sd_int(IR::SaveLayout::SIZE)))
        repeat(ROWS) do |i|
          clear = sp_op(:|, sp_op(:<=, ends, cell(:at, i.node)), sp_op(:>=, place_var(:probe), row_end(i.node)))
          sd_when(sd_and(sd_and(row_in_use(i.node), sp_op(:!=, i.node, place_var(:skip))), sd_eq(clear, sd_int(0)))) do
            set_place_var(:fits, 0)
          end
        end
      end

      # Free the rows of records this build does not declare.
      def save_places_reclaim
        repeat(ROWS) do |i|
          stale = @save_data.each_value.reduce(row_in_use(i.node)) do |test, layout|
            sd_and(test, sp_op(:!=, cell(:key, i.node), sd_int(layout.key)))
          end
          sd_when(stale) do
            set_cell(:key, i.node, sd_int(0))
            set_place_var(:changed, 1)
          end
        end
      end

      # SLIDE THE RECORDS DOWN TOGETHER, lowest first, so all the free room is one piece from
      # the cursor scratch to the end.
      def save_places_compact
        set_place_var(:cursor, IR::SaveLayout::DATA_START)
        repeat(ROWS) do
          set_place_var(:pick, -1)
          set_place_var(:low, IR::SaveLayout::SIZE)
          repeat(ROWS) do |i|
            lower = sd_and(sd_and(row_in_use(i.node), sp_op(:>=, cell(:at, i.node), place_var(:cursor))),
                           sp_op(:<, cell(:at, i.node), place_var(:low)))
            sd_when(lower) do
              set_place_var(:pick, i.node)
              set_place_var(:low, cell(:at, i.node))
            end
          end
          sd_when(sp_op(:!=, place_var(:pick), sd_int(-1))) do
            sd_when(sp_op(:!=, cell(:at, place_var(:pick)), place_var(:cursor))) do
              set_place_var(:row, place_var(:pick))
              set_place_var(:to, place_var(:cursor))
              sp_call(:move)
            end
            set_place_var(:cursor, row_end(place_var(:pick)))
          end
        end
      end

      # MOVE ONE RECORD'S COPIES — the record in the row scratch, as many as its row says — to
      # the to scratch, then write the table, so it points at them only once they are there.
      # Moving up, the bytes go last first, so a move by less than the record's size never
      # reads a byte it has already written over.
      def save_places_move
        row = place_var(:row)
        set_place_var(:from, cell(:at, row))
        set_place_var(:length, row_size(row))
        set_place_var(:up, sp_op(:>, place_var(:to), place_var(:from)))
        repeat(DSL::Value.new(handle, place_var(:length))) do |k|
          back = sp_op(:-, sp_op(:-, place_var(:length), sd_int(1)), sp_op(:*, k.node, sd_int(2)))
          j = sd_add(k.node, sp_op(:*, place_var(:up), back))
          record(Build.save_write(sd_add(place_var(:to), j), sd_read(sd_add(place_var(:from), j), :byte), width: :byte))
        end
        set_cell(:at, row, place_var(:to))
        sp_call(:commit)
      end

      def save_places_commit
        record(Build.set(@save_table.scratch(:copy), sd_int(0)))
        record(Build.call(@save_table.routine(:save)))
        set_place_var(:changed, 0)
      end
    end
  end
end
