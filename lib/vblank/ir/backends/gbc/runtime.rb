# frozen_string_literal: true

require_relative "runtime/boot"
require_relative "runtime/int32"
require_relative "runtime/calls"
require_relative "runtime/frame"
require_relative "runtime/lists"
require_relative "runtime/picture"
require_relative "runtime/picture_groups"
require_relative "runtime/paint"
require_relative "runtime/sound"
require_relative "runtime/music"
require_relative "runtime/effects"
require_relative "runtime/clips"
require_relative "runtime/rumble"
require_relative "runtime/kept_sprites"
require_relative "runtime/big_maps"
require_relative "runtime/saving"

module VBlank
  module IR
    module Backends
      class GBC
        # THE RUNTIME every Game Boy Color cartridge carries, in bank 0 where every routine of the
        # game can reach it: from power-on to the game's first line (Boot), the arithmetic (Int32),
        # calls between banks and the runtime's numbers (Calls), the frame and the buttons (Frame),
        # the lists (Lists), the picture (Picture, and Paint for a painted screen) and the sound
        # (Sound).
        #
        # The game's code (GBC::Lowering) calls its routines by their labels (rt_wait_vblank,
        # rt_list_push, rt_held...), with the numbers on the stack (Runtime::Calls).
        module Runtime
          module_function

          # The runtime's own places in work memory, asked for before the game's, so they are in
          # the half always in view (a painted screen puts its banks in the other half while it
          # works). +art+ is what the game's pictures were made into (GBC::Art), +effects+ its sound
          # effects (GBC::Music#effects). +together+ says it has picture groups with more than one
          # slot (Frame#emit_groups_together). +bar_rows+ is how many rows of the window's grid its status
          # bars fill, or nil for a game with none (Picture#emit_bar). +slides+ says a note of its music
          # slides its pitch (GBC::Music#slides?), +wobbles+ that one wobbles (GBC::Music#wobbles?), and
          # +shapes+ that a square note says its shapes (GBC::Music#shapes?). +banked_songs+ says its
          # songs' notes are kept in the cartridge's banks (GBC::Music#banked?), +clips+ that it
          # plays a recording (GBC::Clips#any?), and +dark+ that it counts the frames its screen is
          # off for (Lowering#counts_dark_frames?), and +rumble+ that it runs a cartridge's motor
          # (Lowering#rumbles?). +swells+ says a song's square note swells by itself in a game that
          # moves the music volume (GBC::Music#swells?). +kept_sprites+ says a sprite placed as it was
          # on the pass before is left as it is (Lowering::Picture#keeps_unchanged_sprites?).
          def reserve(memory, art:, effects: [], together: false, bar_rows: nil, slides: false, wobbles: false,
                      shapes: false, swells: false, banked_songs: false, clips: false, dark: false, rumble: false,
                      kept_sprites: false)
            Clips.reserve(memory) if clips
            Rumble.reserve(memory) if rumble
            KeptSprites.reserve(memory) if kept_sprites
            Frame.reserve(memory, together: together, dark: dark)
            Picture.reserve(memory, lends: art.lending, groups: art.groups?, bar_rows: bar_rows, rooms: art.rooms.any?)
            BigMaps.reserve(memory)
            Paint.reserve(memory, painting: art.painting?)
            Music.reserve(memory, effects: effects, slides: slides, wobbles: wobbles, shapes: shapes, swells: swells,
                                  banked: banked_songs)
          end

          # The runtime's sections: the processor's entry points, and everything else in one.
          # +main+ is the label of the game's main routine, called in its own bank; +art+ is what its
          # pictures were made into (GBC::Art), which the runtime puts in the console at power-on;
          # +music_level+ is where the game keeps how loud its music is (nil for at full), +songs+
          # whether it has any songs at all, +music+ its songs and sound effects (GBC::Music, nil for
          # none), and +frame_begins+ the label of the game's routine run at each frame boundary
          # (its timers moving on, GBC::Timers), or nil for none. +runs+ are the tiles it paints from
          # lists (Lowering::TileRuns#run_uploads), and +drawn_palettes+ where it keeps the colours its
          # pictures are drawn in now, for a game that draws a background in others (nil for none).
          # +big_maps+ is where a game with a map bigger than the grid keeps its copy of the grid and
          # the list of cells for the blank (Runtime::BigMaps), or nil. +together+ is as for #reserve.
          # +clips+ is the game's recordings (GBC::Clips), or nil for a game that plays none.
          # +count_at+ is where a game that counts the frames its screen is off for keeps
          # IR::Frames::COUNT (Frame#emit_add_dark_frames). +banked_colors+ says its backgrounds' colour
          # tables are kept in banks (Runtime::Picture#emit_background_colors_far).
          def sections(memory, main:, art:, music_level: nil, songs: false, music: nil, frame_begins: nil, runs: [],
                       drawn_palettes: nil, big_maps: nil, together: false, bar_rows: nil, clips: nil, count_at: nil,
                       banked_colors: false)
            # A game whose songs are kept in banks notes every bank the runtime puts in view, for the
            # music player to put back (SM83#select_rom_bank, Music::BANK_NOTED); one that plays a
            # recording writes down every bank put in view, for the timer to put back (Runtime::Clips).
            noted = memory[Music::BANK_NOTED] if Music.banked?(memory)
            shown = memory[Clips::SHOWN] if Clips.any?(memory)
            asm = SM83.new("runtime", home: :fixed, bank_noted_at: noted, bank_shown_at: shown)
            Boot.emit(asm, main: "rt_main", clips: !shown.nil?, backdrop: art.backdrop_at_power_on, memory: memory)
            Boot.emit_display_off(asm)
            Boot.emit_clear(asm)
            Int32.emit(asm, memory)
            Calls.emit(asm, memory)
            Frame.emit(asm, memory, together: together, count_at: count_at)
            Lists.emit(asm, memory)
            Picture.emit(asm, memory, sprite_tiles: art.sprite_tiles.length, background_tiles: art.background_tiles.length,
                                      runs: runs, drawn_palettes: drawn_palettes, lends: art.lending,
                                      palettes_in_use: art.palettes_in_use, groups: art.groups?, bar_rows: bar_rows,
                                      rooms: art.rooms.any?, room_colors: art.room_colors?, lent_families: art.lent_families?,
                                      backdrop: art.first_screen_backdrop, banked_colors: banked_colors,
                                      first_kept_list: art.first_kept_list, tall_pieces: art.tall_pieces?)
            BigMaps.emit(asm, memory, buffer: big_maps&.first, staged: big_maps&.last)
            Paint.emit(asm, memory, painting: art.painting?, map_count: art.square_maps.length, bar: !bar_rows.nil?)
            Sound.emit(asm, memory)
            Music.emit(asm, memory, level: music_level, songs: songs, effects: music&.effects || [],
                                    by_rank: music&.effects_by_rank || [], fades: music&.fades? || false,
                                    slides: music&.slides? || false, pans: music&.pans? || false)
            Saving.emit(asm, memory)
            Clips.emit(asm, memory, counts: clips.timer_counts) if shown
            Rumble.emit(asm, memory) if Rumble.any?(memory)
            KeptSprites.emit(asm, memory, lends: art.lends?) if KeptSprites.any?(memory)
            emit_start(asm)
            emit_main(asm, main)
            emit_frame_begins(asm, frame_begins)
            [*Boot.vector_sections(clips: !shown.nil?, dark: Frame.dark?(memory)), asm.section, *Paint.table_sections(maps: art.square_maps)]
          end

          # What a game needs before its first line: its variables that do not start at nought,
          # its lists' headers, and the buttons held from power-on.
          def emit_start(asm)
            asm.label("rt_start")
            asm.load(:hl, "game_starts")
            asm.label("rt_start_next")
            asm.load(:a, [:hli])
            asm.load(:e, :a)
            asm.load(:a, [:hli])
            asm.load(:d, :a)
            asm.or_a(:e)
            asm.jump_relative(:z, "rt_start_lists")
            4.times do
              asm.load(:a, [:hli])
              asm.load([:de], :a)
              asm.inc(:de)
            end
            asm.jump_relative("rt_start_next")
            asm.label("rt_start_lists")
            asm.call("rt_lists_start")
            asm.call("rt_picture_start")
            asm.call("rt_paint_start")
            asm.jump("rt_buttons_from_power_on")
          end

          # The game's main routine, in whichever bank it went to.
          def emit_main(asm, main)
            asm.label("rt_main")
            asm.call("rt_far_call")
            asm.data_bank_of(main)
            asm.data_words(main)
            asm.ret
          end

          # What moves on at each frame boundary, once the buttons are read (Reference#advance_frame's
          # middle): the game's timers, through its routine +routine+ in whichever bank it went to,
          # or nothing for a game with none. The music moves on from the frame's interrupt instead.
          def emit_frame_begins(asm, routine)
            asm.label("rt_frame_begins")
            if routine
              asm.call("rt_far_call")
              asm.data_bank_of(routine)
              asm.data_words(routine)
            end
            asm.ret
          end
        end
      end
    end
  end
end
