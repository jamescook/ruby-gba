# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        module Runtime
          # THE FRAME: waiting for the screen, the buttons, stopping, and going wrong.
          #
          # The console draws the screen a line at a time, 144 of them, and then rests for ten more
          # lines' worth of time — the VERTICAL BLANK — before it starts again. Only in that rest can
          # the picture be changed without the change showing half way down the screen, so a pass of
          # the game loop ends by waiting for it (rg_wait_vblank): the processor sleeps (HALT) until
          # the blank's interrupt wakes it. Then what the pass changed in the picture is copied to
          # the console (Runtime::Picture#upload, the sprite table above all), and the buttons are
          # read for the next pass.
          #
          # A pass that takes longer than a frame finds the blank already gone by the time it waits,
          # and waits for the next one: the game slows down rather than tearing.
          #
          # What the run is doing is kept where a reader of the running cartridge can find it
          # (GBC::HeadlessRun): how many passes have ended, which pass the screen is showing, whether
          # the game is waiting at a frame boundary, and whether it has stopped or gone wrong and why.
          module Frame
            # How the game stands, in State's first byte.
            RUNNING = 0
            HALTED = 1
            WENT_WRONG = 2

            # What went wrong, in Fault's first byte (see GBC::HeadlessRun for the words).
            INDEX_OUT_OF_RANGE = 1
            LIST_FULL = 2
            LIST_EMPTY = 3
            COPY_TOO_LONG = 4
            COPY_PAST_TABLE = 5
            PICTURE_NOT_THERE = 6

            # Where the reader finds each of them: the place in work memory each was given.
            STATE = "rt state" # RUNNING, HALTED or WENT_WRONG
            WAITING = "rt waiting" # 1 while the game waits for its next frame's buttons
            PASSES = "rt passes" # passes of the game loop ended, 32 bits
            SHOWN = "rt shown" # the pass whose picture the console shows, 32 bits
            HELD = "rt held"
            SEEN = "rt seen"
            PRESSED = "rt pressed"
            FAULT = "rt fault" # what went wrong, then the list, then two numbers that say how

            module_function

            def reserve(memory)
              memory.reserve(STATE, 1)
              memory.reserve(WAITING, 1)
              memory.reserve(PASSES, 4)
              memory.reserve(SHOWN, 4)
              memory.reserve(HELD, 1)
              memory.reserve(SEEN, 1)
              memory.reserve(PRESSED, 1)
              memory.reserve(FAULT, 11)
            end

            def emit(asm, memory)
              h = Console::GBCHardware
              vblank = memory.quick(1)

              # The interrupt that says a frame has been drawn.
              asm.label("rt_vblank_interrupt")
              asm.push(:af)
              asm.load(:a, 1)
              asm.load_high(vblank, :a)
              asm.pop(:af)
              asm.reti

              # The end of a pass: count it, say the game is waiting, and wait for the screen.
              asm.label("rg_wait_vblank")
              asm.load(:hl, memory[PASSES])
              asm.call("rt_increment32")
              asm.load(:a, 1)
              asm.load([memory[WAITING]], :a)
              asm.xor_a(:a)
              asm.load_high(vblank, :a)
              asm.call("rt_paint_scan")
              asm.load_high(:a, h::LCDC)
              asm.bit(7, :a)
              asm.jump_relative(:nz, "rg_wait_vblank_sleep")
              # The screen is still off: this is the first frame. Everything set up so far is
              # copied while nothing is being drawn, and the screen comes on showing it.
              asm.call("rt_upload_whole")
              asm.call("rt_shown_is_passes")
              asm.call("rt_display_on")
              asm.call("rt_sleep_until_vblank")
              asm.jump_relative("rg_wait_vblank_buttons")
              asm.label("rg_wait_vblank_sleep")
              asm.call("rt_sleep_until_vblank")
              asm.call("rt_upload_whole")
              asm.call("rt_shown_is_passes")
              asm.label("rg_wait_vblank_buttons")
              asm.call("rt_read_buttons")
              asm.call("rt_frame_begins")
              asm.xor_a(:a)
              asm.load([memory[WAITING]], :a)
              asm.ret

              asm.label("rt_sleep_until_vblank")
              asm.halt
              asm.load_high(:a, vblank)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sleep_until_vblank")
              asm.xor_a(:a)
              asm.load_high(vblank, :a)
              asm.ret

              asm.label("rt_shown_is_passes")
              asm.load(:hl, memory[PASSES])
              asm.load(:de, memory[SHOWN])
              4.times do
                asm.load(:a, [:hli])
                asm.load([:de], :a)
                asm.inc(:de)
              end
              asm.ret

              # The screen on, with the switches the picture wants.
              asm.label("rt_display_on")
              asm.load(:a, [memory[Picture::LCDC_WANTED]])
              asm.or_a(h::LCDC_ON)
              asm.load_high(h::LCDC, :a)
              asm.ret

              emit_increment(asm)
              emit_buttons(asm, memory)
              emit_stopping(asm, memory)
            end

            # The 32-bit number at HL, one more: each byte goes round to nought only when the one
            # below it has.
            def emit_increment(asm)
              asm.label("rt_increment32")
              3.times do
                asm.inc([:hl])
                asm.ret(:nz)
                asm.inc(:hl)
              end
              asm.inc([:hl])
              asm.ret
            end

            # BUTTONS. The console's button register reads four at a time: the directions, or A, B,
            # Select and Start, whichever half is asked for, a bit each and 0 for held. They are
            # read into one byte, a bit each in IR::Buttons's order (A, B, Select, Start, then
            # right, left, up, down), and a press is a button held now and not at the frame before.
            def emit_buttons(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_buttons_now") # A = the buttons held now
              asm.load(:a, 0x20) # the directions
              asm.load_high(h::P1, :a)
              2.times { asm.load_high(:a, h::P1) }
              asm.cpl
              asm.and_a(0x0F)
              asm.swap(:a)
              asm.load(:b, :a)
              asm.load(:a, 0x10) # A, B, Select, Start
              asm.load_high(h::P1, :a)
              6.times { asm.load_high(:a, h::P1) } # the buttons' lines take a moment to settle
              asm.cpl
              asm.and_a(0x0F)
              asm.or_a(:b)
              asm.load(:b, :a)
              asm.load(:a, 0x30)
              asm.load_high(h::P1, :a)
              asm.load(:a, :b)
              asm.ret

              asm.label("rt_read_buttons")
              asm.call("rt_buttons_now")
              asm.load(:b, :a)
              asm.load(:a, [memory[SEEN]])
              asm.cpl
              asm.and_a(:b)
              asm.load([memory[PRESSED]], :a)
              asm.load(:a, :b)
              asm.load([memory[HELD]], :a)
              asm.load([memory[SEEN]], :a)
              asm.ret

              # Held from power-on: down before the first frame boundary, and not yet seen there, so
              # the first boundary still finds them going down — the interpreter's `hold`.
              asm.label("rt_buttons_from_power_on")
              asm.call("rt_buttons_now")
              asm.load([memory[HELD]], :a)
              asm.ret

              # rg_held(button) and rg_pressed(button): 1 when it is down (or went down), -1 asking
              # about any of them.
              [["rg_held", HELD], ["rg_pressed", PRESSED]].each do |name, which|
                asm.label(name)
                asm.load_hl_sp(2)
                asm.load(:a, [memory[which]])
                asm.load(:d, :a)
                asm.load(:a, [:hl])
                asm.bit(7, :a)
                asm.jump_relative(:nz, "#{name}_any")
                asm.load(:e, :a)
                asm.load(:a, :d)
                asm.inc(:e)
                asm.label("#{name}_shift")
                asm.dec(:e)
                asm.jump_relative(:z, "#{name}_bit")
                asm.srl(:a)
                asm.jump_relative("#{name}_shift")
                asm.label("#{name}_bit")
                asm.and_a(1)
                asm.jump("rt_bool_of_nz")
                asm.label("#{name}_any")
                asm.load(:a, :d)
                asm.and_a(:a)
                asm.jump("rt_bool_of_nz")
              end
            end

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            # STOPPING. rg_halt stops the game where it is: what it drew since its last frame is
            # copied to the console in the next blank (or straight away, with the screen switched on,
            # for a game that never got as far as a frame), SHOWN says the end is on the screen, and
            # the processor sleeps from then on. Going wrong is the same, with what went wrong written
            # down first.
            def emit_stopping(asm, memory)
              h = Console::GBCHardware
              asm.label("rg_halt")
              asm.load(:a, HALTED)
              asm.label("rt_stop_with_state")
              asm.load([memory[STATE]], :a)
              asm.call("rt_paint_scan")
              asm.load_high(:a, h::LCDC)
              asm.bit(7, :a)
              asm.jump_relative(:nz, "rt_stop_on_screen")
              asm.call("rt_upload_whole")
              asm.call("rt_display_on")
              asm.jump_relative("rt_stop_shown")
              asm.label("rt_stop_on_screen")
              asm.call("rt_sleep_until_vblank")
              asm.call("rt_upload_whole")
              asm.label("rt_stop_shown")
              asm.load(:hl, memory[SHOWN])
              asm.load(:a, 0xFF)
              4.times { asm.load([:hli], :a) }
              asm.label("rt_stopped")
              asm.halt
              asm.jump_relative("rt_stopped")

              # rt_fault: A = what went wrong, and the list and the two numbers already in FAULT.
              asm.label("rt_fault")
              asm.load([memory[FAULT]], :a)
              asm.load(:a, WENT_WRONG)
              asm.jump("rt_stop_with_state")
            end
          end
        end
      end
    end
  end
end
