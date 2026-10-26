# frozen_string_literal: true

require VBlank.root.join("lib/vblank/ir/backends/gba/placement").to_s # FRAME_ROUTINE and IRQ_ROUTINE, re-exported below

module VBlank
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
    # was copied there at boot and runs nowhere near where it sits in the cartridge. The setting
    # up before the game loop is in it too, though it is no routine, and so is each loop in that
    # setting up that fills a list — inside the setting up's own span, which is the one place two
    # spans here overlap (see IR::Backends::GBA#setting_up_addresses).
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
    # +video_copies+ is every copy into video memory the game makes while it runs — tiles it
    # paints, a map handed to a background, a sprite's next frame — each with where the
    # instruction that starts it runs from and how many bytes it moves. That instruction runs
    # once per copy, so a profile counts the copies without anything added to the cartridge.
    # +late_pages+ is where the instructions run from that show a page at once although it was
    # finished too late for its break (see IR::LatePages), so a profile counts those pages the
    # same way — each saying whether it shows the page part way down the picture, where it can
    # tear, or in the break, where it cannot. Empty for a game whose screens all wait.
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
    # +streamed_sprite_pose_vars+ is the exception to that keying, and it exists because a sprite with
    # more pictures than sprite memory holds keeps ONE of them there at a time — so every pose of
    # it goes into the same place, and the place stops telling the poses apart. Such a sprite's
    # +sprite_offsets+ are counted by pose number instead, and this says where to read the pose
    # number from: the address of the variable the cartridge writes as it copies a frame in. A
    # place in here is what says which of the two keyings that place's offsets use. Empty for a
    # game whose sprites all keep every picture they can show.
    # +lists+ is where each list landed — its first slot, its capacity, its width, and where its
    # length is kept (see IR::Backends::GBA::Lists#list_places). It is what lets the build measure
    # its game with every collection held full, which is a state a game reaches only in play.
    # +sprite_runs+ are the runs of that table drawn in an order the game works out (see
    # Builder#draw_in_order), and they are where +sprite_slots+ stops being the whole answer:
    # in such a run a sprite's rows move every frame, to whichever place its turn in the order
    # puts it. Each says where the cartridge keeps the order — a byte per sprite, back to front —
    # and each sprite's own place and how many places it takes, so a place read off the console
    # can be taken back to the sprite in it. Empty for a game that orders nothing.
    # +sprite_turns+ is the other place +sprite_slots+ stops being the whole answer: sprites of
    # scenes never up together take turns at the same places (see IR::SpriteRows), so a place
    # can be any of several sprites. Keyed by the place, each turn says whose it is and its
    # +sprite_offsets+, and where the cartridge keeps the value the variable picking the scenes
    # held when the table was last written for a change of scene — the turn whose value that is
    # is the one in the place. Empty for a game whose places are each one sprite's.
    # +held_sprites+ is the third: a game with more rows than the console's table holds keeps
    # them in a bigger copy, and copies the ones showing into the console's table each frame (see
    # IR::Backends::GBA::SpriteDrawing::HeldTable), so a row of the console's is whichever of the
    # copy's came to it. It says where the cartridge notes, a half a row, which of the copy's
    # rows each holds, and where it counts the rows left out of a full table. nil for a game
    # whose rows fit.
    # +colors_short_at+ is where the console counts each time a sprite drawn with a list of
    # colours that borrows a group found none free, and was drawn in another list's colours
    # (see IR::Backends::GBA::ScreenLayout::LentColors) — a hidden variable, like the dropped
    # sounds' count. nil for a game whose lists all have a group of their own.
    class BuildRecord < Data.define(:source_program, :placement, :var_addresses, :loop_shapes,
                                    :palette_entries, :column_stretches, :compression,
                                    :build_options, :findings, :emitted, :routines, :video_memory,
                                    :roomy_memory, :timer_handlers, :voices, :sound_drops,
                                    :sprite_slots, :sprite_offsets, :streamed_sprite_pose_vars,
                                    :video_copies, :late_pages, :lists, :sprite_runs, :scene_sets,
                                    :missed_routine_parts, :colors_short_at, :sprite_turns, :held_sprites)
      def initialize(findings: [], emitted: nil, routines: {}, video_memory: nil,
                     roomy_memory: nil, timer_handlers: {}, voices: nil, sound_drops: nil,
                     sprite_slots: {}, sprite_offsets: {}, streamed_sprite_pose_vars: {},
                     video_copies: [], late_pages: [], lists: {}, sprite_runs: [], scene_sets: nil,
                     missed_routine_parts: {}, colors_short_at: nil, sprite_turns: {}, held_sprites: nil, **rest)
        super
      end

      # Where a game keeping more rows than the console's table notes which of them each of the
      # console's rows holds, and where it counts the rows left out (see +held_sprites+).
      HeldSprites = Data.define(:came_from, :left_out_at) do
        # Which of the copy's rows the console's row +slot+ holds, given +half_at+ to read the
        # cartridge's memory with.
        def row_in_copy(slot, half_at) = half_at.call(came_from + (slot * 2))
      end

      # WHERE EACH SCENE'S OWN ROUTINES RUN, for a game whose quick memory is swapped as a scene
      # takes over (see IR::Backends::GBA::SceneQuickMemory). Scenes' sets share one room, so an
      # address there is a different routine depending on which sets are in — and +routines+,
      # which can say one place per routine, gives such a routine the place it sits in the
      # cartridge. +loaded_at+ is the address of the word saying which sets are in, a bit for
      # each set by its number; +scenes+ each scene's set number, and +routines+ each set's
      # routines where they run while it is in.
      SceneSets = Data.define(:loaded_at, :scenes, :routines)

      # The routines and where they run with the sets of +loaded+ in, a bit for each set by its
      # number: those sets' own at their places in the quick memory, every other routine where
      # +routines+ says. Sets that are in together never overlap, so neither do their routines.
      def routines_with_sets(loaded)
        return routines unless scene_sets

        scene_sets.routines.select { |number, _| loaded[number] == 1 }.values.reduce(routines) { |all, set| all.merge(set) }
      end


      # One sprite's turn at a place (see +sprite_turns+): +at+ is the address of the value the
      # scenes' variable held when the table was last written for a change of scene, and the
      # sprite is in the place while that holds +value+. +pose_var+ is where a sprite keeping
      # one frame at a time says which pose it is showing (see +streamed_sprite_pose_vars+), or
      # nil.
      SpriteTurn = Data.define(:at, :value, :name, :offsets, :pose_var)

      # One run of the sprite table drawn in an order the game works out: +order+ is the address
      # of its order, and +homes+ is each of its sprites' own first place and how many places it
      # takes, in the order the order counts them.
      SpriteRun = Data.define(:order, :homes) do
        # Which sprite's own place each place of the run holds now, as { place => own place },
        # given +byte_at+ to read the cartridge's memory with.
        def own_places(byte_at)
          at = homes.map(&:first).min
          (homes.length - 1).downto(0).each_with_object({}) do |turn, found|
            first, pieces = homes.fetch(byte_at.call(order + turn))
            pieces.times do |piece|
              found[at] = first + piece
              at += 1
            end
          end
        end
      end

      # The two routines a program has no name for: the frame's own body, and the one the
      # console jumps into when the display or a timer announces something.
      FRAME_ROUTINE = IR::Backends::GBA::Placement::FRAME_ROUTINE
      IRQ_ROUTINE = IR::Backends::GBA::Placement::IRQ_ROUTINE

      # Whether the frame's own body was kept in the console's quick memory. It is the single
      # most valuable thing to keep there — where nearly all of a frame's time goes — so a
      # guardrail asks, and so does anything reporting on the build.
      def frame_in_quick_memory? = placement ? placement.funcs.include?(FRAME_ROUTINE) : false
    end
  end
end
