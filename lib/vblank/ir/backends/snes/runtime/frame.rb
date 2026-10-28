# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE FRAME: waiting for the screen, the buttons, stopping, and going wrong.
          #
          # The console draws the screen a line at a time, 224 of them, and then rests for 38 more
          # lines' worth of time — the VERTICAL BLANK — before it starts again. Only in that rest
          # (or with the screen switched off) can video RAM, the colour memory and the sprite table
          # be written, so a pass of the game loop ends by waiting for it (rt_wait_vblank): the
          # processor sleeps (WAI) until the blank's interrupt (the NMI) wakes it. Then what the
          # pass changed in the picture is copied to the console (Runtime::Picture), and the
          # buttons are taken for the next pass.
          #
          # A pass that takes longer than a frame finds the blank already gone by the time it waits,
          # and waits for the next one: the game slows down rather than tearing.
          #
          # What the run is doing is kept where a reader of the running cartridge can find it
          # (SNES::HeadlessRun): how many passes have ended, which pass the screen is showing,
          # whether the game is waiting at a frame boundary, and whether it has stopped or gone
          # wrong and why. The names and their meanings are the Game Boy Color runtime's, so a
          # reader of either asks the same questions.
          module Frame
            # How the game stands, in STATE.
            RUNNING = 0
            HALTED = 1
            WENT_WRONG = 2

            # What went wrong, in FAULT's first word (see SNES::HeadlessRun for the words).
            INDEX_OUT_OF_RANGE = 1
            LIST_FULL = 2
            LIST_EMPTY = 3
            SAVE_READ_OUTSIDE = 7
            SAVE_WRITE_OUTSIDE = 8
            CELLS_FULL = 11 # more cells of a background changed in one pass than the queue holds

            # FAULT: what went wrong (a word), the list's place (three bytes and a spare), and two
            # numbers that say how (four bytes each).
            FAULT_LIST = 2
            FAULT_FIRST = 6
            FAULT_SECOND = 10
            FAULT_BYTES = 14

            STATE = "rt state" # RUNNING, HALTED or WENT_WRONG
            WAITING = "rt waiting" # 1 while the game waits for its next frame's buttons
            PASSES = "rt passes" # passes of the game loop ended, 32 bits
            SHOWN = "rt shown" # the pass whose picture the console shows, 32 bits
            HELD = "rt held" # the buttons held through the pass, a bit each in IR::Buttons's order
            SEEN = "rt seen"
            PRESSED = "rt pressed"
            FAULT = "rt fault"
            # Set by whoever reads the run when it has the pass it wanted last: the game shows that
            # pass and goes no further.
            HOLD = "rt hold"
            # Set by the same reader when it has taken the last pass it compares one by one: the
            # game's timers do not move on at the boundary after it, as the interpreter's do not.
            LAST_PASS_TAKEN = "rt last pass taken"
            # HOW MANY FRAMES A PASS TOOK (IR::Frames): the interrupt counts every frame (FRAMES, 32
            # bits); where a pass's wait ends, the frames since the last wait ended are what that
            # pass answers for (FRAMES_TAKEN), and held between one and IR::Frames::MOST (STEP_TAKEN).
            FRAMES = "rt frames"
            FRAMES_MARK = "rt frames mark"
            STEP_TAKEN = "rt step"
            FRAMES_TAKEN = "rt frames taken"
            # ...and the real number for each of the last STEPS_KEPT passes, a byte each, by the
            # pass's number less its multiples of STEPS_KEPT, for a reader of the run.
            STEPS = "rt steps"
            STEPS_KEPT = 16
            # The buttons as the interrupt reads them on every frame: held at the last, and every
            # one that went down on any of them since the last wait ended.
            PAD_HELD = "rt pad held"
            PAD_PRESSED = "rt pad pressed"
            # 1 once the interrupt has come since the game began to wait.
            VBLANK = "rt vblank"
            # 1 once the screen is on: before the end of the first pass it is off.
            DISPLAY_ON = "rt display on"

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            # The buttons as the controller hands them over, a bit each in a 16-bit word with B at
            # the top (Console::SNESHardware::JOYPAD_BITS), to the bit each has in IR::Buttons's
            # order. X and Y are read and dropped: no game names them yet.
            BUTTON_BITS = Buttons::NAMES.each_with_index.to_h do |name, bit|
              [1 << Console::SNESHardware::JOYPAD_BITS.fetch(name), 1 << bit]
            end.freeze

            module_function

            def reserve(memory)
              memory.reserve(STATE, 2)
              memory.reserve(WAITING, 2)
              memory.reserve(PASSES, 4)
              memory.reserve(SHOWN, 4)
              memory.reserve(HELD, 2)
              memory.reserve(SEEN, 2)
              memory.reserve(PRESSED, 2)
              memory.reserve(FAULT, FAULT_BYTES)
              memory.reserve(HOLD, 4)
              memory.reserve(LAST_PASS_TAKEN, 4)
              memory.reserve(FRAMES, 4)
              memory.reserve(FRAMES_MARK, 2)
              memory.reserve(STEP_TAKEN, 2)
              memory.reserve(FRAMES_TAKEN, 2)
              memory.reserve(STEPS, STEPS_KEPT)
              memory.reserve(PAD_HELD, 2)
              memory.reserve(PAD_PRESSED, 2)
              memory.reserve(VBLANK, 2)
              memory.reserve(DISPLAY_ON, 2)
            end

            # +pad+ is two words of the direct page, the same on the game's page and the
            # interrupt's, that reading the controller works in.
            def emit(asm, memory, pad:)
              h = Console::SNESHardware
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }

              # The interrupt that says a frame has been drawn. Everything it touches is saved, and it
              # works on a direct page of its own. The frame is counted and the buttons read, so a pass
              # that spans several frames answers for each of them, as the interpreter's does.
              asm.label("rt_vblank_interrupt")
              asm.rep(0x30)
              asm.pha
              asm.phx
              asm.phy
              asm.phb
              asm.phd
              asm.lda(Memory::INTERRUPT_PAGE)
              asm.tcd
              asm.sep(0x20)
              asm.lda(0x80)
              asm.pha
              asm.plb
              asm.lda(asm.abs(h::RDNMI)) # read, so the interrupt is not taken again
              asm.rep(0x20)
              asm.jsr(asm.abs("rt_pad_read"))
              asm.inc(at.call(FRAMES))
              asm.bne("rt_vblank_counted")
              asm.inc(at.call(FRAMES, 2))
              asm.label("rt_vblank_counted")
              asm.lda(1)
              asm.sta(at.call(VBLANK))
              asm.pld
              asm.plb
              asm.ply
              asm.plx
              asm.pla
              asm.rti

              # The end of a pass: count it, move on what keeps time by the frame, say the game is
              # waiting, and wait for the screen. What keeps time by the frame moves on here, before
              # the game is said to be waiting, because that is where the interpreter moves it on: at
              # the frame boundary, before anything is read of the frame (Reference#advance_frame).
              asm.label("rt_wait_vblank")
              asm.inc(at.call(PASSES))
              asm.bne("rt_wait_vblank_counted")
              asm.inc(at.call(PASSES, 2))
              asm.label("rt_wait_vblank_counted")
              asm.jsr(asm.abs("rt_frame_begins_unless_last"))
              asm.jsl(asm.long("rt_picture_prepare"))
              asm.lda(1)
              asm.sta(at.call(WAITING))
              asm.jsr(asm.abs("rt_show_pass"))
              asm.lda(at.call(HOLD))
              asm.beq("rt_wait_vblank_buttons")
              asm.jml(asm.long("rt_stopped"))
              asm.label("rt_wait_vblank_buttons")
              asm.jsr(asm.abs("rt_read_buttons"))
              asm.stz(at.call(WAITING))
              asm.rtl

              # rt_show_pass: what the pass drew, on the screen, and SHOWN saying so. The first time,
              # the screen is still off, so everything set up so far is copied while nothing is drawn,
              # and the screen comes on in the blank after, showing it; after that, the pass's changes
              # are copied in the blank.
              asm.label("rt_show_pass")
              asm.lda(at.call(DISPLAY_ON))
              asm.bne("rt_show_pass_on")
              asm.jsl(asm.long("rt_upload_whole"))
              asm.jsr(asm.abs("rt_sleep_until_vblank"))
              asm.sep(0x20)
              asm.lda(h::FULL_BRIGHTNESS)
              asm.sta(asm.abs(h::INIDISP))
              asm.rep(0x20)
              asm.lda(1)
              asm.sta(at.call(DISPLAY_ON))
              asm.bra("rt_show_pass_shown")
              asm.label("rt_show_pass_on")
              asm.jsr(asm.abs("rt_sleep_until_vblank"))
              asm.jsl(asm.long("rt_upload"))
              asm.label("rt_show_pass_shown")
              asm.lda(at.call(PASSES))
              asm.sta(at.call(SHOWN))
              asm.lda(at.call(PASSES, 2))
              asm.sta(at.call(SHOWN, 2))
              asm.rts

              asm.label("rt_sleep_until_vblank")
              asm.stz(at.call(VBLANK))
              asm.label("rt_sleep_until_vblank_wait")
              asm.wai
              asm.lda(at.call(VBLANK))
              asm.beq("rt_sleep_until_vblank_wait")
              asm.rts

              # What keeps time by the frame, moved on — unless the reader has taken the last pass it
              # compares, after which the interpreter moves nothing on (LAST_PASS_TAKEN).
              asm.label("rt_frame_begins_unless_last")
              asm.lda(at.call(LAST_PASS_TAKEN))
              asm.bne("rt_frame_begins_skipped")
              asm.jsl(asm.long("rt_frame_begins"))
              asm.label("rt_frame_begins_skipped")
              asm.rts

              emit_buttons(asm, memory, pad)
              emit_stopping(asm, memory)
            end

            # BUTTONS. The controller is read by hand, through its serial port: a write of 1 and then
            # 0 to JOYSER0 tells it to take hold of its buttons, and each read of the port hands over
            # the next of them in bit 0, B first, then Y, Select, Start, Up, Down, Left, Right, A, X,
            # L, R and four that are always 0. Read sixteen times and turned in from the right, they
            # come out laid out as the console's own automatic read lays them out (JOYPAD_BITS). That
            # read happens by itself at the start of the blank and takes three lines; reading by hand
            # takes a few dozen instructions and needs nothing waited for.
            def emit_buttons(asm, memory, pad)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              joyser = 0x4016
              # rt_buttons_now: A = the buttons held now, a bit each in IR::Buttons's order.
              asm.label("rt_buttons_now")
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.abs(joyser))
              asm.stz(asm.abs(joyser))
              asm.rep(0x20)
              asm.stz(asm.direct(pad))
              asm.ldx(16)
              asm.label("rt_buttons_now_bit")
              asm.lda(asm.abs(joyser))
              asm.lsr
              asm.rol(asm.direct(pad))
              asm.dex
              asm.bne("rt_buttons_now_bit")
              asm.stz(asm.direct(pad + 2))
              BUTTON_BITS.each do |from, to|
                skip = "rt_buttons_now_not_#{to}"
                asm.lda(asm.direct(pad))
                asm.bit(from)
                asm.beq(skip)
                asm.lda(asm.direct(pad + 2))
                asm.ora(to)
                asm.sta(asm.direct(pad + 2))
                asm.label(skip)
              end
              asm.lda(asm.direct(pad + 2))
              asm.rts

              # In the interrupt, every frame: the buttons held now, and every one that went down
              # since the frame before added to those pressed during the pass.
              asm.label("rt_pad_read")
              asm.jsr(asm.abs("rt_buttons_now"))
              asm.sta(asm.direct(pad))
              asm.lda(at.call(SEEN))
              asm.eor(0xFFFF)
              asm.and_a(asm.direct(pad))
              asm.ora(at.call(PAD_PRESSED))
              asm.sta(at.call(PAD_PRESSED))
              asm.lda(asm.direct(pad))
              asm.sta(at.call(PAD_HELD))
              asm.sta(at.call(SEEN))
              asm.rts

              # Where a pass's wait ends: the buttons for the pass about to start, from every frame
              # the last one took, and how many frames that was. The interrupt is held off while they
              # are taken, so a press it reads cannot fall between the two; one that came while it was
              # held off is taken as soon as it is allowed again.
              asm.label("rt_read_buttons")
              asm.sep(0x20)
              asm.stz(asm.abs(Console::SNESHardware::NMITIMEN))
              asm.rep(0x20)
              asm.lda(at.call(PAD_PRESSED))
              asm.sta(at.call(PRESSED))
              asm.stz(at.call(PAD_PRESSED))
              asm.lda(at.call(PAD_HELD))
              asm.sta(at.call(HELD))
              asm.lda(at.call(FRAMES))
              asm.tay
              asm.sep(0x20)
              asm.lda(Console::SNESHardware::NMI_ON)
              asm.sta(asm.abs(Console::SNESHardware::NMITIMEN))
              asm.rep(0x20)
              asm.tya
              asm.sec
              asm.sbc(at.call(FRAMES_MARK))
              asm.sty(at.call(FRAMES_MARK))
              asm.and_a(0x00FF)
              asm.bne("rt_read_buttons_some")
              asm.lda(1) # a pass is worth at least the frame it ran in
              asm.label("rt_read_buttons_some")
              asm.sta(at.call(FRAMES_TAKEN))
              asm.tay
              asm.lda(at.call(PASSES))
              asm.and_a(STEPS_KEPT - 1)
              asm.tax
              asm.tya
              asm.sep(0x20)
              asm.sta(asm.abs_x(memory[STEPS]))
              asm.rep(0x20)
              asm.cmp(IR::Frames::MOST + 1)
              asm.bcc("rt_read_buttons_step")
              asm.lda(IR::Frames::MOST)
              asm.label("rt_read_buttons_step")
              asm.sta(at.call(STEP_TAKEN))
              asm.rts

              # Held from power-on: down before the first frame boundary, and not yet seen there, so
              # the first boundary still finds them going down — the interpreter's `hold`.
              asm.label("rt_buttons_from_power_on")
              asm.jsr(asm.abs("rt_buttons_now"))
              asm.sta(at.call(HELD))
              asm.rtl
            end

            # STOPPING. rt_halt stops the game where it is: what it drew since its last frame is
            # copied to the console in the next blank (or with the screen switched on, for a game
            # that never got as far as a frame), SHOWN says the end is on the screen, and the
            # processor sleeps from then on. Going wrong is the same, with what went wrong written
            # down first (rt_fault, A = what went wrong, the list and the numbers already in FAULT).
            def emit_stopping(asm, memory)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              asm.label("rt_halt")
              asm.rep(0x30)
              asm.lda(HALTED)
              asm.label("rt_stop_with_state")
              asm.sta(at.call(STATE))
              asm.jsl(asm.long("rt_picture_prepare"))
              asm.jsr(asm.abs("rt_show_pass"))
              asm.lda(END_SHOWN & 0xFFFF)
              asm.sta(at.call(SHOWN))
              asm.sta(at.call(SHOWN, 2))
              asm.label("rt_stopped")
              asm.wai
              asm.bra("rt_stopped")

              asm.label("rt_fault")
              asm.rep(0x30)
              asm.sta(at.call(FAULT))
              asm.lda(WENT_WRONG)
              asm.bra("rt_stop_with_state")
            end
          end
        end
      end
    end
  end
end
