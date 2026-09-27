# frozen_string_literal: true

require "zlib"

module RubyGBA
  class Builder
    # SAVE DATA: a group of the game's own state — variables and lists — kept in the
    # cartridge's save memory when the game says so, and put back when it says so.
    #
    #   files = save_data :file, copies: 3 do
    #     keep hearts, name, flags
    #   end
    #   files[slot].save      files[slot].load      files[slot].good?
    #
    # A `save_var` is written the moment it changes, which is right for a high score and wrong
    # for a game's progress: a player who turns the console off without saving must find the
    # game as it was when they last saved. So nothing here is written until the game asks.
    #
    # WHAT IS BUILT is ordinary program: a routine per record for saving, loading, erasing,
    # copying and looking a copy over, each made of the three save-memory steps (see
    # IR::SaveLayout) and the arithmetic every backend already runs. So the rules that keep a
    # save safe — two halves per copy, the newer one wins, a checksum written last — are
    # written once, here, and the interpreter and the console cannot disagree about them.
    module SaveData
      # One thing a record keeps, and where in its body it sits. +bytes+ is how much of the
      # body it takes; +width+ is how each of its numbers is stored.
      Kept = Data.define(:kind, :name, :at, :width, :count) do
        def bytes = kind == :var ? 4 : 4 + (count * SaveData::WIDTH_BYTES.fetch(width))
      end

      WIDTH_BYTES = { byte: 1, half: 2, word: 4 }.freeze

      # Declare a record of the game's state, kept in save memory in +copies+ numbered
      # copies. The block names what it keeps, with `keep`. Returns a handle: `files[n]` is
      # one copy, and a copy saves, loads, erases and says whether it is good.
      def save_data(name, copies: 1, when_busy: :wait, &block)
        name = name.to_sym
        check_save_data_name!(name, copies, block)
        check_save_data_when_busy!(name, when_busy)
        kept = SaveDataKeeping.new(self, name).tap { |keeping| keeping.instance_eval(&block) }.kept
        if @save_data.empty?
          declare_save_places
          declare_save_jobs
        end
        record_layout = lay_out_save_data(name, copies, kept, place: :"__save_#{name}_place",
                                                              number: @save_data.size + 1,
                                                              when_busy: when_busy)
        check_save_data_room!(record_layout)
        @save_data[name] = record_layout
        declare_save_data_lists(record_layout)
        declare_save_job_state(record_layout)
        record_layout.copies.times do |copy|
          at_boot(Build.set(record_layout.scratch(:copy), Build.int(copy)))
          at_boot(Build.call(record_layout.routine(:scan)))
        end
        declare_save_data_routines(record_layout, %i[scan load reset])
        { save: SaveJobs::SAVE, erase: SaveJobs::ERASE, copy: SaveJobs::COPY }.each do |job, kind|
          declare_func(record_layout.routine(job)) { save_job_ask(record_layout, kind) }
        end
        declare_func(record_layout.routine(:step)) { save_job_step(record_layout) }
        DSL::SaveData.new(self, record_layout)
      end

      # Everything the routines need to know about one record, worked out once. +place+ is
      # where it starts in save memory: a number for the table of places, which never moves,
      # and for a record the name of a variable, set at power-on from that table. +number+
      # counts the records from 1 in the order they were declared, which is how a job says
      # whose it is; the table of places, which is written without jobs, is 0.
      Layout = Data.define(:name, :copies, :kept, :body, :half, :place, :shape, :key, :number, :when_busy) do
        def routine(job) = :"__save_#{name}_#{job}"
        def scratch(what) = :"__save_#{name}_#{what}"
        def directory(what) = :"__save_#{name}_#{what}_of"
        def region = half * 2 * copies
        def place_node = place.is_a?(Integer) ? Build.int(place) : Build.var_ref(place)
      end

      private

      def check_save_data_name!(name, copies, block)
        raise ArgumentError, "save_data :#{name} needs a block that says what it keeps: " \
                             "`save_data :#{name} do keep hearts, name end`." unless block
        if @save_data.key?(name)
          raise ArgumentError, "save_data :#{name} is declared twice. To fix this, give each one its own name."
        end
        return if copies.is_a?(Integer) && copies >= 1

        raise ArgumentError, "save_data :#{name} was given `copies: #{copies.inspect}`. " \
                             "It must be a whole number, 1 or more."
      end

      # What a save, erase or copy of this record does when one of the record's is already in
      # hand. Waiting is the default because it is the one that loses nothing.
      WHEN_BUSY = %i[wait replace refuse].freeze

      def check_save_data_when_busy!(name, when_busy)
        return if WHEN_BUSY.include?(when_busy)

        raise ArgumentError, "save_data :#{name} was given `when_busy: #{when_busy.inspect}`. It must be " \
                             ":wait (the default: it waits its turn), :replace (it takes the place of the " \
                             "one not yet written) or :refuse (it does nothing and failed? holds)."
      end

      # Where each kept thing sits in the body, and what the record's shape and key are. Where
      # the record sits in save memory is not decided here: the table of places says, at
      # power-on (see SavePlaces).
      def lay_out_save_data(name, copies, kept, place:, number: 0, when_busy: :wait)
        at = 0
        placed = kept.map { |item| item.with(at: at).tap { |one| at += one.bytes } }
        shape = Zlib.crc32(placed.map { |item| [item.kind, item.name, item.width, item.count].join(":") }.join(";"))
        Layout.new(name: name, copies: copies, kept: placed, body: at, half: IR::SaveLayout.half_bytes(at),
                   place: place, shape: IR::Int32.wrap(shape), key: save_data_key(name), number: number,
                   when_busy: when_busy)
      end

      # The record's name as a number, which is how its row in the table of places is found.
      # Never 0, which marks a row nothing uses.
      def save_data_key(name)
        key = IR::Int32.wrap(Zlib.crc32("save_data:#{name}"))
        key.zero? ? 1 : key
      end

      def check_save_data_room!(layout)
        records = [*@save_data.each_value, layout]
        if records.length > IR::SaveLayout::TABLE_ROWS
          raise ArgumentError, "save_data :#{layout.name} is record #{records.length}, and a game can have " \
                               "#{IR::SaveLayout::TABLE_ROWS}. To fix this, keep more in fewer records."
        end
        if (same = @save_data.each_value.find { |other| other.key == layout.key })
          raise ArgumentError, "save_data :#{layout.name} and save_data :#{same.name} have names the save " \
                               "memory cannot tell apart. To fix this, rename one of them."
        end
        room = IR::SaveLayout::SIZE - IR::SaveLayout::DATA_START
        needed = records.sum(&:region)
        return if needed <= room

        sizes = records.map { |one| ":#{one.name} #{one.region}" }
        raise ArgumentError, "save_data :#{layout.name} does not fit in save memory. The records need " \
                             "#{needed} bytes, and there are #{room}. Each copy is kept twice, so a save " \
                             "cut off half way cannot lose it. The records take #{sizes.join(', ')} " \
                             "bytes. To fix this, keep less in each record, or use fewer copies."
      end

      # What the game can ask about each copy without reading save memory: whether it is
      # good, which of its two halves is the newer, and that half's sequence number. Worked
      # out at power-on, and again after each job.
      def declare_save_data_lists(layout)
        %i[state half seq].each do |what|
          at_boot(Build.list_new(layout.directory(what), layout.copies, width: what == :seq ? :word : :byte))
          layout.copies.times { at_boot(Build.list_push(layout.directory(what), Build.int(0))) }
        end
        %i[copy from at at0 at1 v0 v1 s0 s1 started winner failed].each { |what| ensure_var(layout.scratch(what)) }
        ensure_var(layout.place) unless layout.place.is_a?(Integer)
      end

      def declare_save_data_routines(layout, jobs = %i[scan save load erase copy reset])
        jobs.each { |job| declare_func(layout.routine(job)) { send(:"save_data_#{job}", layout) } }
      end

      # --- the routines' bodies, run while the routines are built ---

      def sd_int(value) = Build.int(value)
      def sd_var(name) = Build.var_ref(name)
      def sd_add(lhs, rhs) = Build.binop(:+, lhs, rhs)
      def sd_eq(lhs, rhs) = Build.binop(:==, lhs, rhs)
      def sd_and(lhs, rhs) = Build.binop(:&, lhs, rhs)
      def sd_read(at, width = :word) = Build.save_read(at, width: width)
      def sd_when(test, &block) = DSL::Condition.new(self, test).then(&block)

      # Where one half of copy +copy+ starts: the record's place, two halves a copy.
      def sd_half_at(layout, copy, half)
        sd_add(layout.place_node,
               sd_add(Build.binop(:*, copy, sd_int(layout.half * 2)), Build.binop(:*, half, sd_int(layout.half))))
      end

      # The copy asked for is one this record has.
      def sd_in_range(layout, copy)
        sd_and(Build.binop(:>=, copy, sd_int(0)), Build.binop(:<, copy, sd_int(layout.copies)))
      end

      def sd_directory(layout, what, copy) = Build.list_get(layout.directory(what), copy)

      # LOOK ONE COPY OVER: which half is good and newer, and so what the copy is.
      #
      # A half is good when it has the marker, the record's shape, and a checksum that matches
      # its bytes. Of two good halves the one with the higher sequence number is the copy. With
      # neither good, a half that was started — marker and shape, but a checksum that does not
      # match — is a save cut off before it could finish: the copy is damaged. A half with no
      # marker, or another record's shape, was never this record's, and the copy is empty.
      def save_data_scan(layout)
        copy = sd_var(layout.scratch(:copy))
        started = sd_int(0)
        2.times do |half|
          at = layout.scratch(:"at#{half}")
          record(Build.set(at, sd_half_at(layout, copy, sd_int(half))))
          here = sd_var(at)
          marked = sd_and(sd_eq(sd_read(sd_add(here, sd_int(IR::SaveLayout::MARKER_AT))), sd_int(IR::SaveLayout::MARKER)),
                          sd_eq(sd_read(sd_add(here, sd_int(IR::SaveLayout::SHAPE_AT))), sd_int(layout.shape)))
          summed = sd_eq(sd_read(sd_add(here, sd_int(IR::SaveLayout::CHECKSUM_AT))),
                         Build.save_sum(sd_add(here, sd_int(IR::SaveLayout::HEADER)), sd_int(layout.body)))
          record(Build.set(layout.scratch(:"v#{half}"), sd_and(marked, summed)))
          record(Build.set(layout.scratch(:"s#{half}"), sd_read(sd_add(here, sd_int(IR::SaveLayout::SEQUENCE_AT)))))
          started = Build.binop(:|, started, marked)
        end
        record(Build.set(layout.scratch(:started), started))
        winner = layout.scratch(:winner)
        record(Build.set(winner, sd_int(-1)))
        sd_when(sd_eq(sd_var(layout.scratch(:v0)), sd_int(1))) { record(Build.set(winner, sd_int(0))) }
        newer = Build.binop(:|, sd_eq(sd_var(winner), sd_int(-1)),
                            Build.binop(:>, sd_var(layout.scratch(:s1)), sd_var(layout.scratch(:s0))))
        sd_when(sd_and(sd_eq(sd_var(layout.scratch(:v1)), sd_int(1)), newer)) { record(Build.set(winner, sd_int(1))) }

        state = IR::SaveLayout::STATES
        record(Build.list_set(layout.directory(:half), copy, sd_var(winner)))
        sd_when(sd_eq(sd_var(winner), sd_int(-1))) do
          record(Build.list_set(layout.directory(:seq), copy, sd_int(0)))
          record(Build.list_set(layout.directory(:state), copy,
                                Build.binop(:*, sd_var(layout.scratch(:started)), sd_int(state.index(:damaged)))))
        end.else do
          at = sd_half_at(layout, copy, sd_var(winner))
          record(Build.set(layout.scratch(:at), at))
          record(Build.list_set(layout.directory(:seq), copy,
                                sd_read(sd_add(sd_var(layout.scratch(:at)), sd_int(IR::SaveLayout::SEQUENCE_AT)))))
          erased = sd_eq(sd_read(sd_add(sd_var(layout.scratch(:at)), sd_int(IR::SaveLayout::KIND_AT))),
                         sd_int(IR::SaveLayout::ERASED))
          sd_when(erased) { record(Build.list_set(layout.directory(:state), copy, sd_int(state.index(:erased)))) }
            .else { record(Build.list_set(layout.directory(:state), copy, sd_int(state.index(:good)))) }
        end
      end

      # SAVE THE TABLE OF PLACES in one go (see SavePlaces): its body into the older half, then
      # the header, the checksum last of all — until that is written the half cannot pass for
      # good, so a save cut off anywhere leaves the other half as the table. The game's own
      # records are written the same way, but a piece a pass (see SaveJobs); the table is written
      # only at power-on, before the game has anything to show, so it is written whole.
      def save_data_save(layout)
        save_data_write(layout, IR::SaveLayout::SAVED) do |body|
          layout.kept.each { |item| save_data_put(item, body) }
        end
      end

      # A NEW GAME: each kept variable set to what it was declared with, each kept list emptied.
      def save_data_reset(layout)
        layout.kept.each do |item|
          next repeat(DSL::Value.new(self, Build.list_len(item.name))) { |_| record(Build.list_drop(item.name, from: :back)) } if item.kind == :list

          start = @boot_inits.find { |node| node.kind == :set && node.var == item.name }
          record(Build.set(item.name, start ? start.value.copy : sd_int(0)))
        end
      end

      # The half a job writes is the one that is NOT the copy now — the older one, or the first
      # when neither is good — and it goes one past the copy's sequence number.
      def save_data_write(layout, kind)
        copy = sd_var(layout.scratch(:copy))
        sd_when(sd_in_range(layout, copy)) do
          older =Build.binop(:*, sd_eq(sd_directory(layout, :half, copy), sd_int(0)), sd_int(1))
          record(Build.set(layout.scratch(:at), sd_half_at(layout, copy, older)))
          here = sd_var(layout.scratch(:at))
          body = sd_add(here, sd_int(IR::SaveLayout::HEADER))
          # The marker and the shape go FIRST, so a save cut off at any point after them is
          # known to have been started: a copy that had no good save before then reads as
          # damaged rather than as never saved. They cannot make the half pass for good on their
          # own — only the checksum, written last, does that.
          first = { MARKER_AT: sd_int(IR::SaveLayout::MARKER), SHAPE_AT: sd_int(layout.shape) }
          last = { SEQUENCE_AT: sd_add(sd_directory(layout, :seq, copy), sd_int(1)), KIND_AT: sd_int(kind) }
          first.each { |field, value| record(Build.save_write(sd_add(here, sd_int(IR::SaveLayout.const_get(field))), value)) }
          yield body
          last.each { |field, value| record(Build.save_write(sd_add(here, sd_int(IR::SaveLayout.const_get(field))), value)) }
          record(Build.save_write(sd_add(here, sd_int(IR::SaveLayout::CHECKSUM_AT)),
                                  Build.save_sum(body, sd_int(layout.body))))
          # Looking the copy over again is also the read-back: a job that worked leaves the
          # copy saved (or erased), and anything else means the chip did not keep it.
          record(Build.call(layout.routine(:scan)))
          expected = IR::SaveLayout::STATES.index(kind == IR::SaveLayout::ERASED ? :erased : :good)
          record(Build.set(layout.scratch(:failed), Build.binop(:!=, sd_directory(layout, :state, copy), sd_int(expected))))
        end
      end

      # One kept thing into the body: a variable as a word; a list as its length and then its
      # items, at the width the list keeps them.
      def save_data_put(item, body)
        at = sd_add(body, sd_int(item.at))
        return record(Build.save_write(at, sd_var(item.name))) if item.kind == :var

        record(Build.save_write(at, Build.list_len(item.name)))
        bytes = WIDTH_BYTES.fetch(item.width)
        repeat(DSL::Value.new(self, Build.list_len(item.name))) do |i|
          slot = sd_add(sd_add(at, sd_int(4)), Build.binop(:*, i.node, sd_int(bytes)))
          record(Build.save_write(slot, Build.list_get(item.name, i.node), width: item.width))
        end
      end

      # LOAD A COPY INTO THE GAME'S STATE, when it is good; otherwise nothing changes, so a
      # game can load its settings at power-on with no test around it.
      def save_data_load(layout)
        copy = sd_var(layout.scratch(:copy))
        good = sd_eq(sd_directory(layout, :state, copy), sd_int(IR::SaveLayout::STATES.index(:good)))
        sd_when(sd_in_range(layout, copy)) do
          sd_when(good) do
            record(Build.set(layout.scratch(:at), sd_half_at(layout, copy, sd_directory(layout, :half, copy))))
            body = sd_add(sd_var(layout.scratch(:at)), sd_int(IR::SaveLayout::HEADER))
            layout.kept.each { |item| save_data_take(item, body) }
          end
        end
      end

      def save_data_take(item, body)
        at = sd_add(body, sd_int(item.at))
        return record(Build.set(item.name, sd_read(at))) if item.kind == :var

        repeat(DSL::Value.new(self, Build.list_len(item.name))) { |_| record(Build.list_drop(item.name, from: :back)) }
        count = Build.clamped(sd_read(at), sd_int(0), sd_int(item.count))
        bytes = WIDTH_BYTES.fetch(item.width)
        repeat(DSL::Value.new(self, count)) do |i|
          slot = sd_add(sd_add(at, sd_int(4)), Build.binop(:*, i.node, sd_int(bytes)))
          record(Build.list_push(item.name, sd_read(slot, item.width)))
        end
      end

      public

      # What one thing named in `keep` is, checked: a variable or a list the game declared,
      # kept by no other record, and not a `save_var`, which saves itself as it changes.
      def save_data_item(record, thing)
        item = save_data_item_of(record, thing)
        if (owner = @save_data_kept[item.name])
          raise ArgumentError, "save_data :#{record} keeps :#{item.name}, and save_data :#{owner} keeps it " \
                               "too. To fix this, keep it in one of them."
        end
        if persisted?(item.name)
          raise ArgumentError, "save_data :#{record} keeps :#{item.name}, which is a `save_var`. A save_var " \
                               "saves itself each time it changes. To fix this, declare it with `var`, " \
                               "or leave it out of the record."
        end

        @save_data_kept[item.name] = record
        item
      end

      def save_data_item_of(record, thing)
        case thing
        when DSL::List
          made = @program.walk.find { |node| node.kind == :list_new && node.name == thing.name }
          Kept.new(kind: :list, name: thing.name, at: 0, width: made.width || :word,
                   count: made.capacity)
        when DSL::Value
          return Kept.new(kind: :var, name: thing.name, at: 0, width: :word, count: 1) if thing.name

          save_data_not_state!(record, "a number worked out from other things")
        else
          save_data_not_state!(record, thing.inspect)
        end
      end

      def save_data_not_state!(record, what)
        raise ArgumentError, "save_data :#{record} was asked to keep #{what}. A record keeps the game's " \
                             "own state: the handles `var` and `list` give you. To fix this, pass one of those."
      end

      # --- what the handles call ---

      # Run one of a record's routines for copy +copy+ (a node). A save, an erase or a copy only
      # asks for a job (see SaveJobs); a load reads save memory, so the record's jobs are
      # finished first.
      def run_save_data(layout, job, copy)
        finish_save_jobs_of(layout) if job == :load
        record(Build.set(layout.scratch(:copy), copy))
        record(Build.call(layout.routine(job)))
      end

      def run_save_data_copy(layout, from, to)
        record(Build.set(layout.scratch(:from), from))
        run_save_data(layout, :copy, to)
      end

      # What copy +copy+ is, as a number counting into IR::SaveLayout::STATES; a copy the record
      # does not have reads as empty. It is read from save memory, so the record's jobs are
      # finished first, just before the line that asks.
      def save_data_state(layout, copy)
        finish_save_jobs_of(layout)
        save_data_state_now(layout, copy)
      end

      def save_data_state_now(layout, copy)
        within = sd_in_range(layout, copy)
        index = Build.clamped(copy, sd_int(0), sd_int(layout.copies - 1))
        Build.binop(:*, within, sd_directory(layout, :state, index))
      end

      # The thing a record keeps under +name+, or a friendly error saying what it does keep.
      def save_data_kept(layout, name)
        item = layout.kept.find { |one| one.name == name }
        return item if item

        kept = layout.kept.map { |one| ":#{one.name}" }.join(", ")
        raise ArgumentError, "save_data :#{layout.name} does not keep :#{name}, so a copy cannot be read " \
                             "for it. It keeps #{kept}."
      end

      # A kept variable — or, with +index+, one item of a kept list, or with +length+ how many it
      # holds — read from copy +copy+ without loading it. 0 unless the copy is good, and 0 for an
      # item past the list's end.
      def save_data_peek(layout, copy, item, index: nil, length: false)
        finish_save_jobs_of(layout)
        which = Build.clamped(copy, sd_int(0), sd_int(layout.copies - 1))
        good = sd_eq(save_data_state_now(layout, copy), sd_int(IR::SaveLayout::STATES.index(:good)))
        at = sd_add(sd_half_at(layout, which, sd_directory(layout, :half, which)),
                    sd_int(IR::SaveLayout::HEADER + item.at))
        return Build.binop(:*, good, sd_read(at)) if item.kind == :var || length

        saved = Build.clamped(sd_read(at), sd_int(0), sd_int(item.count))
        inside = sd_and(Build.binop(:>=, index, sd_int(0)), Build.binop(:<, index, saved))
        slot = Build.clamped(index, sd_int(0), sd_int(item.count - 1))
        bytes = WIDTH_BYTES.fetch(item.width)
        place = sd_add(sd_add(at, sd_int(4)), Build.binop(:*, slot, sd_int(bytes)))
        Build.binop(:*, sd_and(good, inside), sd_read(place, item.width))
      end

      # Whether the last job this record ran did not read back as it should have.
      def save_data_failed(layout) = sd_eq(sd_var(layout.scratch(:failed)), sd_int(1))

      # Whether one of this record's jobs was written on the pass that just ended.
      def save_data_finished(layout) = sd_eq(sd_var(layout.scratch(:finished)), sd_int(1))

      # Whether one of this record's jobs is still in hand — running, or waiting its turn.
      def save_data_saving(layout)
        mine = ->(which) { sd_eq(sd_var(:"__save_jobs_#{which}_rec"), sd_int(layout.number)) }
        Build.binop(:|, mine.call(:run), mine.call(:wait))
      end

      private :save_data_item_of, :save_data_not_state!, :save_data_state_now
    end

    # What `keep` inside a `save_data` block collects: the variables and lists the record
    # keeps, checked as they are named.
    class SaveDataKeeping
      attr_reader :kept

      def initialize(builder, record)
        @builder = builder
        @record = record
        @kept = []
      end

      def keep(*things)
        things.each { |thing| @kept << @builder.save_data_item(@record, thing) }
      end
    end
  end
end
