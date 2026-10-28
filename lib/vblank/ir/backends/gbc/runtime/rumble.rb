# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # THE CARTRIDGE'S MOTOR (`rumble`, Nodes::Rumble). A Color cartridge with a rumble motor —
          # an MBC5 that says so in its header — runs it from bit 3 of the register that picks which
          # 8K of its save memory is in view (Console::GBCHardware::MBC_RAM_BANK): 1 and the motor
          # spins, 0 and it stops. Nothing else of the register changes what the motor does.
          #
          # A rumble is a pattern of eight frames and how many frames it lasts, as the Color's own
          # games keep one. rt_rumble(frames, pattern) starts it. Each frame drawn, as the music
          # moves on (Runtime::Frame, where rt_music_tick is called, owed frames included),
          # rt_rumble_tick turns the pattern a place to the right and sets the motor from its
          # lowest bit, as Pokémon Pinball's own does, until the frames run out, and then stops it —
          # the interpreter's Reference#step_motor, frame for frame. rt_rumble_stop stops it at
          # once, for a game that halts or goes wrong (Runtime::Frame's stopping).
          #
          # THE REGISTER ALSO PICKS THE SAVE MEMORY'S BANK, and a write sets both. So the bank the
          # save code puts in view is noted (BANK, rt_ram_bank) and every write of the motor keeps
          # it, and every write of the save code keeps the motor as it stands (MOTOR). The two never
          # come between each other: the motor moves on only at a frame boundary (as the game waits,
          # or with the interrupt held off), and the save code and rt_rumble run in a pass.
          module Rumble
            LEFT = "rt rumble left" # 16 bits: the frames the motor has still to run for
            BITS = "rt rumble bits" # the pattern, turned a place each frame
            MOTOR = "rt rumble motor" # the register's motor bit as it stands: 0 or MOTOR_BIT
            BANK = "rt rumble bank" # the save memory's bank in view

            # The register's bit that runs the motor.
            MOTOR_BIT = 0x08

            module_function

            def reserve(memory)
              memory.reserve(LEFT, 2)
              memory.reserve(BITS, 1)
              memory.reserve(MOTOR, 1)
              memory.reserve(BANK, 1)
            end

            # Does the game rumble?
            def any?(memory) = memory.reserved?(LEFT)

            def emit(asm, memory)
              h = Console::GBCHardware
              frames = Calls.arg(memory, 0, 2)
              pattern = Calls.arg(memory, 1, 2)

              # rt_rumble(frames, pattern): fewer than none is none, and more than 16 bits hold is
              # as many as they do (IR::Rumble::MOST_FRAMES).
              asm.label("rt_rumble")
              asm.load_hl_sp(2)
              asm.load(:b, 8)
              asm.call("rt_take_args")
              asm.load(:de, 0)
              asm.load_high(:a, frames + 3)
              asm.bit(7, :a)
              asm.jump_relative(:nz, "rt_rumble_frames")
              asm.load(:b, :a)
              asm.load_high(:a, frames + 2)
              asm.or_a(:b)
              asm.load(:de, IR::Rumble::MOST_FRAMES)
              asm.jump_relative(:nz, "rt_rumble_frames")
              asm.load_high(:a, frames)
              asm.load(:e, :a)
              asm.load_high(:a, frames + 1)
              asm.load(:d, :a)
              asm.label("rt_rumble_frames")
              asm.load(:hl, memory[LEFT])
              asm.load(:a, :e)
              asm.load([:hli], :a)
              asm.load(:a, :d)
              asm.load([:hl], :a)
              asm.load_high(:a, pattern)
              asm.load([memory[BITS]], :a)
              asm.ret

              # rt_rumble_tick: one frame of the motor.
              asm.label("rt_rumble_tick")
              asm.load(:hl, memory[LEFT])
              asm.load(:a, [:hli])
              asm.or_a([:hl])
              asm.jump_relative(:z, "rt_rumble_still")
              asm.dec(:hl)
              asm.load(:a, [:hl])
              asm.sub_a(1)
              asm.load([:hli], :a)
              asm.load(:a, [:hl])
              asm.sbc_a(0)
              asm.load([:hl], :a)
              asm.load(:a, [memory[BITS]])
              asm.rrca # turned a place to the right, the lowest bit round to the top
              asm.load([memory[BITS]], :a)
              asm.and_a(1)
              asm.jump_relative(:z, "rt_rumble_write")
              asm.load(:a, MOTOR_BIT)
              asm.jump_relative("rt_rumble_write")
              # rt_rumble_stop: no frames left, and the motor off.
              asm.label("rt_rumble_stop")
              asm.xor_a(:a)
              asm.load(:hl, memory[LEFT])
              asm.load([:hli], :a)
              asm.load([:hl], :a)
              asm.label("rt_rumble_still")
              asm.xor_a(:a)
              asm.label("rt_rumble_write")
              asm.load([memory[MOTOR]], :a)
              asm.load(:b, :a)
              asm.load(:a, [memory[BANK]])
              asm.or_a(:b)
              asm.load([h::MBC_RAM_BANK], :a)
              asm.ret

              # rt_ram_bank: the save memory's bank A in view, the motor kept as it stands. A is
              # kept.
              asm.label("rt_ram_bank")
              asm.load([memory[BANK]], :a)
              asm.push(:bc)
              asm.load(:b, :a)
              asm.load(:a, [memory[MOTOR]])
              asm.or_a(:b)
              asm.load([h::MBC_RAM_BANK], :a)
              asm.load(:a, :b)
              asm.pop(:bc)
              asm.ret
            end
          end
        end
      end
    end
  end
end
