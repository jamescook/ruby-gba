# frozen_string_literal: true

module RubyGBA
  module Cartridge
    # WHAT THE BUILD WORKED OUT about a cartridge: everything a finished ROM needs to report
    # on itself, and nothing it needs to run.
    #
    # A cartridge is finished the moment its header, checksum and padding are written, and it
    # boots on the console knowing none of this. But a great deal was settled on the way there
    # that nobody can recover afterwards by reading the bytes back — which routines were kept
    # in the console's quick memory, where each variable landed, which loops held their counter
    # in a register — and where every routine ended up. So `rom.profile` cannot report on a
    # cartridge without it, and the build is the only thing that knows.
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
    #
    # +findings+ is what the guardrails said about the program, kept so a report asked for as
    # data can carry them beside the numbers. Empty until the build's own checks have run — the
    # backend makes the record before those checks exist, since they price with it.
    #
    # +emitted+ is what each node of the program turned into — how many instructions, and how
    # many of them jump. Most of the estimate's weights are a whole number of instructions at
    # one instruction's price, which is a fact the lowering has exactly and a measurement can
    # only recover, so the lowering says it here rather than both saying it separately. See
    # IR::Backends::GBA::Attribution.
    # +routines+ is the span of addresses each routine really occupies while the console runs
    # it, which is what lets a profile of the finished cartridge be reported in the author's own
    # names. It cannot be recovered from the bytes: a routine kept in the console's quick memory
    # was copied there at boot and runs nowhere near where it sits in the cartridge.
    # +video_memory+ is how much of the console's picture memory the sprites and background
    # tiles took, and how much the framework's own choice of storage saved. Nothing in a running
    # cartridge can say the second half: the pictures are there at the size the build chose them,
    # and what they would have cost the other way is gone.
    # +timer_handlers+ is where each timer's on_tick body starts and the rate its program asked
    # for. A handler is emitted inline inside the one routine the console interrupts into, so it
    # has no name of its own in +routines+ — but its first instruction runs exactly once per tick
    # answered, which is what lets a profile count the ticks that really arrived.
    # +voices+ is where the console keeps the sounds it is playing and where each sample landed
    # in the cartridge (see IR::Backends::GBA::Mixer::VoiceTable), or nil for a program that
    # plays no samples. It is what lets a finished cartridge be asked what it is playing.
    # +sound_drops+ is where it counts the sounds it could NOT play, for the same reason and with
    # the same catch: they are hidden variables, so only the build knows their addresses (see
    # IR::Backends::GBA::Mixer::DropTable). nil where nothing plays and nothing can be lost.
    # +sprite_slots+ is which of the console's 128 places each declared sprite was given — one
    # each for most, several in a row for a picture too big to draw in one go. The console's own
    # table says which place a sprite is in and nothing more, so without this nothing can get
    # from a place back to the name the game wrote. Empty for a game with no sprites.
    # +sprite_offsets+ is how far along the build moved each of a sprite's stored poses, and it
    # is what keeps +sprite_slots+ honest about WHERE. A pose is stored trimmed to the part of
    # the canvas it actually draws on, and the sprite is then told to stand that much further
    # along so the picture lands where the author put it — and a pose drawn backwards is trimmed
    # from the other side, so it stands a different amount further along. Both are the build's
    # own doing and neither is anything the game wrote, so a place read back off the console has
    # to have them taken off again before it means the corner of the picture. Keyed by the place
    # in that table, then by the two things a row of it says about which pose it is holding: its
    # first tile, and whether it is being drawn backwards.
    # +sprite_pose_in_room+ is the exception to that keying, and it exists because a sprite with
    # more pictures than sprite memory holds keeps ONE of them there at a time — so every pose of
    # it goes into the same place, and the place stops telling the poses apart. Such a sprite's
    # +sprite_offsets+ are counted by pose number instead, and this says where to read the pose
    # number from: the address of the variable the cartridge writes as it copies a frame in. A
    # place in here is what says which of the two keyings that place's offsets use. Empty for a
    # game whose sprites all keep every picture they can show.
    class BuildRecord < Data.define(:source_program, :placement, :var_addresses, :loop_shapes,
                                    :palette_entries, :column_stretches, :compression,
                                    :build_options, :findings, :emitted, :routines, :video_memory,
                                    :roomy_memory, :timer_handlers, :voices, :sound_drops,
                                    :sprite_slots, :sprite_offsets, :sprite_pose_in_room)
      def initialize(findings: [], emitted: nil, routines: {}, video_memory: nil,
                     roomy_memory: nil, timer_handlers: {}, voices: nil, sound_drops: nil,
                     sprite_slots: {}, sprite_offsets: {}, sprite_pose_in_room: {}, **rest)
        super
      end

      # The two routines a program has no name for: the frame's own body, and the one the
      # console jumps into when the display or a timer announces something.
      FRAME_ROUTINE = IR::Backends::GBA::Placement::FRAME_ROUTINE
      IRQ_ROUTINE = IR::Backends::GBA::Placement::IRQ_ROUTINE

      # Whether the frame's own body was kept in the console's quick memory. It is the single
      # most valuable thing to keep there — where nearly all of a frame's time goes — so a
      # guardrail asks, and so does anything reporting on the build.
      def fast_frame? = placement ? placement.funcs.include?(FRAME_ROUTINE) : false
    end
  end
end
