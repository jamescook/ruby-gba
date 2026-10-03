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
    #
    # ON FLASH a half is wiped before it is written, a block at a time, and the chip takes a good
    # part of a frame over each block. So a job on flash starts each block's wipe and goes on to
    # the next pass, and a pass only asks the chip whether it has finished — opening the half
    # once the last block is wiped. Each byte takes the chip a while too, so a pass writes fewer.
    module SaveJobs
      # How many bytes of a record's body are written each pass: a full-size save file in about
      # five passes on battery memory. A byte of flash takes the chip several hundred cycles
      # where battery memory takes a few, so a pass on flash writes an eighth as many.
      BYTES_PER_PASS = 256
      FLASH_BYTES_PER_PASS = 32

      SAVE = 1
      ERASE = 2
      COPY = 3

      # Where the running job has got: just started, writing the body, closing the half, or —
      # on flash only — waiting for the chip to wipe the half, between starting and writing.
      STARTING = 0
      WRITING = 1
      CLOSING = 2
      WIPING = 3

      # How many times waiting out a wipe asks the chip before giving up, the same as the
      # console's own wait for one byte (IR::Backends::GBA::FlashChip::ASKS): far longer than any
      # chip takes, so giving up means the chip is not answering at all.
      WIPE_ASKS = 0x40000

      # WHAT A JOB IS: whose record, which copy, save / erase / copy, which of the record's two
      # buffers holds its snapshot, and the copy a copy reads from. A job is in one of three
      # places — just asked for, running, or waiting behind the running one — and moves between
      # them whole (see #move_job).
      JOB = %i[rec copy kind slot src].freeze
      PLACES = %i[ask run wait].freeze

      # The rest: how far the running job has got, and the queue's own bookkeeping.
      SCRATCH = (PLACES.product(JOB).map { |place, field| :"#{place}_#{field}" } +
                 %i[run_phase run_done run_at run_from run_wiped serial hold pieces]).freeze

      private

      def jobs_name(what) = Messages::MadeNames.make(:save_jobs, piece: what)
      def job_var(what) = sd_var(jobs_name(what))
      def set_job_var(what, value) = record(Build.set(jobs_name(what), value.is_a?(Integer) ? sd_int(value) : value))
      def job_op(op, lhs, rhs) = Build.binop(op, lhs, rhs)

      # Move the whole job in place +from+ into place +to+.
      def move_job(to:, from:) = JOB.each { |field| set_job_var(:"#{to}_#{field}", job_var(:"#{from}_#{field}")) }

      # Declared with the first record: the variables the jobs are kept in, which a line asking
      # whether a record is saving names before any record is laid out.
      def declare_save_jobs
        SCRATCH.each { |what| ensure_var(jobs_name(what)) }
      end

      # Declared once the records are laid out: the routines that run the jobs, which walk
      # every record.
      def declare_save_job_routines
        %i[tick step_running finish await_wipe pick_slot end].each do |job|
          declare_func(jobs_name(job)) { send(:"save_jobs_#{job}") }
        end
        run_each_pass(jobs_name(:tick))
      end

      # What each record needs of its own: two snapshots' worth of buffer, kept in the roomy
      # memory since it is read only while a job runs, and the flag that says a job just ended.
      def declare_save_snapshot_buffer(layout)
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
        record(Build.call(jobs_name(:step_running)))
      end

      # One piece of the running job, whichever record it belongs to.
      def save_jobs_step_running
        @save_data.each_value do |layout|
          sd_when(sd_eq(job_var(:run_rec), sd_int(layout.number))) { record(Build.call(layout.routine(:step))) }
        end
      end

      # FINISH THE RUNNING JOB NOW, all of it, however many pieces are left. The one waiting
      # behind it then becomes the running one, and is left for the passes to come.
      def save_jobs_finish
        set_job_var(:hold, job_var(:serial))
        done = sd_or(sd_eq(job_var(:run_rec), sd_int(0)), job_op(:!=, job_var(:serial), job_var(:hold)))
        repeat(@save_memory_layout.size, stop_when: DSL::Condition.new(handle, done)) do |_|
          record(Build.call(jobs_name(:step_running)))
        end
      end

      # LET A WIPE THE RUNNING JOB STARTED FINISH, on flash: the chip takes no other command
      # while it wipes, and a read anywhere in it can come back as the chip saying it is busy.
      # So anything that reads save memory, or drops the running job, comes here first. Stepping
      # the job is what asks the chip, and the job goes on to write once the half is wiped.
      #
      # A line that reads a record can come before the records are laid out, which is when the
      # build learns whether the memory is flash, so it always calls this; on battery memory
      # there is nothing to wait for and the routine is empty.
      def save_jobs_await_wipe
        return unless @save_memory_layout.flash?

        wiping = sd_and(job_op(:!=, job_var(:run_rec), sd_int(0)), sd_eq(job_var(:run_phase), sd_int(WIPING)))
        repeat(WIPE_ASKS, stop_when: DSL::Condition.new(handle, sd_eq(wiping, sd_int(0)))) do |_|
          record(Build.call(jobs_name(:step_running)))
        end
      end

      # TAKE A JOB, named by the ask scratch: it runs now when nothing does, and waits otherwise.
      # Make room first (see the module comment), and say which of its record's two buffers a
      # snapshot goes in.
      def save_jobs_pick_slot
        sd_when(job_op(:!=, job_var(:wait_rec), sd_int(0))) { record(Build.call(jobs_name(:finish))) }
        same_record = sd_eq(job_var(:run_rec), job_var(:ask_rec))
        set_job_var(:ask_slot, sd_int(0))
        sd_when(same_record) { set_job_var(:ask_slot, job_op(:-, sd_int(1), job_var(:run_slot))) }
      end

      # The job the ask scratch names is snapshotted, if it wanted one: it goes in line.
      def save_jobs_queue
        sd_when(sd_eq(job_var(:run_rec), sd_int(0))) do
          move_job(to: :run, from: :ask)
          set_job_var(:run_phase, STARTING)
          set_job_var(:serial, sd_add(job_var(:serial), sd_int(1)))
        end.else do
          move_job(to: :wait, from: :ask)
        end
      end

      # The running job is over: the waiting one, if any, runs next.
      def save_jobs_end
        set_job_var(:run_rec, 0)
        sd_when(job_op(:!=, job_var(:wait_rec), sd_int(0))) do
          move_job(to: :run, from: :wait)
          set_job_var(:wait_rec, 0)
          set_job_var(:run_phase, STARTING)
          set_job_var(:serial, sd_add(job_var(:serial), sd_int(1)))
        end
      end

      def sd_or(lhs, rhs) = Build.binop(:|, lhs, rhs)

      # Wait out a wipe the running job started (see #save_jobs_await_wipe).
      def await_save_wipe = record(Build.call(jobs_name(:await_wipe)))

      # --- per record ---

      # ASK FOR A JOB on +layout+'s copy in its copy scratch: room is made, a save is
      # snapshotted into its buffer there and then, and the job goes in line.
      #
      # What happens when one of this record's jobs is already in hand is the record's to say
      # (`when_busy:`): :wait goes in line behind it; :refuse does nothing and says so with
      # `failed?`; :replace takes the place of a job on the same copy that is still waiting,
      # or abandons one on the same copy that is being written — safe, because a half only
      # counts once its checksum is in, so the copy's last save is still there.
      def save_job_request(layout, kind)
        set_job_var(:ask_rec, layout.number)
        set_job_var(:ask_copy, sd_var(layout.scratch(:copy)))
        set_job_var(:ask_kind, kind)
        set_job_var(:ask_src, kind == COPY ? sd_var(layout.scratch(:from)) : sd_int(0))
        case layout.when_busy
        when :refuse
          sd_when(save_data_saving(layout)) { record(Build.set(layout.scratch(:failed), sd_int(1))) }
            .else { accept_save_job(layout, kind) }
        when :replace
          same = lambda do |which|
            sd_and(sd_eq(job_var(:"#{which}_rec"), sd_int(layout.number)), sd_eq(job_var(:"#{which}_copy"), job_var(:ask_copy)))
          end
          sd_when(same.call(:wait)) do
            set_job_var(:ask_slot, job_var(:wait_slot))
            save_job_snapshot_all(layout, kind)
            %i[kind src].each { |what| set_job_var(:"wait_#{what}", job_var(:"ask_#{what}")) }
          end.else do
            sd_when(sd_and(same.call(:run), sd_eq(job_var(:wait_rec), sd_int(0)))) do
              await_save_wipe
              set_job_var(:run_rec, 0)
            end
            accept_save_job(layout, kind)
          end
        else
          accept_save_job(layout, kind)
        end
      end

      # The job the ask scratch names, into line: room made, snapshot taken, queued.
      def accept_save_job(layout, kind)
        record(Build.call(jobs_name(:pick_slot)))
        save_job_snapshot_all(layout, kind)
        save_jobs_queue
      end

      def save_job_snapshot_all(layout, kind)
        return unless kind == SAVE

        base = job_op(:*, job_var(:ask_slot), sd_int(layout.body))
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
        return put.call(item.value_at(base), sd_var(item.name), SaveRecords::WORD) if item.kind == :var

        put.call(item.value_at(base), Build.list_len(item.name), SaveRecords::WORD)
        repeat(DSL::Value.new(handle, Build.list_len(item.name))) do |i|
          put.call(item.slot_at(base, i.node), Build.list_get(item.name, i.node), item.slot_bytes)
        end
      end

      # ONE PIECE OF +layout+'s RUNNING JOB. The first piece picks the half to write — the older
      # one — and writes the marker and the shape; each piece after writes up to a pass's bytes of
      # the body; the pass after the last of the body writes the sequence, the kind and the
      # checksum, looks the copy over again, and ends the job. On flash the half is wiped between
      # picking it and writing the marker, a block at a time, over as many passes as that takes.
      #
      # Each part asks again whose job is running, because ending one hands the line straight to
      # the next — which may be another record's, and must not be run as this one's. A wipe
      # started this pass is first asked about next pass, and the body starts on the pass the
      # last block is seen wiped.
      def save_job_run_phase(layout)
        mine = ->(phase) { sd_and(sd_eq(job_var(:run_rec), sd_int(layout.number)), sd_eq(job_var(:run_phase), sd_int(phase))) }
        sd_when(mine.call(CLOSING)) { save_job_commit(layout) }
        sd_when(mine.call(WIPING)) { save_job_wipe(layout) } if @save_memory_layout.flash?
        sd_when(mine.call(STARTING)) { save_job_start(layout) }
        sd_when(mine.call(WRITING)) { save_job_piece(layout) }
      end

      def save_job_start(layout)
        copy = job_var(:run_copy)
        record(Build.set(layout.scratch(:copy), copy))
        # A copy is wanted only from a good copy that is not the one written over; everything
        # else only needs a copy the record has.
        from = Build.clamped(job_var(:run_src), sd_int(0), sd_int(layout.copies - 1))
        source_good = sd_and(sd_and(sd_in_range(layout, job_var(:run_src)), job_op(:!=, job_var(:run_src), copy)),
                             sd_eq(sd_directory(layout, :state, from), sd_int(IR::SaveLayout::STATES.index(:good))))
        not_a_copy = job_op(:!=, job_var(:run_kind), sd_int(COPY))
        wanted = sd_and(sd_in_range(layout, copy), sd_or(not_a_copy, source_good))
        set_job_var(:run_from, sd_add(sd_newer_half_at(layout, from),
                                 sd_int(IR::SaveLayout::HEADER)))
        sd_when(sd_eq(wanted, sd_int(0))) { record(Build.call(jobs_name(:end))) }.else do
          set_job_var(:run_at, half_to_write(layout, copy))
          next save_job_open_half(layout) unless @save_memory_layout.flash?

          set_job_var(:run_wiped, 0)
          record(Build.save_erase(job_var(:run_at), wait: false))
          set_job_var(:run_phase, WIPING)
        end
      end

      # Flash only: once the block being wiped reads 0xFF the chip is done with it, and the next
      # block's wipe starts — or, with the whole half wiped, the half is opened.
      def save_job_wipe(layout)
        block = sd_add(job_var(:run_at), job_var(:run_wiped))
        sd_when(sd_eq(sd_read(block, :byte), sd_int(IR::SaveImage::FRESH_BYTE))) do
          set_job_var(:run_wiped, sd_add(job_var(:run_wiped), sd_int(@save_memory_layout.block)))
          room = sd_int(@save_memory_layout.room(layout.half))
          sd_when(job_op(:<, job_var(:run_wiped), room)) do
            record(Build.save_erase(sd_add(job_var(:run_at), job_var(:run_wiped)), wait: false))
          end.else do
            save_job_open_half(layout)
          end
        end
      end

      # Step 1 of a half (see SaveHalf) into the half the job picked, whose room is wiped by now
      # where it has to be; then the body, or for an erase none.
      def save_job_open_half(layout)
        emit_half_header(layout, job_var(:run_at), wipe: false)
        set_job_var(:run_done, 0)
        set_job_var(:run_phase, WRITING)
        sd_when(sd_eq(job_var(:run_kind), sd_int(ERASE))) { set_job_var(:run_done, layout.body) }
      end

      def save_job_piece(layout)
        left = job_op(:-, sd_int(layout.body), job_var(:run_done))
        per_pass = @save_memory_layout.flash? ? FLASH_BYTES_PER_PASS : BYTES_PER_PASS
        set_job_var(:pieces, Build.clamped(left, sd_int(0), sd_int(per_pass)))
        sd_when(job_op(:!=, job_var(:run_kind), sd_int(ERASE))) do
          body = sd_add(job_var(:run_at), sd_int(IR::SaveLayout::HEADER))
          base = job_op(:*, job_var(:run_slot), sd_int(layout.body))
          repeat(DSL::Value.new(handle, job_var(:pieces))) do |i|
            j = sd_add(job_var(:run_done), i.node)
            from_buffer = Build.list_get(layout.scratch(:stage), sd_add(base, j))
            from_copy = sd_read(sd_add(job_var(:run_from), j), :byte)
            value = job_op(:+, job_op(:*, sd_eq(job_var(:run_kind), sd_int(SAVE)), from_buffer),
                           job_op(:*, sd_eq(job_var(:run_kind), sd_int(COPY)), from_copy))
            record(Build.save_write(sd_add(body, j), value, width: :byte))
          end
        end
        set_job_var(:run_done, sd_add(job_var(:run_done), job_var(:pieces)))
        sd_when(job_op(:>=, job_var(:run_done), sd_int(layout.body))) { set_job_var(:run_phase, CLOSING) }
      end

      def save_job_commit(layout)
        copy = job_var(:run_copy)
        erase = sd_eq(job_var(:run_kind), sd_int(ERASE))
        kind = sd_add(sd_int(IR::SaveLayout::SAVED), job_op(:*, erase, sd_int(IR::SaveLayout::ERASED - IR::SaveLayout::SAVED)))
        record(Build.set(layout.scratch(:copy), copy))
        emit_half_commit(layout, job_var(:run_at), copy, kind)
        record(Build.set(layout.scratch(:finished), sd_int(1)))
        record(Build.call(jobs_name(:end)))
      end

      # EVERY JOB OF +layout+ STILL IN HAND, finished now — before anything reads the record.
      def finish_save_jobs_of(layout)
        await_save_wipe
        mine = sd_or(sd_eq(job_var(:run_rec), sd_int(layout.number)), sd_eq(job_var(:wait_rec), sd_int(layout.number)))
        repeat(2, stop_when: DSL::Condition.new(handle, sd_eq(mine, sd_int(0)))) do |_|
          record(Build.call(jobs_name(:finish)))
        end
      end
    end
  end
end
