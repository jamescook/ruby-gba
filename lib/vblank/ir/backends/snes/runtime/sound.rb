# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE SOUND UNIT, AND HOW THE CONSOLE TALKS TO IT. A Super Nintendo's sound is made by a
          # small computer of its own: an SPC700 processor with 64K of memory, and the S-DSP, which
          # mixes eight voices, each playing a recorded sound at the pitch and volume its registers
          # say. The console's processor cannot see any of that memory. All it has are four one-byte
          # mailboxes ($2140-$2143 on its side, $F4-$F7 on the sound unit's): a byte the console
          # writes into one is read by the SPC700, and a byte the SPC700 writes is read by the console.
          #
          # SENDING ITS PROGRAM. At power-on the SPC700 runs a little program built into the chip,
          # which zeroes its direct page, puts $AA and $BB in the first two mailboxes to say it is
          # ready, and then takes a program a byte at a time: the console writes the byte into
          # mailbox 1 and its number (the low eight bits of where it is) into mailbox 0, and waits
          # until the SPC700 copies that number back to say it has the byte. Each command is started
          # by a "kick", a number in mailbox 0 that is not the next byte's: $CC for the first, and
          # after the bytes one past the last byte's number. A last command with nought in mailbox 1
          # says where to start the program, and the built-in program jumps there. rt_sound_start
          # does all that, once, at power-on, with interrupts held off and the screen's interrupt
          # still off: the last byte's answer lasts only a few of the SPC700's cycles, and an
          # interrupt could miss it. Its waits have no limit — at power-on the built-in program is
          # always there to answer. (fullsnes, "SNES APU Main CPU Communication Port", which has the
          # built-in program.)
          #
          # THE PROGRAM IT RUNS (Sound.driver) does one thing: it waits for mailbox 0 to change, and
          # then does the command the other three hold — today only "write this value into this
          # DSP register" — and copies mailbox 0's new number back to say it is done. Everything a
          # sound is (which recording, its pitch, its volume, its envelope, key on and key off) is
          # DSP registers, so the console plays every sound by writing them through it.
          #
          # NEVER LOSING A FRAME TO SOUND. rt_sound_write sends one register write and does not wait
          # for it to be done: it waits instead, before sending, for the write before it to have been
          # answered, which takes the SPC700 a few dozen of its cycles. That wait is bounded
          # (PATIENCE tries); a sound unit that has not answered by then has its write dropped and
          # counted in DROPPED, and the game goes on.
          #
          # Every routine is reached with JSL and leaves A, X and Y 16 bits wide. Mailboxes 0 and 1
          # are written a byte at a time, since a 16-bit write to $2140 can spoil $2143 on some
          # cartridges (fullsnes); mailboxes 2 and 3 take a 16-bit write, as fullsnes's uploader
          # writes them.
          module Sound
            # Where in the sound unit's memory its program goes: past the direct page, the stack
            # ($0100-$01FF) and nothing else.
            DRIVER_AT = 0x0200

            # What the built-in program puts in mailboxes 0 and 1 when it is ready, and the first
            # number the console answers with.
            READY = 0xBBAA
            FIRST_KICK = 0xCC

            # The commands the program knows, in mailbox 1.
            WRITE_DSP = 1

            # The SPC700's mailboxes and the DSP's two registers that reach the rest of it: $F2
            # picks a DSP register, and $F3 is its value.
            DSP_ADDRESS = 0xF2
            DSP_DATA = 0xF3
            PORTS = [0xF4, 0xF5, 0xF6, 0xF7].freeze

            # Where the program keeps the last number it answered, in its direct page.
            LAST_ANSWERED = 0x00

            # How many times rt_sound_write reads mailbox 0 for the answer to the write before.
            PATIENCE = 256

            LIVE = "rt sound live" # 1 once the program was sent and started
            SENT = "rt sound sent" # the number of the last command sent, in mailbox 0
            DROPPED = "rt sound dropped" # writes dropped because the sound unit had not answered

            R0 = Memory.register(0)
            R1 = Memory.register(1)

            module_function

            def reserve(memory)
              memory.reserve(LIVE, 2)
              memory.reserve(SENT, 2)
              memory.reserve(DROPPED, 2)
            end

            # The program the SPC700 runs once it has been sent.
            def driver
              ports = PORTS
              spc = SPC700.new(origin: DRIVER_AT)
              spc.instance_eval do
                mov :a, direct(ports[0]) # the number the console started it with
                mov direct(LAST_ANSWERED), :a
                label "wait"
                mov :a, direct(ports[0])
                cmp :a, direct(LAST_ANSWERED)
                beq "wait"
                mov direct(LAST_ANSWERED), :a
                mov :a, direct(ports[1])
                cmp :a, imm(WRITE_DSP)
                bne "answer"
                mov direct(DSP_ADDRESS), direct(ports[2])
                mov direct(DSP_DATA), direct(ports[3])
                label "answer"
                mov :a, direct(LAST_ANSWERED)
                mov direct(ports[0]), :a
                bra "wait"
              end
              spc
            end

            # The program's bytes in the cartridge, for rt_sound_start to send.
            def sections
              asm = W65816.new("sound driver")
              asm.label("sound driver")
              asm.data_bytes(driver.assembled.bytes)
              [asm.section]
            end

            def emit(asm, memory)
              emit_start(asm, memory)
              emit_write(asm, memory)
            end

            # rt_sound_start: the program sent, a byte at a time, and started.
            def emit_start(asm, memory)
              h = Console::SNESHardware
              length = driver.assembled.bytesize
              kick = ((length + 2) & 0xFF) | 1 # past the last byte's number, and never nought
              asm.label("rt_sound_start")
              asm.php
              asm.sei
              asm.label("rt_sound_await_ready")
              asm.lda(asm.abs(h::APUIO0))
              asm.cmp(READY)
              asm.bne("rt_sound_await_ready")
              emit_command(asm, command: 1, kick: FIRST_KICK, echo: "rt_sound_kicked")
              asm.ldx(0)
              asm.sep(0x20)
              asm.label("rt_sound_next_byte")
              asm.lda(asm.long_x("sound driver"))
              asm.sta(asm.abs(h::APUIO1))
              asm.txa
              asm.sta(asm.abs(h::APUIO0))
              emit_await_echo(asm, "rt_sound_byte_taken")
              asm.inx
              asm.cpx(length)
              asm.bne("rt_sound_next_byte")
              asm.rep(0x20)
              emit_command(asm, command: 0, kick: kick, echo: "rt_sound_started")
              asm.lda(kick)
              asm.sta(asm.abs(memory[SENT]))
              asm.lda(1)
              asm.sta(asm.abs(memory[LIVE]))
              asm.plp
              asm.rtl
            end

            # One of the built-in program's commands, with A 16 bits wide before and after: where
            # (always DRIVER_AT, which is where the bytes go and then where the program starts) in
            # mailboxes 2 and 3, +command+ in mailbox 1 (nought starts the program), and +kick+ in
            # mailbox 0, waited for until it comes back.
            def emit_command(asm, command:, kick:, echo:)
              h = Console::SNESHardware
              asm.lda(DRIVER_AT)
              asm.sta(asm.abs(h::APUIO2))
              asm.sep(0x20)
              if command.zero?
                asm.stz(asm.abs(h::APUIO1))
              else
                asm.lda(command)
                asm.sta(asm.abs(h::APUIO1))
              end
              asm.lda(kick)
              asm.sta(asm.abs(h::APUIO0))
              emit_await_echo(asm, echo)
              asm.rep(0x20)
            end

            # A wait, at +label+, until mailbox 0 reads back what A (8 bits) holds.
            def emit_await_echo(asm, label)
              asm.label(label)
              asm.cmp(asm.abs(Console::SNESHardware::APUIO0))
              asm.bne(label)
            end

            # rt_sound_write: DSP register R0 = R1, sent once the write before it has been answered,
            # or dropped and counted when it is not answered in time. Nothing at all before the
            # program has been sent.
            def emit_write(asm, memory)
              h = Console::SNESHardware
              asm.label("rt_sound_write")
              asm.lda(asm.abs(memory[LIVE]))
              asm.beq("rt_sound_write_done")
              asm.ldx(PATIENCE)
              asm.sep(0x20)
              asm.label("rt_sound_write_wait")
              asm.lda(asm.abs(h::APUIO0))
              asm.cmp(asm.abs(memory[SENT]))
              asm.beq("rt_sound_write_send")
              asm.dex
              asm.bne("rt_sound_write_wait")
              asm.rep(0x20)
              asm.inc(asm.abs(memory[DROPPED]))
              asm.rtl
              asm.label("rt_sound_write_send")
              # Reached by the branch above with A still 8 bits wide, whatever the lines just before
              # the label left the assembler counting.
              asm.widths(a16: false, xy16: true)
              asm.lda(asm.direct(R0))
              asm.sta(asm.abs(h::APUIO2))
              asm.lda(asm.direct(R1))
              asm.sta(asm.abs(h::APUIO3))
              asm.lda(WRITE_DSP)
              asm.sta(asm.abs(h::APUIO1))
              asm.lda(asm.abs(memory[SENT]))
              asm.inc
              asm.sta(asm.abs(memory[SENT]))
              asm.sta(asm.abs(h::APUIO0))
              asm.rep(0x20)
              asm.label("rt_sound_write_done")
              asm.rtl
            end
          end
        end
      end
    end
  end
end
