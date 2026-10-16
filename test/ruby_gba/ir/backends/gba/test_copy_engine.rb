# frozen_string_literal: true

require "test_helper"
require "conformance_fixture"

# TELLING THE COPYING ENGINE WHAT TO COPY. The console has an engine that moves a block of
# memory on its own, and it is told what to do through three registers that sit side by side:
# where to copy from, where to, and how much — and writing the third is what starts it. So the
# address of the first is the only one that has to be built; the other two are a step along
# from it, and a store can name a step for nothing.
class TestCopyEngine < Minitest::Test
  runs_on :reference

  include RubyGBA::Console::Hardware

  A = RubyGBA::IR::Backends::GBA::ASM
  Emit = RubyGBA::IR::Backends::GBA::Emit
  Primitives = RubyGBA::IR::Backends::GBA::Primitives
  InRegister = Primitives::InRegister
  ACC = RubyGBA::IR::Backends::GBA::ACC
  TMP = RubyGBA::IR::Backends::GBA::TMP

  private def emitted
    emitter = Emit.new
    yield Primitives.new(emitter: emitter, memory: nil), emitter
    emitter.code.unpack("V*")
  end

  private def number_named(word)
    turn = ((word >> 8) & 0xF) * 2
    byte = word & 0xFF
    ((byte >> turn) | (byte << (32 - turn))) & 0xFFFFFFFF
  end

  # Run a straight line of loads and stores and say what was written where, in order. It
  # knows the four instructions these sequences are made of and stops at anything else.
  private def stores_made_by(words, registers = {})
    held = registers.dup
    words.filter_map do |word|
      to = (word >> 12) & 0xF
      case word & 0xFFF00000
      when 0xE3A00000 then held[to] = number_named(word)
      when 0xE3E00000 then held[to] = ~number_named(word) & 0xFFFFFFFF
      when 0xE3800000 then held[to] |= number_named(word)
      when 0xE5800000 then next [held.fetch((word >> 16) & 0xF) + (word & 0xFFF), held.fetch(to)]
      else flunk format("an instruction this test does not know: 0x%08X", word)
      end
      nil
    end
  end

  # The three instructions a number is put in a register with: the plain load, the load of
  # its opposite, and the one that adds a further byte.
  LOADS = [0xE3A00000, 0xE3E00000, 0xE3800000].freeze

  # How many instructions put a number in +register+.
  private def loads_into(words, register)
    words.count { |word| LOADS.include?(word & 0xFFF00000) && ((word >> 12) & 0xF) == register }
  end

  # --- the one place that writes the three ---

  def test_three_numbers_are_written_to_the_three_registers_and_the_start_is_last
    words = emitted { |p| p.emit_start_copy_engine(from: 0x03000010, to: 0x06000000, control: 0x84000100) }

    assert_equal [[REG_DMA3SAD, 0x03000010], [REG_DMA3DAD, 0x06000000], [REG_DMA3CNT, 0x84000100]],
                 stores_made_by(words)
  end

  def test_only_the_first_of_the_three_addresses_is_built
    words = emitted { |p| p.emit_start_copy_engine(from: 0x03000010, to: 0x06000000, control: 0x84000100) }

    assert_equal A.load_immediate(TMP, REG_DMA3SAD).bytesize / 4, loads_into(words, TMP),
                 "one address, and the other two are a step along from it"
  end

  def test_a_number_waiting_in_a_register_is_stored_from_there
    words = emitted do |p|
      p.emit_start_copy_engine(from: InRegister.new(5), to: InRegister.new(3), control: InRegister.new(4))
    end

    assert_equal [[REG_DMA3SAD, 0x55], [REG_DMA3DAD, 0x33], [REG_DMA3CNT, 0x44]],
                 stores_made_by(words, 5 => 0x55, 3 => 0x33, 4 => 0x44)
    assert_equal 0, loads_into(words, ACC), "nothing had to be loaded to be written"
  end

  # The accumulator is what a number is loaded through on its way to a register, so one
  # waiting there has to be written before the next number comes through.
  def test_a_number_waiting_in_the_accumulator_is_written_before_the_accumulator_is_used_again
    words = emitted do |p|
      p.emit_start_copy_engine(from: 0x03000010, to: InRegister.new(ACC), control: 0x84000100)
    end

    assert_equal [[REG_DMA3DAD, 0x0600A000], [REG_DMA3SAD, 0x03000010], [REG_DMA3CNT, 0x84000100]],
                 stores_made_by(words, ACC => 0x0600A000)
  end

  def test_a_number_worked_out_on_the_spot_is_written_too
    words = emitted do |p, emitter|
      p.emit_start_copy_engine(from: -> { emitter.emit(A.load_immediate(ACC, 0x08000400)) },
                               to: 0x03007000,
                               control: -> { emitter.emit(A.load_immediate_fixed(ACC, 0x84000020)) })
    end

    assert_equal [[REG_DMA3SAD, 0x08000400], [REG_DMA3DAD, 0x03007000], [REG_DMA3CNT, 0x84000020]],
                 stores_made_by(words)
  end

  # --- what it refuses, because being wrong here writes to the wrong place and says nothing ---

  def test_a_number_waiting_in_the_address_register_is_refused
    error = assert_raises(ArgumentError) do
      emitted { |p| p.emit_start_copy_engine(from: InRegister.new(TMP), to: 0, control: 0) }
    end
    assert_includes error.message, "r#{TMP}"
  end

  def test_a_start_waiting_in_the_accumulator_behind_a_number_loaded_through_it_is_refused
    assert_raises(ArgumentError) do
      emitted { |p| p.emit_start_copy_engine(from: 0x03000010, to: 0x06000000, control: InRegister.new(ACC)) }
    end
  end

  def test_working_a_number_out_must_leave_the_address_register_alone
    assert_raises(ArgumentError) do
      emitted do |p, emitter|
        p.emit_start_copy_engine(from: -> { emitter.emit(A.load_immediate(TMP, 4)) }, to: 0, control: 0)
      end
    end
  end

  def test_working_a_number_out_must_leave_a_start_that_is_still_waiting_alone
    error = assert_raises(ArgumentError) do
      emitted do |p, emitter|
        p.emit_start_copy_engine(from: -> { emitter.emit(A.load_immediate(7, 4)) }, to: 0, control: InRegister.new(7))
      end
    end
    assert_includes error.message, "r7"
  end

  # A call is a placeholder until the second pass, and the routine it reaches uses the
  # registers for its own work — so nothing read out of the block's instructions could say
  # what it left behind.
  def test_working_a_number_out_cannot_call_or_jump
    assert_raises(ArgumentError) do
      emitted do |p, emitter|
        p.emit_start_copy_engine(from: -> { emitter.emit_branch(:bl, "elsewhere") }, to: 0, control: 0)
      end
    end
  end

  # --- every program: nothing builds the second or third address any more ---

  # Each number built from more than one instruction, as [value, instructions].
  private def numbers_built_in(program)
    words = GBA.new.lower(program).unpack("V*")
    built = []
    at = 0
    while at < words.size
      word = words[at]
      length = 1
      if (word & 0xFFF00000) == 0xE3A00000
        register = (word >> 12) & 0xF
        more = 0xE3800000 | (register << 16) | (register << 12)
        value = number_named(word)
        while at + length < words.size && (words[at + length] & 0xFFFFF000) == more
          value |= number_named(words[at + length])
          length += 1
        end
        built << [value, length] if length > 1
      end
      at += length
    end
    built
  end

  private def assert_only_the_first_engine_address_is_built(program)
    built = numbers_built_in(program).map(&:first)
    assert_includes built, REG_DMA3SAD, "this program does start the engine"
    assert_equal 0, built.count(REG_DMA3DAD), "the destination register is a step from the first"
    assert_equal 0, built.count(REG_DMA3CNT), "and so is the one that starts it"
  end

  private def dsl_program(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program
  end

  def test_the_program_that_uses_every_kind_of_operation_builds_only_the_first
    assert_only_the_first_engine_address_is_built(ConformanceFixture.program)
  end

  def test_a_direct_colour_screen_builds_only_the_first
    program = dsl_program do
      screen :bitmap
      image :dot, width: 8, height: 8, data: Array.new(64, :red)
      x = var :x, 10
      hero = sprite :dot, at: [20, 20]
      game_loop do
        clear_screen :black
        dma_fill_rect 10, 10, 40, 3, :green
        draw_rect_at x, 40, 9, 6, :white
        blit :dot, x, 60
        hero.move :right
      end
    end
    assert_only_the_first_engine_address_is_built(program)
  end

  def test_a_tear_free_screen_builds_only_the_first
    program = dsl_program do
      screen :bitmap, tear_free: true
      image :dot, width: 8, height: 8, data: Array.new(64, :red)
      x = var :x, 10
      game_loop do
        clear_screen :black
        fill_rect 10, 10, 40, 4, :green
        draw_rect_at x, 40, 30, 6, :white
        blit :dot, x * 2, 60
      end
    end
    assert_only_the_first_engine_address_is_built(program)
  end

  def test_a_tiled_screen_builds_only_the_first
    program = dsl_program do
      screen :tiled
      image :brick, width: 8, height: 8, data: Array.new(64, :red)
      image :floor, width: 8, height: 8, data: Array.new(64, :blue)
      image :dot, width: 8, height: 8, data: Array.new(64, :white)
      tiles :room, "#" => :brick, "." => :floor
      room = background :room, tiles: :room, map: { hall: ["#.", ".#"], cave: ["..", "##"] }
      sprite :dot, at: [20, 20]
      level = var :level, 0
      game_loop do
        room.show_map level
        tint :red, level
      end
    end
    assert_only_the_first_engine_address_is_built(program)
  end
end
