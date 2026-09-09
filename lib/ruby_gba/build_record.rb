# frozen_string_literal: true

module RubyGBA
  # WHAT THE BUILD WORKED OUT about a cartridge: everything a finished ROM needs to report
  # on itself, and nothing it needs to run.
  #
  # A cartridge is finished the moment its header, checksum and padding are written, and it
  # boots on the console knowing none of this. But a great deal was settled on the way there
  # that nobody can recover afterwards by reading the bytes back — which routines were kept
  # in the console's quick memory, where each variable landed, which loops held their counter
  # in a register — and all of it changes what the same statement costs. So `rom.explain`
  # cannot price a frame honestly without it, and the build is the only thing that knows.
  #
  # IT ARRIVES IN ONE PIECE, which is most of why it exists. These were six fields a caller
  # set on a ROM one at a time after assembling it, so between the assemble and the sixth
  # line there was a ROM that was a valid cartridge and half a report — and nothing said
  # which of the two you were holding. Now a ROM either has a record or has none, and having
  # none is exactly what "assembled straight from machine code" means.
  # +build_options+ is what the build was TOLD rather than what it worked out — the cartridge
  # timing it asks for at boot, and whether it chose what to keep in quick memory — and it is
  # here because measuring a cartridge means building it again, the same way: a ROM measured
  # with different settings is not the ROM that ships, and the difference between code in the
  # cartridge and code in the console's quick memory is a factor of about two and a half.
  class BuildRecord < Data.define(:source_program, :placement, :var_addresses, :loop_shapes,
                                  :palette_entries, :column_stretches, :compression,
                                  :build_options)
    # The two routines a program has no name for: the frame's own body, and the one the
    # console jumps into when the display or a timer announces something. The estimate has
    # to be told about each separately for that reason.
    FRAME_ROUTINE = IR::Backends::GBA::Placement::FRAME_ROUTINE
    IRQ_ROUTINE = IR::Backends::GBA::Placement::IRQ_ROUTINE

    # What the cost model needs to know about where this cartridge's code and variables
    # live — both change what the same statement costs.
    def for_cost_model
      decided = { var_addresses: var_addresses, loop_shapes: loop_shapes,
                  palette_entries: palette_entries, column_stretches: column_stretches }.compact
      return decided unless placement

      names = placement.funcs
      { fast_routines: names - [FRAME_ROUTINE, IRQ_ROUTINE],
        fast_frame: names.include?(FRAME_ROUTINE),
        fast_interrupts: names.include?(IRQ_ROUTINE),
        placement: placement }.merge(decided)
    end
  end
end
