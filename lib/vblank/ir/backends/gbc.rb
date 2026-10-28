# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # Raised when a program cannot be made into a Game Boy Color cartridge: it reaches something
        # the Color cannot do, or something its build does not make yet, or it is too big for the
        # cartridge or its memory. Said to the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

require_relative "gbc/sm83"
require_relative "gbc/linker"
require_relative "gbc/memory"
require_relative "gbc/runtime"
require_relative "gbc/art"
require_relative "gbc/square_colors"
require_relative "gbc/music"
require_relative "gbc/sound_registers"
require_relative "gbc/lowering/picture"
require_relative "gbc/lowering/paint_reach"
require_relative "gbc/lowering/sound"
require_relative "gbc/lowering/tile_runs"
require_relative "gbc/lowering/clock"
require_relative "gbc/lowering"
require_relative "gbc/sound_log"
require_relative "gbc/headless_run"
require_relative "gbc/checked_run"

module VBlank
  module IR
    module Backends
      # The game as a GAME BOY COLOR cartridge: the same program every other backend runs, lowered
      # to the SM83, the Color's 8-bit processor, and laid out in a cartridge with a memory bank
      # controller.
      #
      # HOW IT IS MADE. GBC::Lowering walks the IR and emits SM83 machine code, as the GBA lowering
      # emits ARM, sharing only what the IR itself says with the other lowerings (IR::Reach,
      # IR::Frames, IR::SceneHandover and the rest). The runtime the code calls (runtime/*.rb) is
      # written in SM83 here, in Ruby: the arithmetic of IR::Int32 a byte at a time
      # (Runtime::Int32), the frame and the buttons, the lists, and the console's own picture and
      # sound.
      #
      # What the picture is made of is the Color's, not the Advance's: a background of tiles of
      # four colours, forty sprites, eight lists of colours of each kind. What a game asks for is
      # answered by Console::ColorAnswers — it works, or it is refused, naming the hardware the
      # Color lacks — before anything is lowered.
      #
      # A game is checked by playing the cartridge in the emulator and the program on the
      # interpreter, given the Color's screen, and comparing every variable, list and pixel after
      # every pass of the game loop (GBC::CheckedRun).
      class GBC
        # WHERE A RUNNING CARTRIDGE KEEPS WHAT A READER WANTS, which nothing in its bytes says:
        # every variable by the game's name, every list (its place, its capacity, its slot width),
        # where the runtime keeps how the run stands (Runtime::Frame's names), where every label of
        # the code went (the Linker's places), and where each of the game's routines is — a
        # GameRoutine each — for a profile to say whose time it was without reading a label. And what
        # the sound routines are handed is to the interpreter, for a run to read back what the
        # cartridge played (GBC::SoundLog): what each table of sound writes plays, by its label, the
        # songs' notes (GBC::Music#notes), whether the music follows a level the game sets, and the
        # sound effects' names, by their numbers. And what each of the cartridge's checks of its
        # picture groups asks — a sprite showing a picture whose group is not up (PictureCheck), and
        # groups up together that up_together does not allow (TogetherCheck) — by its number, so a
        # run one stops says what stopped it in the interpreter's words.
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :routines, :sound_tables, :notes,
                             :music_follows_level, :sound_effects, :picture_checks, :together_checks) do
          # THE SPRITES THE GAME PLACED IN ITS LAST PASS, as the interpreter says them
          # (Reference#sprites): who each is, which picture it shows and where, back to front. The
          # runtime keeps them in a table of its own (Runtime::Picture::DRAWN), front-most first as
          # the console draws them, so anything reading a running cartridge asks the same of it.
          # +drawn+ is the program's SpriteNames, which turns the table's numbers into names;
          # +read8+ reads one byte of the running cartridge's memory, given its address.
          def drawn_sprite_rows(drawn, read8)
            at = runtime.fetch(Runtime::Picture::DRAWN)
            little = ->(address, width) { (0...width).sum { |i| read8.call(address + i) << (8 * i) } }
            signed16 = ->(value) { value >= 0x8000 ? value - 0x10000 : value }
            rows = Array.new(read8.call(at)) do |i|
              place = at + 1 + (i * Runtime::Picture::DRAWN_BYTES)
              whose, picture, x, y = [[0, 1], [1, 2], [3, 2], [5, 2]].map { |from, width| little.call(place + from, width) }
              drawn.row(whose - 1, picture, signed16.call(x), signed16.call(y))
            end
            rows.reverse
          end

          # Where the runtime counts the times the game has waited for the screen (32 bits).
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)

          # The game's routine whose code holds the byte at +address+ of bank +bank+, or nil for one
          # that is not the game's (the runtime's, the art, the songs).
          def routine_at(bank, address) = routines.find { |held| held.bank == bank && held.addresses.cover?(address) }&.routine
        end

        # One of the cartridge's checks that a sprite's picture is up (Lowering::Picture
        # #emit_refuse_pictures_not_up): the sprite, by the game's name, the picture groups asked
        # about, the sprite's pictures by pose and the groups holding each, the numbers that name a
        # group, and where the number the game said is kept for each of the groups' slots.
        PictureCheck = Data.define(:sprite, :groups, :poses, :holdings, :group_numbers, :said_at)

        # One of the cartridge's checks that a set's groups up can be up together (Lowering::Picture
        # #emit_refuse_groups_not_together): the picture groups, the numbers that name a group, and
        # where the number the game said is kept for each of their slots.
        TogetherCheck = Data.define(:groups, :group_numbers, :said_at)

        # One routine of the game's in the cartridge: its bank, the addresses its code takes there,
        # and what it is to the author (Lowering#section_routines).
        GameRoutine = Data.define(:bank, :addresses, :routine)

        # +program+ as a cartridge (Cartridge::GBCROM), carrying its Places.
        # A game whose sprites wear more lists of colours than the console holds is built again
        # with the lists borrowing them as it runs (Art::TooManySpriteLists).
        # A game whose backgrounds need more tiles than the console holds at once is built again with
        # each screen bringing its own tiles in (Art::TooManyBackgroundTiles).
        def build(program, title: "RUBYGBA")
          build_lending_if_needed(program, title, tile_rooms: false)
        rescue Art::TooManyBackgroundTiles
          build_lending_if_needed(program, title, tile_rooms: true)
        end

        private

        def build_lending_if_needed(program, title, tile_rooms:)
          build_cartridge(program, title, lends: false, tile_rooms: tile_rooms)
        rescue Art::TooManySpriteLists
          build_cartridge(program, title, lends: true, tile_rooms: tile_rooms)
        end

        def build_cartridge(program, title, lends:, tile_rooms:)
          memory = Memory.new
          lowering = Lowering.new(program, memory: memory, lends_sprite_colors: lends, tile_rooms: tile_rooms)
          # The runtime's places first, so they are in the half of work memory always in view.
          Runtime.reserve(memory, art: lowering.art, effects: lowering.music.effects, together: lowering.groups_up_together?,
                                  bar_rows: lowering.bar_rows, slides: lowering.music.slides?,
                                  wobbles: lowering.music.wobbles?)
          game = lowering.sections
          runs = lowering.run_uploads
          runtime = Runtime.sections(memory, main: Lowering::MAIN, art: lowering.art, frame_begins: lowering.frame_begins,
                                             music_level: lowering.music_level, songs: lowering.music.any?,
                                             music: lowering.music, runs: runs, drawn_palettes: lowering.drawn_palettes,
                                             big_maps: lowering.big_map_places, together: lowering.groups_up_together?,
                                             bar_rows: lowering.bar_rows)
          data = [*lowering.art.sections, *(lowering.music.any? ? [lowering.music.section] : [])]
          linked = Linker.new(runtime + game + data, fixed_from: Console::GBCHardware::HEADER_END,
                                                     clock: lowering.clock?).link
          routines = lowering.section_routines.map do |label, routine|
            placed = linked.sections.fetch(label)
            GameRoutine.new(bank: placed.bank, addresses: placed.address...(placed.address + placed.section.size), routine: routine)
          end
          built = Places.new(variables: lowering.variables, lists: lowering.lists, runtime: runtime_places(memory),
                             source_program: program, code: linked.places, routines: routines,
                             sound_tables: lowering.sound_tables, notes: lowering.music.notes,
                             music_follows_level: !lowering.music_level.nil?,
                             sound_effects: lowering.music.effects.map(&:name), picture_checks: lowering.picture_checks,
                             together_checks: lowering.together_checks)
          save_bytes = SaveLayout.named_by?(program) ? Runtime::Saving::SIZE : 0
          Cartridge::GBCROM.new(linked.banks, title: title, save_bytes: save_bytes, clock: lowering.clock?, built: built)
        end

        # Where the runtime keeps how the run stands (Runtime::Frame's names and the rest).
        def runtime_places(memory) = memory.places.select { |name, _| name.start_with?("rt ") }
      end
    end
  end
end
