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
      def save_data(name, copies: 1, &block)
        name = name.to_sym
        check_save_data_name!(name, copies, block)
        kept = SaveDataKeeping.new(self, name).tap { |keeping| keeping.instance_eval(&block) }.kept
        record_layout = lay_out_save_data(name, copies, kept)
        @save_data[name] = record_layout
        declare_save_data_state(record_layout)
        declare_save_data_routines(record_layout)
        DSL::SaveData.new(self, record_layout)
      end

      # Everything the routines need to know about one record, worked out once.
      Layout = Data.define(:name, :copies, :kept, :body, :half, :start, :shape) do
        def routine(job) = :"__save_#{name}_#{job}"
        def scratch(what) = :"__save_#{name}_#{what}"
        def directory(what) = :"__save_#{name}_#{what}_of"
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

      # Where each kept thing sits in the body, and where the record's copies sit in save
      # memory: after every record declared before it, so declaring another one later moves
      # nothing that was already saved.
      def lay_out_save_data(name, copies, kept)
        at = 0
        placed = kept.map { |item| item.with(at: at).tap { |one| at += one.bytes } }
        half = IR::SaveLayout.half_bytes(at)
        start = IR::SaveLayout::START + @save_data.each_value.sum { |other| other.half * 2 * other.copies }
        check_save_data_fits!(name, start + (half * 2 * copies))
        shape = Zlib.crc32(placed.map { |item| [item.kind, item.name, item.width, item.count].join(":") }.join(";"))
        Layout.new(name: name, copies: copies, kept: placed, body: at, half: half, start: start,
                   shape: IR::Int32.wrap(shape))
      end

      def check_save_data_fits!(name, ends_at)
        return if ends_at <= IR::SaveLayout::SIZE

        sizes = @save_data.each_value.map { |other| ":#{other.name} #{other.half * 2 * other.copies}" }
        raise ArgumentError, "save_data :#{name} does not fit in save memory. It ends #{ends_at} bytes in, " \
                             "and there are #{IR::SaveLayout::SIZE}. Each copy is kept twice, so a save " \
                             "cut off half way cannot lose it. The records before it take #{sizes.join(', ')} " \
                             "bytes. To fix this, keep less in each record, or use fewer copies."
      end

      # What the game can ask about each copy without reading save memory: whether it is
      # good, which of its two halves is the newer, and that half's sequence number. Worked
      # out at power-on, and again after each job.
      def declare_save_data_state(layout)
        %i[state half seq].each do |what|
          at_boot(Build.list_new(layout.directory(what), layout.copies, width: what == :seq ? :word : :byte))
          layout.copies.times { at_boot(Build.list_push(layout.directory(what), Build.int(0))) }
        end
        %i[copy from source at at0 at1 v0 v1 s0 s1 started winner].each { |what| ensure_var(layout.scratch(what)) }
        layout.copies.times do |copy|
          at_boot(Build.set(layout.scratch(:copy), Build.int(copy)))
          at_boot(Build.call(layout.routine(:scan)))
        end
      end

      def declare_save_data_routines(layout)
        declare_func(layout.routine(:scan)) { save_data_scan(layout) }
        declare_func(layout.routine(:save)) { save_data_save(layout) }
        declare_func(layout.routine(:load)) { save_data_load(layout) }
        declare_func(layout.routine(:erase)) { save_data_erase(layout) }
        declare_func(layout.routine(:copy)) { save_data_copy(layout) }
        declare_func(layout.routine(:reset)) { save_data_reset(layout) }
      end

      # --- the routines' bodies, run while the routines are built ---

      def sd_int(value) = Build.int(value)
      def sd_var(name) = Build.var_ref(name)
      def sd_add(lhs, rhs) = Build.binop(:+, lhs, rhs)
      def sd_eq(lhs, rhs) = Build.binop(:==, lhs, rhs)
      def sd_and(lhs, rhs) = Build.binop(:&, lhs, rhs)
      def sd_read(at, width = :word) = Build.save_read(at, width: width)
      def sd_when(test, &block) = DSL::Condition.new(self, test).then(&block)

      # Where one half of copy +copy+ starts: the record's start, two halves a copy.
      def sd_half_at(layout, copy, half)
        sd_add(sd_int(layout.start),
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

      # SAVE THE GAME'S STATE INTO A COPY: its body into the older half, then the header, the
      # checksum last of all — until that is written the half cannot pass for good, so a save
      # cut off anywhere leaves the other half as the copy. Then the copy is looked over again,
      # which is also what finds a save that did not read back.
      def save_data_save(layout)
        save_data_write(layout, IR::SaveLayout::SAVED) do |body|
          layout.kept.each { |item| save_data_put(item, body) }
        end
      end

      def save_data_erase(layout)
        save_data_write(layout, IR::SaveLayout::ERASED) { |_body| nil }
      end

      # COPY ONE COPY OVER ANOTHER, byte for byte, when the one copied from is good and is not
      # the one written over. Where it reads from is worked out before anything is written, so
      # writing cannot move it.
      def save_data_copy(layout)
        from = sd_var(layout.scratch(:from))
        good = sd_eq(sd_directory(layout, :state, Build.clamped(from, sd_int(0), sd_int(layout.copies - 1))),
                     sd_int(IR::SaveLayout::STATES.index(:good)))
        sd_when(sd_and(sd_and(sd_in_range(layout, from), good),
                       Build.binop(:!=, from, sd_var(layout.scratch(:copy))))) do
          source = sd_add(sd_half_at(layout, from, sd_directory(layout, :half, from)), sd_int(IR::SaveLayout::HEADER))
          record(Build.set(layout.scratch(:source), source))
          save_data_write(layout, IR::SaveLayout::SAVED) do |body|
            repeat(layout.body) do |i|
              record(Build.save_write(sd_add(body, i.node),
                                      sd_read(sd_add(sd_var(layout.scratch(:source)), i.node), :byte), width: :byte))
            end
          end
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
          older = Build.binop(:*, sd_eq(sd_directory(layout, :half, copy), sd_int(0)), sd_int(1))
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
          record(Build.call(layout.routine(:scan)))
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

      # Run one of a record's routines for copy +copy+ (a node).
      def run_save_data(layout, job, copy)
        record(Build.set(layout.scratch(:copy), copy))
        record(Build.call(layout.routine(job)))
      end

      def run_save_data_copy(layout, from, to)
        record(Build.set(layout.scratch(:from), from))
        run_save_data(layout, :copy, to)
      end

      # What copy +copy+ is, as a number counting into IR::SaveLayout::STATES; a copy the record
      # does not have reads as empty.
      def save_data_state(layout, copy)
        within = sd_in_range(layout, copy)
        index = Build.clamped(copy, sd_int(0), sd_int(layout.copies - 1))
        Build.binop(:*, within, sd_directory(layout, :state, index))
      end

      # A saved variable, read from copy +copy+ without loading it: 0 unless the copy is good.
      def save_data_peek(layout, copy, name)
        item = layout.kept.find { |one| one.name == name }
        unless item&.kind == :var
          kept = layout.kept.map { |one| ":#{one.name}" }.join(", ")
          raise ArgumentError, "save_data :#{layout.name} does not keep a variable :#{name}, so a copy " \
                               "cannot be read for it. It keeps #{kept}."
        end

        index = Build.clamped(copy, sd_int(0), sd_int(layout.copies - 1))
        good = sd_eq(save_data_state(layout, copy), sd_int(IR::SaveLayout::STATES.index(:good)))
        at = sd_add(sd_half_at(layout, index, sd_directory(layout, :half, index)),
                    sd_int(IR::SaveLayout::HEADER + item.at))
        Build.binop(:*, good, sd_read(at))
      end

      private :save_data_item_of, :save_data_not_state!
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
