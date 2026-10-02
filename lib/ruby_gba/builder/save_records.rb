# frozen_string_literal: true

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
    # IR::SaveLayout) and the arithmetic every backend already runs, so the interpreter and the
    # console cannot disagree about the rules that keep a save safe. Each is written once: two
    # halves per copy and the newer one wins (#save_data_scan), the order a half is written in
    # with its checksum last (SaveHalf), and where each kept thing sits in a body (Kept).
    module SaveRecords
      # One thing a record keeps, and where in its body it sits — the one place that says how a
      # kept thing is laid out. A variable is a word at +at+. A list is its length, a word at
      # +at+, and then +count+ slots of +width+ each, the first right after the length.
      #
      # +base+ below is where the body starts, as the program works it out: a half in save
      # memory, or the snapshot a background save copies the kept things into first.
      Kept = Data.define(:kind, :name, :at, :width, :count) do
        def bytes = kind == :var ? WORD : WORD + (count * slot_bytes)
        def slot_bytes = SaveRecords::WIDTH_BYTES.fetch(width)

        # Where the variable, or the list's length, sits.
        def value_at(base) = IR::Build.binop(:+, base, IR::Build.int(at))

        # Where slot +index+ of the list sits.
        def slot_at(base, index)
          IR::Build.binop(:+, IR::Build.binop(:+, value_at(base), IR::Build.int(WORD)),
                          IR::Build.binop(:*, index, IR::Build.int(slot_bytes)))
        end
      end

      WORD = 4

      WIDTH_BYTES = { byte: 1, half: 2, word: 4 }.freeze

      # Declare a record of the game's state, kept in save memory in +copies+ numbered
      # copies. The block, if there is one, names what it keeps with `keep`; the handle's own
      # `keep` adds more later, from anywhere in the program. Returns a handle: `files[n]` is
      # one copy, and a copy saves, loads, erases and says whether it is good.
      #
      # THE RECORD IS USABLE AT ONCE AND LAID OUT AT THE END. A file-select screen comes first
      # in a game and has to save and peek at the record, while what the record keeps belongs
      # to the gameplay declared after it. So nothing here depends on what is kept: the handle
      # knows the record's name, its copies and its variables, which is all a save, a load or a
      # state test names where it is written. Where each kept thing sits, how big a copy is and
      # whether the records fit are worked out once the whole program is declared
      # (#lay_out_save_records), and every routine that reads them is built then.
      def declare(name, copies:, when_busy:, &block)
        name = name.to_sym
        check_save_data_name!(name, copies)
        check_save_data_when_busy!(name, when_busy)
        declare_save_jobs if @save_data.empty?
        place = Messages::MadeNames.make(:save_record, record: name, piece: :place)
        record_layout = Layout.new(name: name, copies: copies, kept: nil, body: nil, half: nil, place: place,
                                   shape: nil, key: IR::SaveLayout.record_key(name),
                                   number: @save_data.size + 1, when_busy: when_busy, pools: nil)
        check_save_data_count!(record_layout)
        @save_data[name] = record_layout
        @save_data_keeping[name] = []
        declare_save_data_vars(record_layout)
        SaveDataKeeping.new(self, name).instance_eval(&block) if block
        DSL::SaveData.new(handle, self, record_layout)
      end

      # Add +things+ to what record +name+ keeps, after the ones already kept.
      def save_data_keep(name, things)
        if @save_data_settled
          raise ArgumentError, "save_data :#{name} is already laid out in save memory, so it cannot keep more. " \
                               "To fix this, call `keep` while the program is declared."
        end
        things.each do |thing|
          next @save_data_keeping.fetch(name) << keep_pool_part(name, thing) if pool_part?(thing)

          @save_data_keeping.fetch(name) << claim_kept_item!(name, thing)
        end
      end

      # A POOL, OR ONE FIELD OF ONE, is kept as the lists and variables it is made of, which
      # are only all known once the program is built (see DSL::Pool#saved_lists_and_vars) — so it is
      # held as it is until the record is laid out. Kept twice is refused here, where the
      # game wrote it: a whole pool claims each of its fields, so a field kept elsewhere
      # clashes with it too.
      def pool_part?(thing) = thing.is_a?(DSL::Pool) || thing.is_a?(DSL::Pool::Column)

      def keep_pool_part(record, thing)
        pool = thing.is_a?(DSL::Pool) ? thing : thing.pool
        names = thing.is_a?(DSL::Pool) ? pool.field_names.map { |one| pool.field_list(one) } : [pool.field_list(thing.field)]
        names.each do |name|
          if (owner = @save_data_kept[name])
            raise ArgumentError, "save_data :#{record} keeps #{thing.inspect}, and save_data :#{owner} keeps it " \
                                 "too. To fix this, keep it in one of them."
          end
        end
        names.each { |name| @save_data_kept[name] = record }
        thing
      end

      # What a pool, or one field of one, is kept as, now that the program is built: each list
      # at the width and length it was made with, and each variable as a word.
      def pool_items(thing)
        lists, vars = thing.is_a?(DSL::Pool) ? thing.saved_lists_and_vars : [[thing.pool.field_list(thing.field)], []]
        lists.map { |name| kept_list(name) } +
          vars.map { |name| Kept.new(kind: :var, name: name, at: 0, width: :word, count: 1) }
      end

      def kept_list(name)
        made = list_new_node(name)
        Kept.new(kind: :list, name: name, at: 0, width: made.width || :word, count: made.capacity)
      end

      # LAY EVERY RECORD OUT, once the whole program is declared: where each kept thing sits,
      # how big a copy is, whether the records fit in save memory, and every routine that
      # reads or writes them — the table of places, the job queue, each record's own. The
      # Builder calls this after building every routine the game wrote, which is the last
      # place a `keep` can come from, and builds the routines declared here after it.
      def lay_out_save_records
        return if @save_data.empty? || @save_data_settled

        @save_data_settled = true
        @save_data.transform_values! { |layout| layout_with_kept(layout) }
        @save_memory = pick_save_memory!
        declare_save_places
        declare_save_job_routines
        @save_data.each_value { |layout| declare_save_data_record(layout) }
      end

      # Everything the routines need to know about one record, worked out once. +place+ is
      # where it starts in save memory: a number for the table of places, which never moves,
      # and for a record the name of a variable, set at power-on from that table. +number+
      # counts the records from 1 in the order they were declared, which is how a job says
      # whose it is; the table of places, which is written without jobs, is 0.
      #
      # +pools+ is each pool, and each field of one, the record keeps (their lists and variables
      # are in +kept+ too), for the reset that has to put a pool back rather than empty it.
      #
      # Until the program is fully declared a record's +kept+, +body+, +half+, +shape+ and
      # +pools+ are nil (see #declare), so anything that reads them too early fails where it
      # reads.
      Layout = Data.define(:name, :copies, :kept, :body, :half, :place, :shape, :key, :number, :when_busy,
                           :pools) do
        def routine(job) = Messages::MadeNames.make(:save_record, record: name, piece: job)
        def scratch(what) = Messages::MadeNames.make(:save_record, record: name, piece: what)
        def directory(what) = Messages::MadeNames.make(:save_directory, record: name, kept: what)
        def region = half * 2 * copies
        def place_node = place.is_a?(Integer) ? Build.int(place) : Build.var_ref(place)
      end

      private

      def check_save_data_name!(name, copies)
        unless Messages::MadeNames::RECORD_NAME.match?(name)
          raise ArgumentError, "save_data #{name.inspect}: this name cannot name a record. A record name is " \
                               "letters and digits, with one underscore between words (for example " \
                               ":file or :high_scores). Use a name of that form."
        end
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
      def lay_out_save_data(name, copies, kept, place:, number: 0, when_busy: :wait, pools: [])
        at = 0
        placed = kept.map { |item| item.with(at: at).tap { |one| at += one.bytes } }
        shape = IR::SaveLayout.shape(placed.map { |item| [item.kind, item.name, item.width, item.count] })
        Layout.new(name: name, copies: copies, kept: placed, body: at, half: IR::SaveLayout.half_bytes(at),
                   place: place, shape: shape, key: IR::SaveLayout.record_key(name), number: number,
                   when_busy: when_busy, pools: pools)
      end

      def check_save_data_count!(layout)
        records = [*@save_data.each_value, layout]
        if records.length > IR::SaveLayout::TABLE_ROWS
          raise ArgumentError, "save_data :#{layout.name} is record #{records.length}, and a game can have " \
                               "#{IR::SaveLayout::TABLE_ROWS}. To fix this, keep more in fewer records."
        end
        return unless (same = @save_data.each_value.find { |other| other.key == layout.key })

        raise ArgumentError, "save_data :#{layout.name} and save_data :#{same.name} have names the save " \
                             "memory cannot tell apart. To fix this, rename one of them."
      end

      # HOW MUCH SAVE MEMORY THE CARTRIDGE HAS: the smallest that holds every record, or the
      # size the game named with `save_memory:`. Asked once the records are laid out, since
      # what they keep is only known then.
      def pick_save_memory!
        halves = @save_data.values.map { |one| [one.half, one.copies] }
        pinned = @port.save_memory
        if pinned
          refuse_records_over_pinned_memory!(pinned, halves) unless IR::SaveLayout.fits?(pinned, halves)
          pinned
        else
          IR::SaveLayout.smallest_fitting(halves) || refuse_records_over_all_memory!
        end
      end

      # The records in the order they were declared, each with what it keeps laid out. The
      # first that does not fit beside the ones before it is the one named.
      def refuse_records_over_all_memory!
        records = @save_data.values
        over = records.each_index.find do |i|
          !IR::SaveLayout.fits?(IR::SaveLayout::MEMORIES.last, records[0..i].map { |one| [one.half, one.copies] })
        end
        sizes = records.map { |one| ":#{one.name} #{one.region}" }
        raise ArgumentError, "save_data :#{records[over].name} does not fit in save memory. The biggest save " \
                             "memory a cartridge can have is 128K, and the records need more. Each copy is " \
                             "kept twice, so a save cut off half way cannot lose it. The records take " \
                             "#{sizes.join(', ')} bytes. To fix this, keep less in each record, or use " \
                             "fewer copies."
      end

      def refuse_records_over_pinned_memory!(pinned, halves)
        needed = IR::SaveLayout.smallest_fitting(halves) or refuse_records_over_all_memory!
        raise ArgumentError, "This game asks for `save_memory: #{pinned}`, and its save_data records need " \
                             "#{needed}K. To fix this, ask for `save_memory: #{needed}`, or keep less in " \
                             "each record, or use fewer copies."
      end

      # +layout+ with what it keeps laid out — or a friendly error for a record that keeps
      # nothing, which would save an empty copy and load nothing back.
      def layout_with_kept(layout)
        keeping = @save_data_keeping.fetch(layout.name)
        pools = keeping.select { |one| pool_part?(one) }
        kept = keeping.flat_map { |one| pool_part?(one) ? pool_items(one) : [one] }
        if kept.empty?
          raise ArgumentError, "save_data :#{layout.name} keeps nothing, so a save of it has nothing to save. " \
                               "To fix this, name what it keeps: `files.keep hearts`, or " \
                               "`save_data :#{layout.name} do keep hearts end`."
        end

        lay_out_save_data(layout.name, layout.copies, kept, place: layout.place, number: layout.number,
                                                            when_busy: layout.when_busy, pools: pools)
      end

      # One record's lists, buffer, power-on scans and routines, once it is laid out.
      def declare_save_data_record(layout)
        declare_save_data_lists(layout)
        declare_save_snapshot_buffer(layout)
        layout.copies.times do |copy|
          at_boot(Build.set(layout.scratch(:copy), Build.int(copy)))
          at_boot(Build.call(layout.routine(:scan)))
        end
        declare_save_data_routines(layout, %i[scan load reset])
        { save: SaveJobs::SAVE, erase: SaveJobs::ERASE, copy: SaveJobs::COPY }.each do |job, kind|
          declare_func(layout.routine(job)) { save_job_request(layout, kind) }
        end
        declare_func(layout.routine(:step)) { save_job_run_phase(layout) }
      end

      # The variables a record's routines work in, and the one its place in save memory is
      # kept in. Named where the record is declared, because the lines that save it or ask
      # about it name them before the record is laid out.
      def declare_save_data_vars(layout)
        %i[copy from at at0 at1 v0 v1 s0 s1 started winner failed].each { |what| ensure_var(layout.scratch(what)) }
        ensure_var(layout.place) unless layout.place.is_a?(Integer)
      end

      # What the game can ask about each copy without reading save memory: whether it is
      # good, which of its two halves is the newer, and that half's sequence number. Worked
      # out at power-on, and again after each job.
      def declare_save_data_lists(layout)
        %i[state half seq].each do |what|
          at_boot(Build.list_new(layout.directory(what), layout.copies, width: what == :seq ? :word : :byte))
          layout.copies.times { at_boot(Build.list_push(layout.directory(what), Build.int(0))) }
        end
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
      def sd_when(test, &block) = DSL::Condition.new(handle, test).then(&block)

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
          layout.kept.each { |item| emit_write_kept_item(item, body) }
        end
      end

      # A NEW GAME: each kept variable set to what it was declared with, each kept list emptied.
      # The random numbers roll on: a new game that started them where power-on does would
      # play the same rolls as every new game before it.
      #
      # A kept pool is put back as power-on leaves it — every slot there and free — rather than
      # emptied the way a kept list is, which would leave it with no slots at all. A field kept
      # on its own is nought in every slot.
      def save_data_reset(layout)
        pooled = layout.pools.flat_map { |part| pool_items(part).map(&:name) }
        layout.pools.each { |part| reset_pool_part(part, layout.pools) }
        layout.kept.each do |item|
          next if random_numbers?(item.name) || pooled.include?(item.name)
          next repeat(DSL::Value.new(handle, Build.list_len(item.name))) { |_| record(Build.list_drop(item.name, from: :back)) } if item.kind == :list

          start = start_value(item.name)
          record(Build.set(item.name, start ? start.copy : sd_int(0)))
        end
      end

      def reset_pool_part(part, parts)
        return pool_refill(part).each { |node| record(node) } if part.is_a?(DSL::Pool)
        return if parts.include?(part.pool) # the whole pool's refill puts this field back too

        list = part.pool.field_list(part.field)
        repeat(part.pool.capacity) { |i| record(Build.list_set(list, i.node, sd_int(0))) }
      end

      # A whole half written in one go, in the safe order (see SaveHalf): opened, the body the
      # block writes, closed.
      def save_data_write(layout, kind)
        copy = sd_var(layout.scratch(:copy))
        sd_when(sd_in_range(layout, copy)) do
          record(Build.set(layout.scratch(:at), half_to_write(layout, copy)))
          here = sd_var(layout.scratch(:at))
          emit_half_header(layout, here)
          yield sd_add(here, sd_int(IR::SaveLayout::HEADER))
          emit_half_commit(layout, here, copy, kind)
        end
      end

      # One kept thing into the body: a variable as a word; a list as its length and then its
      # items, at the width the list keeps them.
      def emit_write_kept_item(item, body)
        return record(Build.save_write(item.value_at(body), sd_var(item.name))) if item.kind == :var

        record(Build.save_write(item.value_at(body), Build.list_len(item.name)))
        repeat(DSL::Value.new(handle, Build.list_len(item.name))) do |i|
          record(Build.save_write(item.slot_at(body, i.node), Build.list_get(item.name, i.node), width: item.width))
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
            layout.kept.each { |item| emit_read_kept_item(item, body) }
          end
        end
      end

      def emit_read_kept_item(item, body)
        return record(Build.set(item.name, sd_read(item.value_at(body)))) if item.kind == :var

        repeat(DSL::Value.new(handle, Build.list_len(item.name))) { |_| record(Build.list_drop(item.name, from: :back)) }
        count = Build.clamped(sd_read(item.value_at(body)), sd_int(0), sd_int(item.count))
        repeat(DSL::Value.new(handle, count)) do |i|
          record(Build.list_push(item.name, sd_read(item.slot_at(body, i.node), item.width)))
        end
      end

      public

      # What one thing named in `keep` is, checked: a variable or a list the game declared,
      # kept by no other record, and not a `save_var`, which saves itself as it changes.
      def claim_kept_item!(record, thing)
        item = kept_item_for(record, thing)
        if (owner = @save_data_kept[item.name])
          them = random_numbers?(item.name) ? "them" : "it"
          raise ArgumentError, "save_data :#{record} keeps #{kept_words(item.name)}, and save_data :#{owner} " \
                               "keeps #{them} too. To fix this, keep #{them} in one of them."
        end
        if save_var?(item.name)
          raise ArgumentError, "save_data :#{record} keeps :#{item.name}, which is a `save_var`. A save_var " \
                               "saves itself each time it changes. To fix this, declare it with `var`, " \
                               "or leave it out of the record."
        end

        @save_data_kept[item.name] = record
        item
      end

      def kept_item_for(record, thing)
        case thing
        when DSL::RandomNumbers
          Kept.new(kind: :var, name: thing.name, at: 0, width: :word, count: 1)
        when DSL::List
          made = list_new_node(thing.name)
          Kept.new(kind: :list, name: thing.name, at: 0, width: made.width || :word,
                   count: made.capacity)
        when DSL::Value
          return Kept.new(kind: :var, name: thing.name, at: 0, width: :word, count: 1) if thing.name

          refuse_non_state_keep!(record, "a number worked out from other things")
        else
          refuse_non_state_keep!(record, thing.inspect)
        end
      end

      def refuse_non_state_keep!(record, what)
        raise ArgumentError, "save_data :#{record} was asked to keep #{what}. A record keeps the game's " \
                             "own state: the handles `var` and `list` give you. To fix this, pass one of those."
      end

      # --- what the handles call ---

      # Run one of a record's routines for copy +copy+ (a node). A save, an erase or a copy only
      # asks for a job (see SaveJobs); a load reads save memory, so the record's jobs are
      # finished first.
      def emit_save_data_call(layout, job, copy)
        finish_save_jobs_of(layout) if job == :load
        record(Build.set(layout.scratch(:copy), copy))
        record(Build.call(layout.routine(job)))
      end

      def emit_save_data_copy_call(layout, from, to)
        record(Build.set(layout.scratch(:from), from))
        emit_save_data_call(layout, :copy, to)
      end

      # What copy +copy+ is, as a number counting into IR::SaveLayout::STATES; a copy the record
      # does not have reads as empty. It is read from save memory, so the record's jobs are
      # finished first, just before the line that asks.
      def save_data_state_after_jobs(layout, copy)
        finish_save_jobs_of(layout)
        save_data_state_node(layout, copy)
      end

      def save_data_state_node(layout, copy)
        within = sd_in_range(layout, copy)
        index = Build.clamped(copy, sd_int(0), sd_int(layout.copies - 1))
        Build.binop(:*, within, sd_directory(layout, :state, index))
      end

      # ONE PEEK AT A COPY, written wherever the game reads it — which on a file-select screen
      # is before the record says what it keeps, so where the thing sits in a copy is not known
      # yet. The line gets a stand-in for the number, named after the record, and
      # #resolve_save_data_peeks puts the real reading in its place once every record is laid
      # out. What the reading does is fixed here: the record's jobs are finished first, just
      # before the line that asks, because the reading is of save memory.
      #
      # +shape+ is how the game read it: :number for a variable, :item (with +index+) for one
      # item of a list, :length for how many a list holds.
      PeekSite = Data.define(:record, :name, :copy, :shape, :index)

      def peek_stand_in(layout, copy, name, shape, index: nil)
        finish_save_jobs_of(layout)
        stand_in = Messages::MadeNames.make(:save_record, record: layout.name, piece: :"peek#{@save_data_peeks.size}")
        @save_data_peeks[stand_in] = PeekSite.new(record: layout.name, name: name, copy: copy, shape: shape,
                                                  index: index)
        Build.var_ref(stand_in)
      end

      # EVERY PEEK'S STAND-IN REPLACED BY ITS READING, wherever in +program+ it ended up — a
      # stand-in copied along with a condition is replaced where the copy went, too. Called
      # once the whole program is built. A peek at something its record never kept is a
      # friendly error whether or not the game used it; one read the wrong way for what is
      # kept (a list as one number, a variable item by item) is one where it is read.
      def resolve_save_data_peeks(program)
        return if @save_data_peeks.empty?

        @save_data_peeks.each_value { |site| kept_item!(@save_data.fetch(site.record), site.name) }
        holders = program.walk.select { |node| node.attrs.each_value.any? { |value| holds_peek?(value) } }
        holders.each do |node|
          node.attrs.each do |field, value|
            node.public_send(:"#{field}=", replace_peek_stand_ins(value)) if holds_peek?(value)
          end
        end
      end

      # The thing a record keeps under +name+, or a friendly error saying what it does keep.
      def kept_item!(layout, name)
        item = layout.kept.find { |one| one.name == name }
        return item if item

        kept = layout.kept.map { |one| kept_words(one.name) }.join(", ")
        raise ArgumentError, "save_data :#{layout.name} does not keep :#{name}, so a copy cannot be read " \
                             "for it. It keeps #{kept}."
      end

      # A kept thing as a message names it: the random numbers in words, since their variable
      # is the framework's and not a name the game wrote; anything else by its name.
      def kept_words(name) = random_numbers?(name) ? "the random numbers" : ":#{name}"

      def random_numbers?(name) = name == Randomness::RNG_STATE

      # The stream of random numbers, for `keep` inside a record's block (see SaveDataKeeping).
      def random_numbers = handle.random_numbers

      private

      def holds_peek?(value)
        case value
        when IR::Node then value.kind == :var_ref && @save_data_peeks.key?(value.name)
        when Array then value.any? { |element| holds_peek?(element) }
        else false
        end
      end

      def replace_peek_stand_ins(value)
        case value
        when Array then value.map { |element| replace_peek_stand_ins(element) }
        when IR::Node then holds_peek?(value) ? peek_reading(@save_data_peeks.fetch(value.name)) : value
        else value
        end
      end

      # The reading one stand-in stands for, built fresh for each place it is used, since a
      # node belongs to one place in the tree.
      def peek_reading(site)
        layout = @save_data.fetch(site.record)
        item = kept_item!(layout, site.name)
        check_peek_shape!(layout, item, site.shape)
        save_data_peek(layout, site.copy.copy, item, index: site.index&.copy, length: site.shape == :length)
      end

      def check_peek_shape!(layout, item, shape)
        if item.kind == :list && shape == :number
          raise ArgumentError, "save_data :#{layout.name} keeps :#{item.name} as a list, so peek(:#{item.name}) " \
                               "is not one number. To read it, use peek(:#{item.name})[i] for one item, or " \
                               "peek(:#{item.name}).length for how many items it holds."
        end
        return unless item.kind == :var && shape != :number

        raise ArgumentError, "save_data :#{layout.name} keeps :#{item.name} as a variable, so " \
                             "peek(:#{item.name}) has no items and no length. To read it, use " \
                             "peek(:#{item.name}) as a number."
      end

      # A kept variable — or, with +index+, one item of a kept list, or with +length+ how many it
      # holds — read from copy +copy+ without loading it. 0 unless the copy is good, and 0 for an
      # item past the list's end.
      def save_data_peek(layout, copy, item, index: nil, length: false)
        which = Build.clamped(copy, sd_int(0), sd_int(layout.copies - 1))
        good = sd_eq(save_data_state_node(layout, copy), sd_int(IR::SaveLayout::STATES.index(:good)))
        body = sd_add(sd_half_at(layout, which, sd_directory(layout, :half, which)), sd_int(IR::SaveLayout::HEADER))
        return Build.binop(:*, good, sd_read(item.value_at(body))) if item.kind == :var || length

        saved = Build.clamped(sd_read(item.value_at(body)), sd_int(0), sd_int(item.count))
        inside = sd_and(Build.binop(:>=, index, sd_int(0)), Build.binop(:<, index, saved))
        slot = Build.clamped(index, sd_int(0), sd_int(item.count - 1))
        Build.binop(:*, sd_and(good, inside), sd_read(item.slot_at(body, slot), item.width))
      end

      public

      # Whether the last job this record ran did not read back as it should have.
      def save_data_failed(layout) = sd_eq(sd_var(layout.scratch(:failed)), sd_int(1))

      # Whether one of this record's jobs was written on the pass that just ended.
      def save_data_finished(layout) = sd_eq(sd_var(layout.scratch(:finished)), sd_int(1))

      # Whether one of this record's jobs is still in hand — running, or waiting its turn.
      def save_data_saving(layout)
        mine = ->(which) { sd_eq(job_var(:"#{which}_rec"), sd_int(layout.number)) }
        Build.binop(:|, mine.call(:run), mine.call(:wait))
      end

      private :kept_item_for, :refuse_non_state_keep!, :save_data_state_node
    end

    # What `keep` inside a `save_data` block means: the same as the handle's own `keep`.
    class SaveDataKeeping
      def initialize(saves, record)
        @saves = saves
        @record = record
      end

      def keep(*things) = @saves.save_data_keep(@record, things)

      # The one verb a block may need besides the game's own handles: the stream of random
      # numbers, which a game holds no handle to until it asks.
      def random_numbers = @saves.random_numbers
    end
  end
end
