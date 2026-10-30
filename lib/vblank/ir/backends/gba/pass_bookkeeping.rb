# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # WHERE A CHECKED BUILD KEEPS HOW THE RUN STANDS, by the names every console's reader asks
        # for them by (Backends::CartridgeHeadlessRun): how many passes have ended, which one the
        # screen shows, whether the game waits at the end of one, how it stands and what went wrong.
        # The Color's runtime keeps these in every cartridge (GBC::Runtime::Frame); the Advance's
        # keeps them only in a cartridge built to be checked against the interpreter
        # (GBA.new(checked: true)), so a cartridge built for a player is the bytes it always was.
        module Runtime
          module Frame
            # What went wrong, by the number every console's runtime keeps it by.
            include CartridgeFaults

            # How the game stands, in STATE.
            RUNNING = 0
            HALTED = 1
            WENT_WRONG = 2

            STATE = "rt state"
            WAITING = "rt waiting" # 1 while the game waits for the screen at the end of a pass
            PASSES = "rt passes" # passes of the game loop ended
            SHOWN = "rt shown" # the pass whose picture the screen shows
            HOLD = "rt hold" # set by the reader: show this pass and go no further
            LAST_PASS_TAKEN = "rt last pass taken" # set by the reader after the last pass it compares
            FRAMES = "rt frames" # every frame the screen has drawn (IR::Frames::COUNT)
            # How many frames each of the last STEPS_KEPT passes really took, a byte each, by the
            # pass's number less its multiples of STEPS_KEPT.
            STEPS = "rt steps"
            STEPS_KEPT = 16
            # What went wrong, a word each: the number, the place of the list it was about, and the
            # two numbers that say how (CartridgeHeadlessRun#fault_message).
            FAULT = "rt fault"
            FAULT_BYTES = 16

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            # The game's variables each of the words above is kept in.
            WORDS = { STATE => :"rt state", WAITING => :"rt waiting", PASSES => :"rt passes",
                      SHOWN => :"rt shown", HOLD => :"rt hold", LAST_PASS_TAKEN => :"rt last pass taken" }.freeze
          end
        end

        # THE BOOKKEEPING A CHECKED BUILD EMITS (Runtime::Frame): at power-on, at the end of each pass,
        # where the game halts and where a list is read past its end. Each word is a variable of the
        # build's own, placed as every variable is, and the two longer records are kept at the far
        # end of the quick memory.
        class PassBookkeeping
          include Console::Hardware

          Frame = Runtime::Frame

          def initialize(emitter:, primitives:, memory:)
            @emitter = emitter
            @primitives = primitives
            @memory = memory
          end

          # Where each name of Runtime::Frame is, once the program is lowered, for the reader:
          # +variables+ is where each variable went (GBA#var_addresses).
          def places(variables)
            words = Frame::WORDS.transform_values { |name| variables.fetch(name) }
            words.merge(Frame::FRAMES => variables.fetch(IR::Frames::COUNT), Frame::STEPS => steps_at,
                        Frame::FAULT => fault_at)
          end

          # Everything from nought at power-on: this console's memory is not cleared then.
          def emit_at_power_on
            @emitter.emit_number(ACC, 0)
            Frame::WORDS.each_value { |name| @primitives.store_var(ACC, name) }
            @primitives.store_var(ACC, IR::Frames::COUNT)
            @emitter.emit_number(TMP, steps_at)
            (Frame::STEPS_KEPT / 4).times { |k| @emitter.emit(ASM.str_offset(ACC, TMP, k * 4)) }
            @emitter.emit_number(TMP, fault_at)
            (Frame::FAULT_BYTES / 4).times { |k| @emitter.emit(ASM.str_offset(ACC, TMP, k * 4)) }
          end

          # The pass has ended: one more of them, and the game waiting, from here to the frame after.
          def emit_pass_ended
            @primitives.load_var(ACC, Frame::WORDS.fetch(Frame::PASSES))
            @emitter.emit(ASM.add_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, Frame::WORDS.fetch(Frame::PASSES))
            emit_word(Frame::WAITING, 1)
          end

          # The frames the pass took, as the screen counted them and not held at IR::Frames::MOST:
          # asked as the wait ends, before the marks the game reads move (Frames#emit_frame_step).
          def emit_frames_taken
            @primitives.load_var(ACC, IR::Frames::COUNT)
            @primitives.load_var(TMP, IR::Frames::SEEN)
            @emitter.emit(ASM.sub_reg(ACC, ACC, TMP))
            @primitives.load_var(TMP, Frame::WORDS.fetch(Frame::PASSES))
            @emitter.emit(ASM.and_imm(TMP, TMP, Frame::STEPS_KEPT - 1))
            @emitter.emit_number(SPARE, steps_at)
            @emitter.emit(ASM.add_reg(TMP, SPARE, TMP))
            @emitter.emit(ASM.strb(ACC, TMP))
          end

          # The frame after the wait shows the pass: said so, and where the reader has asked for this
          # pass to be the last, the game goes no further. Then it is no longer waiting.
          def emit_pass_shown
            @primitives.load_var(ACC, Frame::WORDS.fetch(Frame::PASSES))
            @primitives.store_var(ACC, Frame::WORDS.fetch(Frame::SHOWN))
            @primitives.load_var(ACC, Frame::WORDS.fetch(Frame::HOLD))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            going_on = @emitter.gensym
            @emitter.emit_branch(:bcond, going_on, cond: :eq)
            emit_jump_far(stopped_label)
            @emitter.place_label(going_on)
            emit_word(Frame::WAITING, 0)
          end

          # THE GAME HALTS: so said, its last picture shown, and the end said to be on the screen.
          def emit_halt
            emit_word(Frame::STATE, Frame::HALTED)
            emit_jump_far(stopping_label)
          end

          # A LIST READ OR WRITTEN PAST ITS END stops the game, as the interpreter stops it: r0 holds
          # the index, which is checked unsigned so a negative one is caught too, and +length+ is the
          # variable that holds how many items the list has. +place+ is where the list is kept, which
          # names it to the reader. r1 is spent; the read or write after loads what it needs again.
          def emit_refuse_index_past_length(length, place)
            within = @emitter.gensym
            @primitives.load_var(TMP, length)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, within, cond: :lo)
            @emitter.emit_number(SPARE, fault_at) # the game goes no further, so nothing waiting there is lost
            @emitter.emit(ASM.str_offset(ACC, SPARE, 8))
            @emitter.emit(ASM.str_offset(TMP, SPARE, 12))
            @emitter.emit_number(ACC, place)
            @emitter.emit(ASM.str_offset(ACC, SPARE, 4))
            @emitter.emit_number(ACC, Frame::INDEX_OUT_OF_RANGE)
            @emitter.emit(ASM.str_offset(ACC, SPARE, 0))
            emit_word(Frame::STATE, Frame::WENT_WRONG)
            emit_jump_far(stopping_label)
            @emitter.place_label(within)
          end

          # Where a halt and a fault go, emitted once at the end of the program: the frame after
          # shows what the game drew last, then the end is said to be on the screen and the game
          # sleeps from frame to frame. A held pass stops at the same sleep, with its own pass shown.
          # In a game that never waits for the screen (+frames+ false) its interrupt is not armed:
          # what it drew is on the screen already, and it stops where it is.
          def emit_stopping(frames:)
            @emitter.place_label(stopping_label)
            @emitter.emit(ASM.swi(GBA::SWI_VBLANK_INTR_WAIT << 16)) if frames
            emit_word(Frame::SHOWN, Frame::END_SHOWN)
            @emitter.place_label(stopped_label)
            if frames
              @emitter.emit(ASM.swi(GBA::SWI_VBLANK_INTR_WAIT << 16))
              @emitter.emit_branch(:b, stopped_label)
            else
              @emitter.emit(ASM.loop_forever)
            end
          end

          private

          # A jump to +label+ by its whole address: the routine jumping can be one kept in the quick
          # memory, which a plain jump to the cartridge cannot leave.
          def emit_jump_far(label)
            @emitter.emit_load_label_address(TMP, label)
            @emitter.emit(ASM.bx(TMP))
          end

          def emit_word(name, value)
            @emitter.emit_number(ACC, value)
            @primitives.store_var(ACC, Frame::WORDS.fetch(name))
          end

          def stopping_label = @stopping_label ||= @emitter.gensym
          def stopped_label = @stopped_label ||= @emitter.gensym

          def steps_at = @steps_at ||= @memory.alloc(Frame::STEPS_KEPT)
          def fault_at = @fault_at ||= @memory.alloc(Frame::FAULT_BYTES)
        end
      end
    end
  end
end
