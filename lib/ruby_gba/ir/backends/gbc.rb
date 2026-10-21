# frozen_string_literal: true

require_relative "gbc/sm83"
require_relative "gbc/linker"
require_relative "gbc/memory"
require_relative "gbc/runtime"
require_relative "gbc/art"
require_relative "gbc/picture"
require_relative "gbc/sound"
require_relative "gbc/music"
require_relative "gbc/compiler"
require_relative "gbc/lowering"
require_relative "gbc/headless_run"
require_relative "gbc/checked_run"

module RubyGBA
  module IR
    module Backends
      # The game as a GAME BOY COLOR cartridge: the same program every other backend runs, lowered
      # to the SM83, the Color's 8-bit processor, and laid out in a cartridge with a memory bank
      # controller.
      #
      # HOW IT IS MADE. The native lowering already says a program as a small tree of statements
      # and calls into a runtime, with no operator anywhere on a game's number (see the comment
      # atop Native); GBC::Lowering builds that same tree, and GBC::Compiler turns it into SM83
      # machine code rather than text. The runtime the calls go to (runtime/*.rb) is written in
      # SM83 here, in Ruby, the way the GBA lowering writes its ARM: the arithmetic of IR::Int32 a
      # byte at a time (Runtime::Int32), the frame and the buttons, the lists, and the console's
      # own picture and sound.
      #
      # What the picture is made of is the Color's, not the Advance's: a background of tiles of
      # four colours, forty sprites, eight lists of colours of each kind. What a game asks for that
      # a Color does not have is answered by Console::GBCFeatures — it works, it degrades with a
      # warning, or it is refused — before anything is lowered.
      #
      # A game is checked by playing the cartridge in the emulator and the program on the
      # interpreter, given the Color's screen, and comparing every variable, list and pixel after
      # every pass of the game loop (GBC::CheckedRun).
      class GBC
        # Raised when a program cannot be made into a Game Boy Color cartridge.
        LoweringError = Native::LoweringError

        # WHERE A RUNNING CARTRIDGE KEEPS WHAT A READER WANTS, which nothing in its bytes says:
        # every variable by the game's name, every list (its place, its capacity, its slot width),
        # where the runtime keeps how the run stands (Runtime::Frame's names), and where every
        # label of the code went (the Linker's places), for a profile to say whose time it was.
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code) do
          # THE SPRITES THE GAME PLACED IN ITS LAST PASS, as the interpreter says them
          # (Reference#sprites): who each is, which picture it shows and where, back to front. The
          # runtime keeps them in a table of its own (Runtime::Picture::DRAWN), front-most first as
          # the console draws them, so anything reading a running cartridge asks the same of it.
          # +drawn+ is a Native::DrawnSprites of the program, which turns the table's numbers into
          # names; +read8+ reads one byte of the running cartridge's memory, given its address.
          def drawn_sprite_rows(drawn, read8)
            at = runtime.fetch(Runtime::Picture::DRAWN)
            little = ->(address, width) { (0...width).sum { |i| read8.call(address + i) << (8 * i) } }
            signed16 = ->(value) { value >= 0x8000 ? value - 0x10000 : value }
            rows = Array.new(read8.call(at)) do |i|
              place = at + 1 + (i * Runtime::Picture::DRAWN_BYTES)
              whose, picture, x, y = [[0, 1], [1, 2], [3, 2], [5, 2]].map { |from, width| little.call(place + from, width) }
              drawn.row_from("sprite #{whose - 1} #{picture} #{signed16.call(x)} #{signed16.call(y)}")
            end
            rows.reverse
          end

          # Where the runtime counts the times the game has waited for the screen (32 bits).
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)
        end

        # +program+ as a cartridge (Cartridge::GBCROM), carrying its Places.
        def build(program, title: "RUBYGBA")
          lowering = Lowering.new(program, title: title)
          statements = lowering.top_level
          memory = Memory.new
          # The runtime's places first, so they are in the half of work memory always in view.
          Runtime.reserve(memory, art: lowering.art)
          compiled = Compiler.new(memory: memory).compile(statements)
          level = lowering.music_level_name&.then { |text| compiled.globals.fetch(text) }
          runtime = Runtime.sections(memory, main: "game_#{lowering.main_routine}", art: lowering.art,
                                             music_level: level, songs: lowering.music.any?)
          data = [*lowering.art.sections, *(lowering.music.any? ? [lowering.music.section] : [])]
          linked = Linker.new(runtime + compiled.sections + data, fixed_from: Console::GBCHardware::HEADER_END).link
          save_bytes = Native::Saving.named_by?(program) ? Runtime::Saving::SIZE : 0
          Cartridge::GBCROM.new(linked.banks, title: title, save_bytes: save_bytes,
                                              built: places(lowering, compiled, memory, program, linked))
        end

        private

        def places(lowering, compiled, memory, program, linked)
          variables = lowering.variable_names_in_statements.transform_values { |text| compiled.globals.fetch(text) }
          lists = lowering.list_names_in_statements.transform_values { |text| compiled.lists.fetch(text) }
          runtime = memory.places.select { |name, _| name.start_with?("rt ") }
          Places.new(variables: variables, lists: lists, runtime: runtime, source_program: program, code: linked.places)
        end
      end
    end
  end
end
