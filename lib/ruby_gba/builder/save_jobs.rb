# frozen_string_literal: true

module RubyGBA
  class Builder
    # SAVING IN THE BACKGROUND: every save, erase and copy a game asks for is a JOB, and jobs
    # are written into save memory a piece at a time, once a pass of the game loop, while the
    # game goes on.
    #
    # Written in one go, a full-size save file stands the game still for a frame or more: save
    # memory is read and written a byte at a time, and slowly. A piece a pass costs a little of
    # several passes instead, so nothing the player is watching stops.
    #
    # THE SAVE HOLDS THE MOMENT IT WAS ASKED FOR. Asking copies what the record keeps into a
    # buffer of the record's own, there and then, and the buffer is what is written — so the
    # hearts can change on the next pass without the save picking up half of the change. A copy
    # needs no buffer: the copy it reads from changes only through jobs, and jobs run one at a
    # time, in the order they were asked for.
    #
    # ONE JOB RUNS AND ONE WAITS. A second job asked for while one runs waits its turn, which is
    # what a game that saves a file and then its settings wants. Each record has room for two
    # snapshots, so the one waiting and the one running never share. A third asked for while
    # two are already in hand finishes the running one on the spot — a pass that stands still,
    # once, rather than anything lost.
    #
    # READING A RECORD FINISHES ITS JOBS FIRST. A copy's state, a peek at what it holds, and a
    # load all read save memory, so each one first finishes any job of that record still in
    # hand: a file screen shown straight after a save shows the save.
    #
    # The order the bytes go in is the order a save always had — marker and shape, the body,
    # then the sequence and kind, the checksum last of all — so the power going off between two
    # passes is the same as the power going off half way through a save, and loses nothing.
    module SaveJobs
      # How many bytes of a record's body are written each pass: a full-size save file in about
      # five passes.
      BYTES_PER_PASS = 256

      SAVE = 1
      ERASE = 2
      COPY = 3

      SCRATCH = %i[run_rec run_copy run_kind run_slot run_src run_phase run_done run_at run_from serial
                   wait_rec wait_copy wait_kind wait_slot wait_src hold ask_rec ask_copy ask_kind ask_slot ask_src
                   pieces].freeze

      private

      def jobs_name(what) = Messages::MadeNames.make(:save_jobs, piece: what)
      def jv(what) = sd_var(jobs_name(what))
      def jv_set(what, value) = record(Build.set(jobs_name(what), value.is_a?(Integer) ? sd_int(value) : value))
      def job_op(op, lhs, rhs) = Build.binop(op, lhs, rhs)

      # Declared with the first record: the variables the jobs are kept in, and the routines
      # that run them.
      def declare_save_jobs
        SCRATCH.each { |what| ensure_var(jobs_name(what)) }
        %i[tick step finish ask end].each do |job|
          declare_func(jobs_name(job)) { send(:"save_jobs_#{job}") }
        end
        @per_pass_routines << jobs_name(:tick)
      end

      # What each record needs of its own: two snapshots' worth of buffer, kept in the roomy
      # memory since it is read only while a job runs, and the flag that says a job just ended.
      def declare_save_job_state(layout)
        stage = layout.scratch(:stage)
        size = [layout.body * 2, 1].max
        at_boot(Build.list_new(stage, size, width: :byte, fast: false))
        index = layout.scratch(:stage_fill)
        ensure_var(index)
        at_boot(Build.repeat(Build.int(size), index, Build.list_push(stage, Build.int(0))))
        ensure_var(layout.scratch(:finished))
      end

      # ONCE A PASS: last pass's "just finished" is over, and the running job moves on a piece.
      def save_jobs_tick
        @save_data.each_value { |layout| record(Build.set(layout.scratch(:finished), sd_int(0))) }
        record(Build.call(jobs_name(:step)))
      end

      # One piece of the running job, whichever record it belongs to.
      def save_jobs_step
        @save_data.each_value do |layout|
          sd_when(sd_eq(jv(:run_rec), sd_int(layout.number))) { record(Build.call(layout.routine(:step))) }
        end
      end

      # FINISH THE RUNNING JOB NOW, all of it, however many pieces are left. The one waiting
      # behind it then becomes the running one, and is left for the passes to come.
      def save_jobs_finish
        jv_set(:hold, jv(:serial))
        done = sd_or(sd_eq(jv(:run_rec), sd_int(0)), job_op(:!=, jv(:serial), jv(:hold)))
        repeat(IR::SaveLayout::SIZE, stop_when: DSL::Condition.new(self, done)) do |_|
          record(Build.call(jobs_name(:step)))
        end
      end

      # TAKE A JOB, named by the ask scratch: it runs now when nothing does, and waits otherwise.
      # Make room first (see the module comment), and say which of its record's two buffers a
      # snapshot goes in.
      def save_jobs_ask
        sd_when(job_op(:!=, jv(:wait_rec), sd_int(0))) { record(Build.call(jobs_name(:finish))) }
        same_record = sd_eq(jv(:run_rec), jv(:ask_rec))
        jv_set(:ask_slot, sd_int(0))
        sd_when(same_record) { jv_set(:ask_slot, job_op(:-, sd_int(1), jv(:run_slot))) }
      end

      # The job the ask scratch names is snapshotted, if it wanted one: it goes in line.
      def save_jobs_queue
        sd_when(sd_eq(jv(:run_rec), sd_int(0))) do
          %i[rec copy kind slot src].each { |what| jv_set(:"run_#{what}", jv(:"ask_#{what}")) }
          jv_set(:run_phase, 0)
          jv_set(:serial, sd_add(jv(:serial), sd_int(1)))
        end.else do
          %i[rec copy kind slot src].each { |what| jv_set(:"wait_#{what}", jv(:"ask_#{what}")) }
        end
      end

      # The running job is over: the waiting one, if any, runs next.
      def save_jobs_end
        jv_set(:run_rec, 0)
        sd_when(job_op(:!=, jv(:wait_rec), sd_int(0))) do
          %i[rec copy kind slot src].each { |what| jv_set(:"run_#{what}", jv(:"wait_#{what}")) }
          jv_set(:wait_rec, 0)
          jv_set(:run_phase, 0)
          jv_set(:serial, sd_add(jv(:serial), sd_int(1)))
        end
      end

      def sd_or(lhs, rhs) = Build.binop(:|, lhs, rhs)

      # --- per record ---

      # ASK FOR A JOB on +layout+'s copy in its copy scratch: room is made, a save is
      # snapshotted into its buffer there and then, and the job goes in line.
      #
      # What happens when one of this record's jobs is already in hand is the record's to say
      # (`when_busy:`): :wait goes in line behind it; :refuse does nothing and says so with
      # `failed?`; :replace takes the place of a job on the same copy that is still waiting,
      # or abandons one on the same copy that is being written — safe, because a half only
      # counts once its checksum is in, so the copy's last save is still there.
      def save_job_ask(layout, kind)
        jv_set(:ask_rec, layout.number)
        jv_set(:ask_copy, sd_var(layout.scratch(:copy)))
        jv_set(:ask_kind, kind)
        jv_set(:ask_src, kind == COPY ? sd_var(layout.scratch(:from)) : sd_int(0))
        case layout.when_busy
        when :refuse
          sd_when(save_data_saving(layout)) { record(Build.set(layout.scratch(:failed), sd_int(1))) }
            .else { save_job_take(layout, kind) }
        when :replace
          same = lambda do |which|
            sd_and(sd_eq(jv(:"#{which}_rec"), sd_int(layout.number)), sd_eq(jv(:"#{which}_copy"), jv(:ask_copy)))
          end
          sd_when(same.call(:wait)) do
            jv_set(:ask_slot, jv(:wait_slot))
            save_job_snapshot_all(layout, kind)
            %i[kind src].each { |what| jv_set(:"wait_#{what}", jv(:"ask_#{what}")) }
          end.else do
            sd_when(sd_and(same.call(:run), sd_eq(jv(:wait_rec), sd_int(0)))) { jv_set(:run_rec, 0) }
            save_job_take(layout, kind)
          end
        else
          save_job_take(layout, kind)
        end
      end

      # The job the ask scratch names, into line: room made, snapshot taken, queued.
      def save_job_take(layout, kind)
        record(Build.call(jobs_name(:ask)))
        save_job_snapshot_all(layout, kind)
        save_jobs_queue
      end

      def save_job_snapshot_all(layout, kind)
        return unless kind == SAVE

        base = job_op(:*, jv(:ask_slot), sd_int(layout.body))
        layout.kept.each { |item| save_job_snapshot(item, base, layout) }
      end

      # One kept thing into the record's buffer, laid out exactly as it goes into save memory:
      # a variable as a word, a list as its length and then its items, every number lowest byte
      # first.
      def save_job_snapshot(item, base, layout)
        stage = layout.scratch(:stage)
        put = lambda do |offset, value, bytes|
          bytes.times do |b|
            byte = job_op(:&, job_op(:>>, value, sd_int(8 * b)), sd_int(0xFF))
            record(Build.list_set(stage, sd_add(offset, sd_int(b)), byte))
          end
        end
        return put.call(item.value_at(base), sd_var(item.name), SaveData::WORD) if item.kind == :var

        put.call(item.value_at(base), Build.list_len(item.name), SaveData::WORD)
        repeat(DSL::Value.new(self, Build.list_len(item.name))) do |i|
          put.call(item.slot_at(base, i.node), Build.list_get(item.name, i.node), item.slot_bytes)
        end
      end

      # ONE PIECE OF +layout+'s RUNNING JOB. The first piece picks the half to write — the older
      # one — and writes the marker and the shape; each piece after writes up to BYTES_PER_PASS of
      # the body; the pass after the last of the body writes the sequence, the kind and the
      # checksum, looks the copy over again, and ends the job.
      #
      # Each part asks again whose job is running, because ending one hands the line straight to
      # the next — which may be another record's, and must not be run as this one's.
      def save_job_step(layout)
        mine = ->(phase) { sd_and(sd_eq(jv(:run_rec), sd_int(layout.number)), sd_eq(jv(:run_phase), sd_int(phase))) }
        sd_when(mine.call(2)) { save_job_commit(layout) }
        sd_when(mine.call(0)) { save_job_start(layout) }
        sd_when(mine.call(1)) { save_job_piece(layout) }
      end

      def save_job_start(layout)
        copy = jv(:run_copy)
        record(Build.set(layout.scratch(:copy), copy))
        # A copy is wanted only from a good copy that is not the one written over; everything
        # else only needs a copy the record has.
        from = Build.clamped(jv(:run_src), sd_int(0), sd_int(layout.copies - 1))
        source_good = sd_and(sd_and(sd_in_range(layout, jv(:run_src)), job_op(:!=, jv(:run_src), copy)),
                             sd_eq(sd_directory(layout, :state, from), sd_int(IR::SaveLayout::STATES.index(:good))))
        not_a_copy = job_op(:!=, jv(:run_kind), sd_int(COPY))
        wanted = sd_and(sd_in_range(layout, copy), sd_or(not_a_copy, source_good))
        jv_set(:run_from, sd_add(sd_half_at(layout, from, sd_directory(layout, :half, from)),
                                 sd_int(IR::SaveLayout::HEADER)))
        sd_when(sd_eq(wanted, sd_int(0))) { record(Build.call(jobs_name(:end))) }.else do
          jv_set(:run_at, half_to_write(layout, copy))
          open_half(layout, jv(:run_at))
          jv_set(:run_done, 0)
          jv_set(:run_phase, 1)
          sd_when(sd_eq(jv(:run_kind), sd_int(ERASE))) { jv_set(:run_done, layout.body) }
        end
      end

      def save_job_piece(layout)
        left = job_op(:-, sd_int(layout.body), jv(:run_done))
        jv_set(:pieces, Build.clamped(left, sd_int(0), sd_int(BYTES_PER_PASS)))
        sd_when(job_op(:!=, jv(:run_kind), sd_int(ERASE))) do
          body = sd_add(jv(:run_at), sd_int(IR::SaveLayout::HEADER))
          base = job_op(:*, jv(:run_slot), sd_int(layout.body))
          repeat(DSL::Value.new(self, jv(:pieces))) do |i|
            j = sd_add(jv(:run_done), i.node)
            from_buffer = Build.list_get(layout.scratch(:stage), sd_add(base, j))
            from_copy = sd_read(sd_add(jv(:run_from), j), :byte)
            value = job_op(:+, job_op(:*, sd_eq(jv(:run_kind), sd_int(SAVE)), from_buffer),
                           job_op(:*, sd_eq(jv(:run_kind), sd_int(COPY)), from_copy))
            record(Build.save_write(sd_add(body, j), value, width: :byte))
          end
        end
        jv_set(:run_done, sd_add(jv(:run_done), jv(:pieces)))
        sd_when(job_op(:>=, jv(:run_done), sd_int(layout.body))) { jv_set(:run_phase, 2) }
      end

      def save_job_commit(layout)
        copy = jv(:run_copy)
        erase = sd_eq(jv(:run_kind), sd_int(ERASE))
        kind = sd_add(sd_int(IR::SaveLayout::SAVED), job_op(:*, erase, sd_int(IR::SaveLayout::ERASED - IR::SaveLayout::SAVED)))
        record(Build.set(layout.scratch(:copy), copy))
        close_half(layout, jv(:run_at), copy, kind)
        record(Build.set(layout.scratch(:finished), sd_int(1)))
        record(Build.call(jobs_name(:end)))
      end

      # EVERY JOB OF +layout+ STILL IN HAND, finished now — before anything reads the record.
      def finish_save_jobs_of(layout)
        mine = sd_or(sd_eq(jv(:run_rec), sd_int(layout.number)), sd_eq(jv(:wait_rec), sd_int(layout.number)))
        repeat(2, stop_when: DSL::Condition.new(self, sd_eq(mine, sd_int(0)))) do |_|
          record(Build.call(jobs_name(:finish)))
        end
      end
    end
  end
end
