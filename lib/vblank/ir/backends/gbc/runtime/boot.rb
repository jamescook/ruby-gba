# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # FROM POWER-ON TO THE GAME'S FIRST LINE.
          #
          # The console's own start-up program checks the cartridge's logo and header and then jumps
          # to 0x0100, where the header's first four bytes jump on to here. From here the console is
          # ours, and it is in no known state, so everything is set up before the game runs:
          #
          # - the processor is put in DOUBLE SPEED, which only a Color has: twice the instructions
          #   in every frame, and a game's 32-bit arithmetic needs them;
          # - the display is switched off, which is the only time video memory can be written
          #   freely, and stays off — showing white — until the game's first frame is ready, as the
          #   interpreter holds its picture off until then;
          # - work memory, the processor's quick memory and video memory are cleared, so every
          #   variable starts at nought, as the interpreter's do;
          # - the little routine that fills the sprite table is copied into quick memory, since
          #   while that copy runs the processor can read nothing else;
          # - sound is switched on, and the vertical-blank interrupt, which says a frame has been
          #   drawn, is switched on.
          #
          # Then the game's main routine is called. A game whose routine ends stops there.
          module Boot
            module_function

            # The processor's fixed entry points: the eight one-byte calls (unused, so each goes
            # nowhere harmful), the five interrupts, and the jump from the header. The timer's
            # plays a sample of a recording in a game that plays one (+clips+, Runtime::Clips).
            def vector_sections(clips: false)
              vectors = SM83.new("vectors", home: 0)
              8.times { vectors.bytes_of([0xC9] + ([0x00] * 7)) } # each RST: a return
              vectors.label("rt_vblank_vector") # 0x40
              vectors.jump("rt_vblank_interrupt")
              vectors.bytes_of([0x00] * (0x48 - vectors.here))
              vectors.jump("rt_hblank_interrupt") # 0x48: the display's, raised as a line ends
              [0x50, 0x58, 0x60].each do |at|
                vectors.bytes_of(Array.new(at - vectors.here, 0x00))
                next vectors.jump("rt_clip_tick") if clips && at == Console::GBCHardware::TIMER_VECTOR

                vectors.reti
              end
              entry = SM83.new("entry", home: Console::GBCHardware::ENTRY)
              entry.nop
              entry.jump("rt_boot")
              [vectors.section, entry.section]
            end

            # The start-up routine, ending in a call to +main+. In a game that plays a recording
            # (+clips+), the timer is stopped and its interrupt switched on, for a clip to start.
            def emit(asm, main:, clips: false)
              h = Console::GBCHardware
              asm.label("rt_boot")
              asm.di
              asm.load(:sp, Memory::STACK_TOP)
              # Double speed: ask for it, then STOP, which is when the processor changes speed.
              asm.load_high(:a, h::KEY1)
              asm.bit(7, :a)
              asm.jump_relative(:nz, "rt_boot_fast")
              asm.load(:a, 0x30)
              asm.load_high(h::P1, :a)
              asm.load(:a, 0x01)
              asm.load_high(h::KEY1, :a)
              asm.stop
              asm.label("rt_boot_fast")
              asm.call("rt_display_off")
              asm.load(:a, 1)
              asm.load_high(h::SVBK, :a)
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              # Work memory: the always-there half and bank 1, whole. The stack is in it, so this
              # one is cleared here and not by a call, whose return address it would clear.
              asm.load(:hl, h::WRAM0)
              asm.xor_a(:a)
              asm.label("rt_boot_clear_work")
              asm.load([:hli], :a)
              asm.load(:b, :a)
              asm.load(:a, :h)
              asm.cp_a(h::WRAMX >> 8 | 0x10) # 0xE0: past bank 1
              asm.load(:a, :b)
              asm.jump_relative(:nz, "rt_boot_clear_work")
              asm.load(:hl, Memory::QUICK_FIRST)
              asm.load(:bc, Memory::QUICK_END - Memory::QUICK_FIRST)
              asm.call("rt_clear")
              # Video memory, both banks.
              [1, 0].each do |bank|
                asm.load(:a, bank)
                asm.load_high(h::VBK, :a)
                asm.load(:hl, h::VRAM)
                asm.load(:bc, h::VRAM_SIZE)
                asm.call("rt_clear")
              end
              copy_oam_dma(asm)
              # Every colour of every list black, which is the interpreter's empty screen.
              [h::BCPS, h::OCPS].each do |select|
                asm.load(:a, 0x80) # from the first, moving on after each byte
                asm.load_high(select, :a)
                asm.xor_a(:a)
                asm.load(:b, 64)
                asm.label("rt_boot_black_#{select}")
                asm.load_high(select + 1, :a)
                asm.dec(:b)
                asm.jump_relative(:nz, "rt_boot_black_#{select}")
              end
              asm.load(:a, 1)
              asm.load_high(Memory::CURRENT_BANK, :a)
              asm.select_rom_bank
              # Sound on, both speakers at full, every voice to both.
              asm.load(:a, 0x80)
              asm.load_high(h::NR52, :a)
              asm.load(:a, 0x77)
              asm.load_high(h::NR50, :a)
              asm.load(:a, 0xFF)
              asm.load_high(h::NR51, :a)
              asm.xor_a(:a)
              asm.load_high(h::TAC, :a) if clips
              asm.load_high(h::IF, :a)
              asm.load(:a, clips ? h::INT_VBLANK | h::INT_TIMER : h::INT_VBLANK)
              asm.load_high(h::IE, :a)
              asm.ei
              asm.call("rt_start")
              asm.call(main)
              asm.jump("rt_halt") # a game whose main routine ends has stopped, as one that halts has
            end

            # The display off, which is only allowed during a vertical blank: wait for one first.
            def emit_display_off(asm)
              h = Console::GBCHardware
              asm.label("rt_display_off")
              asm.load_high(:a, h::LCDC)
              asm.bit(7, :a)
              asm.ret(:z)
              asm.label("rt_display_off_wait")
              asm.load_high(:a, h::LY)
              asm.cp_a(144)
              asm.jump_relative(:c, "rt_display_off_wait")
              asm.xor_a(:a)
              asm.load_high(h::LCDC, :a)
              asm.ret
            end

            # The routine that fills the sprite table from its copy in work memory, put in quick
            # memory: write the copy's page to the DMA register, then wait the 160 cycles the copy
            # takes, during which only quick memory can be read.
            OAM_DMA_ROUTINE = [0x3E, Memory::SHADOW_OAM >> 8, # ld a, high(SHADOW_OAM)
                               0xE0, Console::GBCHardware::DMA & 0xFF, # ldh (DMA), a
                               0x3E, 40, # ld a, 40
                               0x3D, # dec a
                               0x20, 0xFD, # jr nz, -3
                               0xC9].freeze # ret

            def copy_oam_dma(asm)
              asm.load(:hl, Memory::OAM_DMA)
              OAM_DMA_ROUTINE.each do |byte|
                asm.load(:a, byte)
                asm.load([:hli], :a)
              end
            end

            # HL..HL+BC = 0.
            def emit_clear(asm)
              asm.label("rt_clear")
              asm.inc(:b) # so the count runs down in two loops: C then B, as a pair would not
              asm.inc(:c)
              asm.xor_a(:a)
              asm.jump_relative("rt_clear_next")
              asm.label("rt_clear_loop")
              asm.load([:hli], :a)
              asm.label("rt_clear_next")
              asm.dec(:c)
              asm.jump_relative(:nz, "rt_clear_loop")
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_clear_loop")
              asm.ret
            end
          end
        end
      end
    end
  end
end
