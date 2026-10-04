# frozen_string_literal: true

module RubyGBA
  class Builder
    # WHERE A COPY'S HALVES ARE, AND WRITING ONE in the order that keeps a save safe.
    #
    # Every copy of a record is kept twice, and a save goes into the OLDER half, which only
    # counts once the whole of it is in. What makes that true is the order the half is written
    # in, and this is the one place it is written down:
    #
    #   1. OPEN: the marker and the record's shape. From here on a half cut off anywhere reads
    #      as a save that was started, so a copy with no good save before it reads as damaged
    #      rather than as never saved. Neither can make the half pass for good on its own.
    #   2. The body — whatever the caller writes between opening and closing.
    #   3. CLOSE: the sequence number (one past the copy's), the kind (saved or erased), and the
    #      checksum LAST of all. Until the checksum matches, the half is not good, so the other
    #      half is still the copy. Then the copy is looked over again, which is also the read
    #      back: a half that does not come back as it should means the chip did not keep it.
    #
    # Two things write halves, and they are why this is its own piece: the table of places,
    # written whole at power-on (SaveRecords#save_data_write), and a record's saves, written a
    # piece each pass while the game runs (SaveJobs). Both open and close here; what goes
    # between is theirs.
    #
    # An object of its own, made once the records are laid out, since where a half is depends
    # on the save memory they were laid out in and nothing else.
    class SaveHalf
      include SaveProgram

      # +memory+ is the IR::SaveLayout::Memory the records are laid out in.
      def initialize(port, memory:)
        @port = port
        @memory = memory
      end

      # Where one half of copy +copy+ starts: the record's place, two halves a copy, each as far
      # from the last as the save memory gives a half (see IR::SaveLayout::Memory#room).
      def half_at(layout, copy, half)
        room = @memory.room(layout.half)
        sd_add(layout.place_node, sd_add(sd_op(:*, copy, sd_int(room * 2)), sd_op(:*, half, sd_int(room))))
      end

      # Where copy +copy+'s newer half starts. A copy with no good half says -1 for which is
      # newer, so it is held to 0 or 1: a reading of such a copy is thrown away, but the place it
      # read from is still a place in save memory, which a 128K chip reaches by switching to the
      # bank it is in.
      def newer_half_at(layout, copy)
        half_at(layout, copy, Build.clamped(layout.directory_at(:half, copy), sd_int(0), sd_int(1)))
      end

      # Where copy +copy+ is written: its older half, or its first when neither is good.
      def half_to_write(layout, copy)
        half_at(layout, copy, sd_eq(layout.directory_at(:half, copy), sd_int(0)))
      end

      # Step 1: the marker and the shape, into the half starting at +here+ — wiped first, on a
      # memory that has to be (see #emit_room_wipe), unless +wipe+ says the caller wiped it.
      def emit_half_header(layout, here, wipe: true)
        emit_room_wipe(here, @memory.room(layout.half)) if wipe
        { MARKER_AT: sd_int(IR::SaveLayout::MARKER), SHAPE_AT: sd_int(layout.shape) }.each do |field, value|
          record(Build.save_write(sd_add(here, sd_int(IR::SaveLayout.const_get(field))), value))
        end
      end

      # Step 3: the sequence, the kind and the checksum, then the read back. +kind+ is SAVED or
      # ERASED, as a number written in the program or one the game works out. The record's
      # `copy` must already name +copy+, since looking it over reads which copy from there.
      def emit_half_commit(layout, here, copy, kind)
        kind_node = kind.is_a?(Integer) ? sd_int(kind) : kind
        record(Build.save_write(sd_add(here, sd_int(IR::SaveLayout::SEQUENCE_AT)),
                                sd_add(layout.directory_at(:seq, copy), sd_int(1))))
        record(Build.save_write(sd_add(here, sd_int(IR::SaveLayout::KIND_AT)), kind_node))
        record(Build.save_write(sd_add(here, sd_int(IR::SaveLayout::CHECKSUM_AT)),
                                Build.save_sum(sd_add(here, sd_int(IR::SaveLayout::HEADER)), sd_int(layout.body))))
        record(Build.call(layout.routine(:scan)))
        record(Build.set(layout.scratch(:failed), sd_op(:!=, layout.directory_at(:state, copy),
                                                        expected_state_node(kind))))
      end

      private

      # Wipe the +bytes+ of save memory from +here+, which start on a block and cover whole
      # ones. Flash can only turn bits off when it is written, so a half written over an older
      # save has to be wiped back to all bits on first; the 32K memory takes any byte as it is,
      # and a game on it gets nothing here.
      def emit_room_wipe(here, bytes)
        return unless @memory.flash?

        (bytes / @memory.block).times do |i|
          record(Build.save_erase(sd_add(here, sd_int(i * @memory.block))))
        end
      end

      # What a copy reads as once a half of +kind+ is in: good after a save, erased after an
      # erase.
      def expected_state_node(kind)
        good = IR::SaveLayout::STATES.index(:good)
        erased = IR::SaveLayout::STATES.index(:erased)
        return sd_int(kind == IR::SaveLayout::ERASED ? erased : good) if kind.is_a?(Integer)

        erasing = sd_eq(kind, sd_int(IR::SaveLayout::ERASED))
        sd_add(sd_int(good), sd_op(:*, erasing, sd_int(erased - good)))
      end
    end
  end
end
