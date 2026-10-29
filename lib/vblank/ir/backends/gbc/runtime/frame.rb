# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # THE FRAME: waiting for the screen, the buttons, stopping, and going wrong.
          #
          # The console draws the screen a line at a time, 144 of them, and then rests for ten more
          # lines' worth of time — the VERTICAL BLANK — before it starts again. Only in that rest can
          # the picture be changed without the change showing half way down the screen, so a pass of
          # the game loop ends by waiting for it (rt_wait_vblank): the processor sleeps (HALT) until
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
            SAVE_READ_OUTSIDE = 7
            SAVE_WRITE_OUTSIDE = 8
            PICTURE_NOT_UP = 9 # the numbers: which check stopped it (GBC::Places#picture_checks), and the pose
            GROUPS_NOT_TOGETHER = 10 # the number: which set of picture groups (GBC::Places#together_checks)

            # Where the reader finds each of them: the place in work memory each was given.
            STATE = "rt state" # RUNNING, HALTED or WENT_WRONG
            WAITING = "rt waiting" # 1 while the game waits for its next frame's buttons
            PASSES = "rt passes" # passes of the game loop ended, 32 bits
            SHOWN = "rt shown" # the pass whose picture the console shows, 32 bits
            HELD = "rt held"
            SEEN = "rt seen"
            PRESSED = "rt pressed"
            FAULT = "rt fault" # what went wrong, then the list, then two numbers that say how
            # Set by whoever reads the run (GBC::HeadlessRun) when it has the pass it wanted last:
            # the game then shows that pass and goes no further, so nothing it would do next —
            # writing its save memory above all — happens after the moment the run ended on.
            HOLD = "rt hold"
            # Set by the same reader when it has taken the last of the passes it compares one by
            # one: the boundary after it is where the interpreter stops a run, before it moves
            # anything on, so the game's timers do not move on there either.
            LAST_PASS_TAKEN = "rt last pass taken"
            # HOW MANY FRAMES A PASS TOOK (IR::Frames). The screen's interrupt counts every frame it
            # draws (FRAMES, 32 bits, which a reader of the run reads too), whatever the game is
            # doing; where a pass's wait ends, the frames since the last wait ended are what that
            # pass answers for (STEP_TAKEN), held between one and IR::Frames::MOST.
            FRAMES = "rt frames"
            FRAMES_MARK = "rt frames mark"
            STEP_TAKEN = "rt step"
            FRAMES_TAKEN = "rt frames taken" # the same, not held at the cap: what IR::Frames::COUNT moves on by
            # ...and the real number for each of the last STEPS_KEPT passes, by the pass's number
            # (PASSES) less its multiples of STEPS_KEPT, for a reader of the run: the music and the
            # buttons take every frame, past the cap.
            STEPS = "rt steps"
            STEPS_KEPT = 16
            # The buttons as the interrupt reads them, on every frame: held at the last, and every
            # one that went down on any of them since the last wait ended.
            PAD_HELD = "rt pad held"
            PAD_PRESSED = "rt pad pressed"
            # The frames of music owed: drawn while the game was in the middle of a pass, and played
            # where the pass ends (see rt_vblank_interrupt).
            MUSIC_OWED = "rt music owed"
            # 1 once a sprite placed in this pass was found showing a picture not up (rt_picture_not_up).
            PICTURE_NOT_UP_NOTED = "rt picture not up"
            # rt_groups_together's own: where the record's slots start, how many slots, how many of its
            # lists of groups are left to try (two bytes), the list being tried (where its groups
            # start, how many) and where the next list starts.
            TOGETHER = "rt groups together"
            TOGETHER_SLOTS = 0
            TOGETHER_COUNT = 2
            TOGETHER_LISTS_LEFT = 3
            TOGETHER_LIST = 5
            TOGETHER_LENGTH = 7
            TOGETHER_NEXT = 8
            TOGETHER_BYTES = 10

            # THE FRAMES THE SCREEN WAS OFF FOR, from power-on to the game's first frame, in a game that
            # reads `frames_since_power_on` (#emit_dark_start). The screen's interrupt counts every
            # frame it draws, and a screen that is off draws none; the timer counts on regardless.
            # Its counts come TIMER_COUNTS_A_FRAME to a frame — a frame is a whole number of them —
            # and it interrupts every DARK_COUNTS, which divides that, so DARK_TICKS_A_FRAME of its
            # interrupts are exactly a frame.
            DARK_FRAMES = "rt frames dark" # 16 bits, which a reader of the run reads too
            DARK_TICKS = "rt dark ticks" # the timer's interrupts since the last whole frame
            DARK_IN_MEMORY = "rt dark in memory" # 1 once the count is kept in memory (#emit_dark_to_memory)
            TIMER_COUNTS_A_FRAME = Console.described(:gbc).then { |gbc| gbc.cycles_a_frame / gbc.sample_timer_step }
            DARK_COUNTS = (1..256).select { |counts| (TIMER_COUNTS_A_FRAME % counts).zero? }.max
            DARK_TICKS_A_FRAME = TIMER_COUNTS_A_FRAME / DARK_COUNTS

            module_function

            # Does the game count the frames its screen was off for (#emit_dark_start)?
            def dark?(memory) = memory.reserved?(DARK_FRAMES)

            # +dark+ says the game counts the frames its screen was off for.
            def reserve(memory, together: false, dark: false)
              if dark
                memory.reserve(DARK_FRAMES, 2)
                memory.reserve(DARK_TICKS, 1)
                memory.reserve_quick(DARK_IN_MEMORY, 1)
              end
              memory.reserve(TOGETHER, TOGETHER_BYTES) if together
              memory.reserve(STATE, 1)
              memory.reserve(WAITING, 1)
              memory.reserve(PASSES, 4)
              memory.reserve(SHOWN, 4)
              memory.reserve(HELD, 1)
              memory.reserve(SEEN, 1)
              memory.reserve(PRESSED, 1)
              memory.reserve(FAULT, 11)
              memory.reserve(HOLD, 4)
              memory.reserve(LAST_PASS_TAKEN, 4) # the reader writes four bytes at a time
              memory.reserve(FRAMES, 4)
              memory.reserve(FRAMES_MARK, 1)
              memory.reserve(STEP_TAKEN, 1)
              memory.reserve(FRAMES_TAKEN, 1)
              memory.reserve(STEPS, STEPS_KEPT)
              memory.reserve(PAD_HELD, 1)
              memory.reserve(PAD_PRESSED, 1)
              memory.reserve(MUSIC_OWED, 1)
              memory.reserve(PICTURE_NOT_UP_NOTED, 1)
            end

            # +together+ says the game has picture groups with more than one slot, which
            # rt_groups_together asks of. +count_at+ is where the game keeps IR::Frames::COUNT, in a
            # game that counts the frames its screen was off for.
            def emit(asm, memory, together: false, count_at: nil)
              raise ArgumentError, "a game that counts its dark frames needs count_at:" if dark?(memory) && count_at.nil?

              clips = Clips.any?(memory)
              rumble = Rumble.any?(memory)
              h = Console::GBCHardware
              vblank = memory.quick(1)

              # The interrupt that says a frame has been drawn. The frame is counted, and the buttons
              # read, so a pass that spans several frames answers for each of them, as the
              # interpreter's does (Reference#advance_frame, #read_buttons).
              #
              # THE MUSIC PLAYS A FRAME FOR EVERY FRAME DRAWN (Runtime::Music), but where the pass
              # that spans it ends. The interpreter plays a pass's frames of music after everything
              # the pass did, so a tune named, stopped or turned down half way through a pass that
              # spans three frames is named before all three; played here as they come, the frames
              # before the word would be played without it. So a frame drawn while the game is in
              # the middle of a pass is owed (MUSIC_OWED), and the owed frames are played as the pass
              # ends (rt_wait_vblank) — a game that keeps up is always waiting by then, and owes
              # nothing.
              #
              # A RECORDING PLAYING (Runtime::Clips) WANTS A SAMPLE EVERY FEW HUNDRED CYCLES,
              # and the processor takes no interrupt while it is in one, so the music and the buttons
              # would hold a clip's samples back until they were done, every frame: a buzz at the
              # frame's own rate. So in a game that plays one, the timer's interrupt alone is let in
              # while this one runs, and the switches are put back as it ends.
              asm.label("rt_vblank_interrupt")
              %i[af bc de hl].each { |pair| asm.push(pair) }
              if clips
                asm.load_high(:a, h::IE)
                asm.push(:af)
                asm.load(:a, h::INT_TIMER)
                asm.load_high(h::IE, :a)
                asm.ei
              end
              asm.load(:a, [memory[WAITING]])
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_vblank_music")
              asm.load(:hl, memory[MUSIC_OWED])
              asm.inc([:hl])
              asm.jump_relative("rt_vblank_music_done")
              asm.label("rt_vblank_music")
              asm.call("rt_music_tick")
              asm.call("rt_rumble_tick") if rumble # the motor moves on with the music (Runtime::Rumble)
              asm.label("rt_vblank_music_done")
              asm.call("rt_pad_read")
              asm.load(:hl, memory[FRAMES])
              asm.call("rt_increment32")
              asm.load(:a, 1)
              asm.load_high(vblank, :a)
              if clips
                asm.di
                asm.pop(:af)
                asm.load_high(h::IE, :a)
              end
              %i[hl de bc af].each { |pair| asm.pop(pair) }
              asm.reti

              # The end of a pass: count it, move on what keeps time by the frame, say the game is
              # waiting, and wait for the screen.
              #
              # WHAT KEEPS TIME BY THE FRAME (the game's timers, rt_frame_begins) MOVES ON HERE, in
              # the wait and before the game is said to be waiting, because that is where the
              # interpreter moves it on: at the frame boundary, before anything is read of the frame
              # (Reference#advance_frame). So whoever reads the game while it waits reads it with
              # this boundary's ticks counted.
              #
              # BEFORE THE SCAN that finds what to send, since a tick's handler can draw. A painted
              # screen on a Color is one page, tear-free or not (Console::Description's
              # painted_pages), so what a handler paints at the boundary is in the picture that
              # frame shows, as it is to the interpreter.
              asm.label("rt_wait_vblank")
              asm.load(:hl, memory[PASSES])
              asm.call("rt_increment32")
              asm.xor_a(:a)
              asm.load_high(vblank, :a)
              asm.call("rt_frame_begins_unless_last")
              asm.call("rt_paint_scan")
              # Waiting from here, and the music owed by the frames the pass spanned played first,
              # with the interrupt held off so a frame drawn now is played after them. In a game that
              # plays a recording, only the screen's is held off: a frame behind can owe several, and
              # the timer's samples go on between them, as they do in the screen's interrupt.
              if clips
                asm.load_high(:a, h::IE)
                asm.push(:af)
                asm.load(:a, h::INT_TIMER)
                asm.load_high(h::IE, :a)
              else
                asm.di
              end
              asm.load(:a, 1)
              asm.load([memory[WAITING]], :a)
              asm.label("rt_wait_vblank_owed")
              asm.load(:a, [memory[MUSIC_OWED]])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_wait_vblank_paid")
              asm.dec(:a)
              asm.load([memory[MUSIC_OWED]], :a)
              asm.call("rt_music_tick")
              asm.call("rt_rumble_tick") if rumble
              asm.jump_relative("rt_wait_vblank_owed")
              asm.label("rt_wait_vblank_paid")
              if clips
                asm.pop(:af)
                asm.load_high(h::IE, :a)
              else
                asm.ei
              end
              asm.load_high(:a, h::LCDC)
              asm.bit(7, :a)
              asm.jump_relative(:nz, "rt_wait_vblank_sleep")
              # The screen is still off: this is the first frame. Everything set up so far is
              # copied while nothing is being drawn, and the screen comes on showing it.
              emit_dark_end(asm) if dark?(memory)
              asm.call("rt_upload_whole")
              asm.call("rt_shown_is_passes")
              asm.call("rt_display_on")
              asm.call("rt_sleep_until_vblank")
              emit_add_dark_frames(asm, memory, count_at) if dark?(memory)
              asm.jump_relative("rt_wait_vblank_buttons")
              asm.label("rt_wait_vblank_sleep")
              asm.call("rt_sleep_until_vblank")
              asm.call("rt_upload_whole")
              asm.call("rt_shown_is_passes")
              asm.label("rt_wait_vblank_buttons")
              asm.load(:a, [memory[HOLD]])
              asm.and_a(:a)
              asm.jump(:nz, "rt_stopped")
              asm.call("rt_read_buttons")
              asm.xor_a(:a)
              asm.load([memory[WAITING]], :a)
              asm.ret

              # SLEEPING UNTIL THE BLANK. The processor sleeps until any interrupt, so it sleeps again
              # until the screen's has said a blank began. A pass that ends late can find one begun
              # already, and that one is passed over for the next. Slept through, the next interrupt
              # to wake the game would be — in a game that bends rows — the display's own, as the
              # first line of the frame ends: the blank's copies would run while the screen is drawn,
              # the first rows bent wrong, and an interrupt taken during the sprite table's copy
              # would start the console again (rt_oam_dma_held). Used at once, the game would never be
              # waiting as a frame begins, where the reader of a running cartridge looks for it
              # (GBC::HeadlessRun). Interrupts are held off while the blank is forgotten, so the
              # screen's cannot say one began between that and the sleep; they come back on after
              # the instruction that follows, the sleep itself.
              asm.label("rt_sleep_until_vblank")
              asm.di
              asm.xor_a(:a)
              asm.load_high(vblank, :a)
              asm.ei
              asm.label("rt_sleep_until_vblank_halt")
              asm.halt
              asm.load_high(:a, vblank)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sleep_until_vblank_halt")
              asm.xor_a(:a)
              asm.load_high(vblank, :a)
              asm.ret

              # What keeps time by the frame, moved on — unless the reader has taken the last pass it
              # compares, after which the interpreter moves nothing on (LAST_PASS_TAKEN).
              asm.label("rt_frame_begins_unless_last")
              asm.load(:a, [memory[LAST_PASS_TAKEN]])
              asm.and_a(:a)
              asm.ret(:nz)
              asm.jump("rt_frame_begins")

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

              emit_dark_tick(asm, memory) if dark?(memory)
              emit_increment(asm)
              emit_buttons(asm, memory)
              emit_stopping(asm, memory)
              emit_groups_together(asm, memory) if together
            end

            # COUNTING THE FRAMES THE SCREEN IS OFF FOR STARTS AS THE BOOT DOES (Runtime::Boot#emit),
            # before it clears work memory and quick memory, which take frames of their own and would
            # clear a count kept there. So until they are cleared the count is kept in DE, which
            # nothing the boot runs touches: E the timer's interrupts since the last whole frame, D
            # the frames. The timer is told to interrupt every DARK_COUNTS of its counts, and its
            # interrupt alone is let in.
            def emit_dark_start(asm, memory)
              h = Console::GBCHardware
              asm.xor_a(:a)
              asm.load([memory[DARK_IN_MEMORY]], :a)
              asm.load(:de, 0)
              asm.load(:a, 256 - DARK_COUNTS)
              asm.load_high(h::TMA, :a)
              asm.load_high(h::TIMA, :a)
              asm.load(:a, Clips::TIMER_ON)
              asm.load_high(h::TAC, :a)
              asm.xor_a(:a)
              asm.load_high(h::IF, :a)
              asm.load(:a, h::INT_TIMER)
              asm.load_high(h::IE, :a)
              asm.ei
            end

            # ...and once memory is cleared, the count goes into it (DARK_FRAMES, DARK_TICKS) and is
            # kept there from then on. Interrupts are held off while it moves; the boot lets them in
            # again as it sets them up for the game.
            def emit_dark_to_memory(asm, memory)
              asm.di
              asm.load(:a, :e)
              asm.load([memory[DARK_TICKS]], :a)
              asm.load(:a, :d)
              asm.load([memory[DARK_FRAMES]], :a)
              asm.xor_a(:a)
              asm.load([memory[DARK_FRAMES] + 1], :a)
              asm.inc(:a)
              asm.load([memory[DARK_IN_MEMORY]], :a)
            end

            # The timer's interrupt while the screen is off: one more tick, and one more frame every
            # DARK_TICKS_A_FRAME of them, in DE or in memory (#emit_dark_start).
            def emit_dark_tick(asm, memory)
              asm.label("rt_dark_tick")
              asm.push(:af)
              asm.load(:a, [memory[DARK_IN_MEMORY]])
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_dark_tick_kept")
              asm.inc(:e)
              asm.load(:a, :e)
              asm.cp_a(DARK_TICKS_A_FRAME)
              asm.jump_relative(:nz, "rt_dark_tick_done")
              asm.load(:e, 0)
              asm.inc(:d)
              asm.jump_relative("rt_dark_tick_done")
              asm.label("rt_dark_tick_kept")
              asm.push(:hl)
              asm.load(:hl, memory[DARK_TICKS])
              asm.inc([:hl])
              asm.load(:a, [:hl])
              asm.cp_a(DARK_TICKS_A_FRAME)
              asm.jump_relative(:nz, "rt_dark_tick_kept_done")
              asm.xor_a(:a)
              asm.load([:hl], :a)
              asm.load(:hl, memory[DARK_FRAMES])
              asm.inc([:hl])
              asm.jump_relative(:nz, "rt_dark_tick_kept_done")
              asm.inc(:hl)
              asm.inc([:hl])
              asm.label("rt_dark_tick_kept_done")
              asm.pop(:hl)
              asm.label("rt_dark_tick_done")
              asm.pop(:af)
              asm.reti
            end

            # As the screen comes on for the first frame: the timer stopped, so the frame that follows
            # is the screen's interrupt's to count.
            def emit_dark_end(asm)
              h = Console::GBCHardware
              asm.di
              asm.xor_a(:a)
              asm.load_high(h::TAC, :a)
              asm.load(:a, h::INT_VBLANK)
              asm.load_high(h::IE, :a)
              asm.load_high(:a, h::IF)
              asm.and_a(~h::INT_TIMER & 0xFF)
              asm.load_high(h::IF, :a)
              asm.ei
            end

            # ...and once the first frame boundary has come, the frames it was off for added to the
            # game's count (+count_at+), as setting up that took that long. After the boundary,
            # where the interpreter adds them (Reference#frames_setting_up), so a reader of the run
            # at the boundary finds the count as the interpreter has it there.
            def emit_add_dark_frames(asm, memory, count_at)
              asm.load(:hl, memory[DARK_FRAMES])
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:b, [:hl])
              asm.load(:hl, count_at)
              asm.load(:a, [:hl])
              asm.add_a(:c)
              asm.load([:hli], :a)
              asm.load(:a, [:hl])
              asm.adc_a(:b)
              asm.load([:hli], :a)
              asm.load(:a, [:hl])
              asm.adc_a(0)
              asm.load([:hli], :a)
              asm.load(:a, [:hl])
              asm.adc_a(0)
              asm.load([:hl], :a)
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

              # In the screen's interrupt, every frame: the buttons held now, and every one that went
              # down since the frame before added to those pressed during the pass.
              asm.label("rt_pad_read")
              asm.call("rt_buttons_now")
              asm.load(:b, :a)
              asm.load(:a, [memory[SEEN]])
              asm.cpl
              asm.and_a(:b)
              asm.load(:c, :a)
              asm.load(:a, [memory[PAD_PRESSED]])
              asm.or_a(:c)
              asm.load([memory[PAD_PRESSED]], :a)
              asm.load(:a, :b)
              asm.load([memory[PAD_HELD]], :a)
              asm.load([memory[SEEN]], :a)
              asm.ret

              # Where a pass's wait ends: the buttons for the pass about to start, from every frame the
              # last one took, and how many frames that was. The interrupt is held off while they are
              # taken, so a press it reads cannot fall between the two.
              asm.label("rt_read_buttons")
              asm.di
              asm.load(:a, [memory[PAD_PRESSED]])
              asm.load([memory[PRESSED]], :a)
              asm.xor_a(:a)
              asm.load([memory[PAD_PRESSED]], :a)
              asm.load(:a, [memory[PAD_HELD]])
              asm.load([memory[HELD]], :a)
              asm.load(:a, [memory[FRAMES]])
              asm.ei
              asm.load(:b, :a)
              asm.load(:hl, memory[FRAMES_MARK])
              asm.sub_a([:hl])
              asm.load([:hl], :b)
              asm.jump_relative(:nz, "rt_read_buttons_some")
              asm.inc(:a) # a pass is worth at least the frame it ran in
              asm.label("rt_read_buttons_some")
              asm.load([memory[FRAMES_TAKEN]], :a)
              asm.load(:b, :a)
              asm.load(:a, [memory[PASSES]])
              asm.and_a(STEPS_KEPT - 1)
              asm.add_a(memory[STEPS] & 0xFF)
              asm.load(:l, :a)
              asm.load(:a, memory[STEPS] >> 8)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.load([:hl], :b)
              asm.load(:a, :b)
              asm.cp_a(IR::Frames::MOST + 1)
              asm.jump_relative(:c, "rt_read_buttons_step")
              asm.load(:a, IR::Frames::MOST)
              asm.label("rt_read_buttons_step")
              asm.load([memory[STEP_TAKEN]], :a)
              asm.ret

              # Held from power-on: down before the first frame boundary, and not yet seen there, so
              # the first boundary still finds them going down — the interpreter's `hold`.
              asm.label("rt_buttons_from_power_on")
              asm.call("rt_buttons_now")
              asm.load([memory[HELD]], :a)
              asm.ret

              # rt_held(button) and rt_pressed(button): 1 when it is down (or went down), -1 asking
              # about any of them.
              [["rt_held", HELD], ["rt_pressed", PRESSED]].each do |name, which|
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

            # STOPPING. rt_halt stops the game where it is: what it drew since its last frame is
            # copied to the console in the next blank (or straight away, with the screen switched on,
            # for a game that never got as far as a frame), SHOWN says the end is on the screen, and
            # the processor sleeps from then on. Going wrong is the same, with what went wrong written
            # down first.
            def emit_stopping(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_halt")
              asm.load(:a, HALTED)
              asm.label("rt_stop_with_state")
              asm.load([memory[STATE]], :a)
              asm.call("rt_rumble_stop") if Rumble.any?(memory) # a game that has stopped shakes nothing
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

              # rt_picture_not_up(check, pose): which of the build's checks found a sprite showing a
              # picture whose group is not up (Lowering::Picture#emit_refuse_pictures_not_up), and
              # the pose it shows, noted for the end of the sprites (rt_picture_not_up_stop). The
              # reader of the run finds the sprite, the picture and the groups up by them.
              #
              # NOTED, NOT STOPPED HERE, because the interpreter names the hindmost of the sprites
              # that show a picture not up, and the sprites are placed front-most first: the last
              # noted is the one it names.
              asm.label("rt_picture_not_up")
              asm.load_hl_sp(2)
              asm.load(:b, 8)
              asm.call("rt_take_args")
              asm.load(:hl, memory[FAULT] + 3)
              8.times do |i|
                asm.load_high(:a, Calls.arg(memory, i / 4, 2) + (i % 4))
                asm.load([:hli], :a)
              end
              asm.load(:a, 1)
              asm.load([memory[PICTURE_NOT_UP_NOTED]], :a)
              asm.ret

              # rt_picture_not_up_stop, as a pass's sprites are all placed: the game stops if one
              # of them was noted (rt_picture_not_up).
              asm.label("rt_picture_not_up_stop")
              asm.load(:a, [memory[PICTURE_NOT_UP_NOTED]])
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:a, PICTURE_NOT_UP)
              asm.jump("rt_fault")
            end

            # TWO PICTURE GROUPS UP TOGETHER THAT up_together DOES NOT SAY CAN BE stop the game, as
            # the interpreter stops it (Reference#refuse_groups_not_together!): the console may have
            # put their pictures in the same place in sprite memory (IR::PictureGroupPlaces), so one
            # copied in writes over the other's.
            #
            # rt_groups_together(record, check): the record (Lowering::Picture#emit_refuse_groups_not_together)
            # is the set's slots, the place of each one's group as the sprites want it (a byte,
            # Runtime::PictureGroups::NONE for none), then every list of groups that can be up
            # together, as the lowering says them. The groups up are fine when one list holds every
            # one of them; when none does, the game stops, with +check+, which of the build's sets
            # it was (GBC::Places#together_checks).
            #
            # The record: how many slots, each slot's place (two bytes), how many lists (two bytes),
            # and each list as how many groups and then the groups.
            def emit_groups_together(asm, memory)
              at = ->(offset) { memory[TOGETHER] + offset }
              asm.label("rt_groups_together")
              asm.load_hl_sp(2)
              asm.load(:b, 8)
              asm.call("rt_take_args")
              asm.load_high(:a, Calls.arg(memory, 0, 2))
              asm.load(:l, :a)
              asm.load_high(:a, Calls.arg(memory, 0, 2) + 1)
              asm.load(:h, :a)
              asm.load(:a, [:hli]) # how many slots
              asm.load([at.call(TOGETHER_COUNT)], :a)
              asm.load(:a, :l)
              asm.load([at.call(TOGETHER_SLOTS)], :a)
              asm.load(:a, :h)
              asm.load([at.call(TOGETHER_SLOTS + 1)], :a)
              asm.load(:a, [at.call(TOGETHER_COUNT)]) # past the slots' places, two bytes each
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.add_hl(:de)
              asm.add_hl(:de)
              2.times do |i| # how many lists
                asm.load(:a, [:hli])
                asm.load([at.call(TOGETHER_LISTS_LEFT + i)], :a)
              end

              # The next list, at HL: where its groups start and how many, and where the one after it
              # starts.
              asm.label("rt_groups_together_list")
              asm.load(:a, [at.call(TOGETHER_LISTS_LEFT)])
              asm.load(:e, :a)
              asm.load(:a, [at.call(TOGETHER_LISTS_LEFT + 1)])
              asm.load(:d, :a)
              asm.or_a(:e)
              asm.jump(:z, "rt_groups_together_not")
              asm.dec(:de)
              asm.load(:a, :e)
              asm.load([at.call(TOGETHER_LISTS_LEFT)], :a)
              asm.load(:a, :d)
              asm.load([at.call(TOGETHER_LISTS_LEFT + 1)], :a)
              asm.load(:a, [:hli])
              asm.load([at.call(TOGETHER_LENGTH)], :a)
              asm.load(:a, :l)
              asm.load([at.call(TOGETHER_LIST)], :a)
              asm.load(:a, :h)
              asm.load([at.call(TOGETHER_LIST + 1)], :a)
              asm.load(:a, [at.call(TOGETHER_LENGTH)])
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.add_hl(:de)
              asm.load(:a, :l)
              asm.load([at.call(TOGETHER_NEXT)], :a)
              asm.load(:a, :h)
              asm.load([at.call(TOGETHER_NEXT + 1)], :a)

              # Every slot's group in the list, or wanting none: then the groups up are fine.
              asm.load(:a, [at.call(TOGETHER_SLOTS)])
              asm.load(:l, :a)
              asm.load(:a, [at.call(TOGETHER_SLOTS + 1)])
              asm.load(:h, :a)
              asm.load(:a, [at.call(TOGETHER_COUNT)])
              asm.load(:c, :a)
              asm.label("rt_groups_together_slot")
              asm.load(:a, :c)
              asm.and_a(:a)
              asm.ret(:z)
              asm.dec(:c)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:de]) # the group the slot wants: the low byte of its number
              asm.cp_a(PictureGroups::NONE)
              asm.jump(:z, "rt_groups_together_slot")
              asm.push(:hl)
              asm.push(:bc)
              asm.load(:b, :a)
              asm.load(:a, [at.call(TOGETHER_LIST)])
              asm.load(:l, :a)
              asm.load(:a, [at.call(TOGETHER_LIST + 1)])
              asm.load(:h, :a)
              asm.load(:a, [at.call(TOGETHER_LENGTH)])
              asm.load(:c, :a)
              asm.label("rt_groups_together_member")
              asm.load(:a, :c)
              asm.and_a(:a)
              asm.jump(:z, "rt_groups_together_missing")
              asm.dec(:c)
              asm.load(:a, [:hli])
              asm.cp_a(:b)
              asm.jump(:nz, "rt_groups_together_member")
              asm.pop(:bc)
              asm.pop(:hl)
              asm.jump("rt_groups_together_slot")
              asm.label("rt_groups_together_missing") # not in this list: the next one
              asm.pop(:bc)
              asm.pop(:hl)
              asm.load(:a, [at.call(TOGETHER_NEXT)])
              asm.load(:l, :a)
              asm.load(:a, [at.call(TOGETHER_NEXT + 1)])
              asm.load(:h, :a)
              asm.jump("rt_groups_together_list")

              # No list holds them all.
              asm.label("rt_groups_together_not")
              asm.load(:hl, memory[FAULT] + 3)
              4.times do |i|
                asm.load_high(:a, Calls.arg(memory, 1, 2) + i)
                asm.load([:hli], :a)
              end
              asm.load(:a, GROUPS_NOT_TOGETHER)
              asm.jump("rt_fault")
            end
          end
        end
      end
    end
  end
end
