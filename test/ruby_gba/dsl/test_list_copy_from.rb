# frozen_string_literal: true

require "test_helper"

# A RUN OF A TABLE COPIED INTO A LIST AT ONCE: `list.copy_from(table, at: start, count: n)`.
# The table is pictures or text built into the cartridge, the start is worked out as the game
# runs (which letter, which frame), and the list then holds exactly those n entries. A loop of
# `list[i] = table[start + i]` says the same thing a byte at a time; this is one copy.
class TestListCopyFrom < Minitest::Test
  LETTERS = (0...32).map { |n| (n * 7) - 100 }.freeze

  # Copies the run starting at +start+ and keeps its first and last items in variables, so
  # both backends can be read the same way.
  private def copying(start:, count: 4, width: :byte)
    proc do
      screen :tiled
      # A full build refuses a tiled screen with nothing on it.
      image(:dot, "#" => :white) { "########\n" * 8 }
      sprite :dot, at: [0, 0]
      letters = table :letters, LETTERS, width: width
      name = list :name, capacity: 8, width: width
      at = var :at, 0
      first = var :first, 0
      last = var :last, 0
      held = var :held, 0
      game_loop do
        at.set! start
        name.copy_from letters, at: at, count: count
        first.set! name[0]
        last.set! name[count - 1]
        held.set! name.length
      end
    end
  end

  private def interpreted(game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    Reference.new.run(builder.program, frames: 3)
  end

  private def readings(run) = %i[first last held].map { |name| run[name] }

  private def on_console(game)
    rom = RubyGBA.build("COPYFROM", out: StringIO.new, err: StringIO.new, &game)
    v = assert_emulator_loads_rom(rom, frames: 4, vars: rom.var_addresses)
    %i[first last held].map { |name| v.var(name) }
  end

  def test_a_run_from_a_worked_out_start_lands_the_same_on_both_backends
    game = copying(start: 5)

    assert_equal [LETTERS[5], LETTERS[8], 4], readings(interpreted(game))
    assert_equal readings(interpreted(game)), on_console(game)
  end

  # The console copies a whole word at a time, a half at a time, or a byte at a time, as the
  # run's start and length allow, so each width and an even and an odd start are each tried.
  def test_every_width_and_start_agrees_on_both_backends
    [[:byte, 8, 8], [:byte, 3, 6], [:half, 2, 4], [:half, 1, 3], [:word, 7, 5]].each do |width, start, count|
      game = copying(start: start, count: count, width: width)

      assert_equal [LETTERS[start], LETTERS[start + count - 1], count], readings(interpreted(game)), width.to_s
      assert_equal readings(interpreted(game)), on_console(game), "#{width} from #{start}"
    end
  end

  # A start worked out past either end is held so the run is inside the table.
  def test_a_start_off_the_table_is_held_inside_it
    { -3 => 0, 40 => LETTERS.length - 4 }.each do |start, held|
      game = copying(start: start)

      assert_equal [LETTERS[held], LETTERS[held + 3], 4], readings(interpreted(game)), "from #{start}"
      assert_equal readings(interpreted(game)), on_console(game), "from #{start}"
    end
  end

  # WHAT IT IS FOR: a file screen letters three names of six 64-byte pictures from a table of
  # letter pictures, eighteen runs, on the frame it opens. Copied a byte at a time that was
  # most of a frame; as a block it is a small part of one.
  def test_eighteen_runs_of_64_bytes_take_a_small_part_of_a_frame
    rom = RubyGBA.build("LETTERS", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :white) { "########\n" * 8 }
      sprite :dot, at: [0, 0]
      pictures = table :pictures, (0...4096).map { |n| (n * 5) & 0x7F }, width: :byte
      pieces = Array.new(18) { |n| list :"piece#{n}", capacity: 64, width: :byte, fast: false }
      letter = var :letter, 0
      game_loop do
        letter.set! (letter + 1) & 63
        pieces.each { |piece| piece.copy_from pictures, at: letter * 64, count: 64 }
      end
    end
    result = RubyGBA::Diagnostics::Profiler.run(rom, frames: 30, picture: false)

    assert_operator result.idle_share, :>, 0.95, "eighteen copies left #{result.idle_share} of the frame"
  end

  private def refused(&game)
    builder = Builder.new
    assert_raises(ArgumentError) { builder.instance_eval(&game) }.message
  end

  def test_a_copy_that_cannot_be_made_is_a_friendly_error
    shapes = {
      /needs a table/ => -> { list(:l, capacity: 4, width: :byte).copy_from [1, 2], at: 0, count: 2 },
      /count:/ => -> { list(:l, capacity: 4, width: :byte).copy_from table(:t, [1, 2], width: :byte), at: 0, count: var(:n, 2) },
      /table :t has 2/ => -> { list(:l, capacity: 4, width: :byte).copy_from table(:t, [1, 2], width: :byte), at: 0, count: 3 },
      /capacity of 3/ => -> { list(:l, capacity: 2, width: :byte).copy_from table(:t, [1, 2, 3], width: :byte), at: 0, count: 3 },
      /same `width:`/ => -> { list(:l, capacity: 4).copy_from table(:t, [1, 2], width: :byte), at: 0, count: 2 },
      /holds numbers with a fraction. The list holds whole numbers/ =>
        -> { list(:l, capacity: 4).copy_from table(:t, [1.5, 2.5]), at: 0, count: 2 },
      /`at:` holds a fraction/ =>
        -> { list(:l, capacity: 4, width: :byte).copy_from table(:t, [1, 2], width: :byte), at: var(:f, 1.5), count: 2 },
      /It was given List/ => -> { list(:l, capacity: 4, width: :byte).copy_from list(:m, capacity: 4), at: 0, count: 2 },
      /65536 bytes or less/ =>
        -> { list(:l, capacity: 70_000, width: :byte).copy_from table(:t, [1] * 70_000, width: :byte), at: 0, count: 70_000 }
    }
    shapes.each do |phrase, game|
      assert_match phrase, refused { instance_exec(&game) }
    end
  end
end
