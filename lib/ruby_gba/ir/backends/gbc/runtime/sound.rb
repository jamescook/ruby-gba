# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        module Runtime
          # THE SOUND: the console's own voices, told what to play by writing their registers.
          #
          # rg_gbc_sound_writes(table) writes a table the build made (GBC::Sound): each entry a
          # register's place among the console's registers at 0xFF00 and the byte to write there,
          # nought after the last.
          module Sound
            module_function

            def emit(asm)
              asm.label("rg_gbc_sound_writes")
              asm.load_hl_sp(2)
              asm.load(:a, [:hli])
              asm.load(:h, [:hl])
              asm.load(:l, :a)
              asm.label("rg_gbc_sound_writes_next")
              asm.load(:a, [:hli])
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load_high([:c], :a)
              asm.jump_relative("rg_gbc_sound_writes_next")
            end
          end
        end
      end
    end
  end
end
