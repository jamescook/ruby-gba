# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Reference
        # WRITE A COPY OF A RECORD INTO SAVE MEMORY, holding values a test chose, so a game starts
        # from that save rather than being played until it makes one:
        #
        #   image = Reference.save_into(SaveImage.new, program, :file, 0, hearts: 12, name: [76, 73])
        #   Reference.new(save: image).run(program)     # ...or the Verifier's save:, or to_sav
        #
        # It is written by the game's own code, not by a second writer of the format. The game
        # is powered on against the save memory and run to its first frame — which lays out the
        # table of places as power-on always does — the record's own `reset` puts what it keeps
        # back as declared, the kept things the test names are given its values, and the
        # record's own save routine runs to the end. So the copy is byte for byte the one the
        # game would have written with those values, on any size of save memory: it goes into
        # the copy's older half and counts newer than what was there, and the record's other
        # copies and the other records are not touched. The format stays private to the build,
        # where the next change to it is made in one place.
        #
        # What else changes is what any power-on of the game changes — the table of places, and
        # whatever the game itself saves before its first frame. The random numbers are the one
        # kept thing `reset` leaves rolling, so unnamed they are wherever power-on left them.
        module SaveWriting
          # The things a test can write into a copy, said in an error that refuses another.
          WRITABLE = "a variable (a number), a list (an Array of numbers) and random_numbers (a number)"

          def self.included(base) = base.extend(ClassMethods)

          module ClassMethods
            # Write copy +copy+ of record +record+ into +image+, holding +values+: a number for a
            # variable (a Float for one that holds a fraction), an Array for a list, and a number
            # for :random_numbers. Returns +image+.
            def save_into(image, program, record, copy, **values)
              new(save: image).run(program, frames: 0).write_save_copy(program, record, copy, values)
              image
            end
          end

          # Give record +record+'s kept things +values+ and save copy +copy+, then finish the
          # save. Called on an interpreter that has run +program+ to its first frame.
          def write_save_copy(program, record, copy, values)
            name, _half, copies, kept = save_record_named(program, record)
            refuse_copy_out_of_range!(name, copy, copies)
            call_func(save_routine(name, :reset)) # the power-on code may have loaded another copy
            values.each { |key, value| put_kept_value(name, kept, key, value) }

            @vars[save_routine(name, :copy)] = copy
            call_func(save_routine(name, :save))
            # The running save and one waiting behind it, each to the end: two is as many as the
            # game ever holds (see Builder::SaveJobs#emit_finish_jobs_of).
            2.times do
              call_func(Messages::MadeNames.make(:save_jobs, piece: :await_wipe))
              call_func(Messages::MadeNames.make(:save_jobs, piece: :finish))
            end
            refuse_save_not_taken!(name) if @vars[save_routine(name, :failed)] == 1
            self
          end

          private

          def save_routine(record, piece) = Messages::MadeNames.make(:save_record, record: record, piece: piece)

          def save_record_named(program, record)
            records = save_records_of(program)
            found = records.find { |one| one.first == record }
            return found if found

            known = records.map { |one| ":#{one.first}" }
            raise ArgumentError,
                  "This program declares no save_data :#{record}. " +
                  (known.empty? ? "It declares no save_data records." : "Its save_data records are #{known.join(', ')}.")
          end

          def save_records_of(program)
            node = program.walk.find { |one| one.kind == :save_memory }
            (node&.records || []).reject { |one| one.first == SaveLayout::SAVE_VAR_RECORD }
          end

          def refuse_copy_out_of_range!(name, copy, copies)
            return if copy.is_a?(Integer) && copy >= 0 && copy < copies

            raise ArgumentError,
                  "save_data :#{name} has #{copies} #{copies == 1 ? 'copy' : 'copies'}, numbered 0 to #{copies - 1}. " \
                  "There is no copy #{copy.inspect}."
          end

          # A record that refuses a save while one of its own is in hand refused this one: the
          # game's power-on code asked for a save and it was still being written.
          def refuse_save_not_taken!(name)
            raise ArgumentError,
                  "save_data :#{name} refused the save, because the game started a save of :#{name} before its " \
                  "first frame and that save was not finished. To fix this, give :#{name} `when_busy: :wait`, " \
                  "or write the copy into a save memory the game does not save into at power-on."
          end

          def put_kept_value(record, kept, key, value)
            entry = kept.find { |one| test_name_of(one) == key }
            refuse_unkept_name!(record, kept, key) if entry.nil?

            kind, name, bits = entry
            case kind
            when :var then put_kept_number(record, name, bits, value)
            when :random_numbers then put_kept_number(record, name, nil, value, called: :random_numbers)
            when :list then put_kept_list(record, name, bits, value)
            else refuse_pool!(record, entry)
            end
          end

          # The name a test gives a kept thing: its own name, the word for the random numbers,
          # and a pool's field by the field.
          def test_name_of(entry)
            kind, name, field = entry
            case kind
            when :random_numbers then :random_numbers
            when :pool_field then field
            else name
            end
          end

          def refuse_unkept_name!(record, kept, key)
            names = kept.map do |kind, name, field|
              case kind
              when :random_numbers then ":random_numbers"
              when :pool then ":#{name} (a pool)"
              when :pool_field then ":#{field} of the pool :#{name}"
              else ":#{name}"
              end
            end
            raise ArgumentError, "save_data :#{record} does not keep :#{key}. It keeps #{names.join(', ')}."
          end

          def refuse_pool!(record, entry)
            kind, pool, field = entry
            what = kind == :pool ? "the pool :#{pool}" : "the field :#{field} of the pool :#{pool}"
            raise ArgumentError,
                  "save_data :#{record} keeps #{what}, and a test cannot write a pool into a copy. A test can write " \
                  "#{WRITABLE}. To fix this, leave :#{pool} out, and let the game fill the pool before it saves."
          end

          # A whole number, or a Float for a variable that holds a fraction, which is kept
          # multiplied up by its own scale.
          def put_kept_number(record, name, bits, value, called: name)
            unless value.is_a?(Numeric)
              raise ArgumentError, "save_data :#{record} keeps :#{called} as a number, and the test gave it " \
                                   "#{value.inspect}. Give :#{called} a number."
            end
            @vars[name] = stored_number(record, called, bits, value)
          end

          def put_kept_list(record, name, bits, value)
            unless value.is_a?(Array) && value.all?(Numeric)
              raise ArgumentError, "save_data :#{record} keeps :#{name} as a list, and the test gave it " \
                                   "#{value.inspect}. Give :#{name} an Array of numbers."
            end
            list = @lists.fetch(name)
            if value.length > list.capacity
              raise ArgumentError, "save_data :#{record} keeps :#{name}, a list of at most #{list.capacity} " \
                                   "items, and the test gave it #{value.length}. Give it #{list.capacity} or fewer."
            end
            stored = value.map { |one| stored_number(record, name, bits, one) }
            refuse_unfitting_items!(record, name, list, stored)
            list.replace(stored)
          end

          # A Float is right for something that holds a fraction and only there, and a whole
          # number the other way round — either mistake would store a number a long way off.
          def stored_number(record, name, bits, value)
            if bits && !value.is_a?(Float)
              raise ArgumentError, "save_data :#{record} keeps :#{name}, which holds a fraction, and the test gave " \
                                   "it #{value.inspect}. Give it a Float, like #{value.to_f}."
            elsif bits.nil? && value.is_a?(Float)
              raise ArgumentError, "save_data :#{record} keeps :#{name}, which holds whole numbers, and the test " \
                                   "gave it #{value.inspect}. Give it a whole number."
            end
            bits ? (value * (1 << bits)).round : value
          end

          def refuse_unfitting_items!(record, name, list, stored)
            range = list.slot_range
            bad = stored.find { |one| !range.cover?(one) }
            return if bad.nil?

            raise ArgumentError, "save_data :#{record} keeps :#{name}, whose items each hold #{range.min} to " \
                                 "#{range.max}, and the test gave it #{bad}. Give each item a number in that range."
          end
        end
      end
    end
  end
end
