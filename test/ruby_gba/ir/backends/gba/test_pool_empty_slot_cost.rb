# frozen_string_literal: true

require "test_helper"

require "stringio"

# WHAT A POOL'S EMPTY SLOTS COST THE FRAME. A pool that draws has a sprite for every thing it can
# hold, and before each frame the framework writes the console's table row for each: where a live
# thing stands, or "hidden" for a place with nothing in it. A game sized for its biggest room keeps
# pools mostly empty in every other room, so what an empty place costs is what every room pays for
# the biggest one. It costs a few instructions — its row marked hidden, and on to the next — and
# not the whole write a live thing needs.
class TestPoolEmptySlotCost < Minitest::Test
  include EmulatorSupport

  # Two things live, in a pool declared with +capacity+ slots.
  private def rom(capacity)
    RubyGBA.build("ROWS", console: :gba, out: StringIO.new, err: StringIO.new, profile: false) do
      screen :tiled
      image(:rock, "#" => :white) { Array.new(8) { "#" * 8 }.join("\n") }
      var :where, 0
      scene(:play) do
        rocks = pool :rocks, x: 0, y: 0, capacity: capacity, image: :rock
        after(1) do
          rocks.spawn(x: 10, y: 10)
          rocks.spawn(x: 30, y: 10)
        end
        rocks.each { |r| r.x.add! 1 }
      end
      game_loop { case_var(:where) { when_val 0, :play } }
    end
  end

  ROUTINE = RubyGBA::IR::Backends::GBA::SpriteDrawing.sprites_routine(:_scene_play)

  private def sprite_writing_work(capacity)
    result = RubyGBA::Diagnostics::Profiler.run(rom(capacity), frames: 30, picture: false)
    RubyGBA::Diagnostics::Profiler.work_in(result).fetch(ROUTINE)
  end

  # ...AND IT IS STILL HIDDEN. Three things come, one goes, two more come: the console draws the
  # four left where the interpreter does, and nothing at the places with nothing in them.
  def test_the_places_with_nothing_in_them_show_nothing
    require_emulator!
    program = RubyGBA::Builder.new.tap do |b|
      b.instance_eval do
        screen :tiled
        image(:rock, "#" => :white) { Array.new(8) { "#" * 8 }.join("\n") }
        rocks = pool :rocks, x: 0, y: 0, capacity: 12, image: :rock
        pass = var :pass, 0
        game_loop do
          pass.add! 1
          (pass == 2).then { 3.times { |n| rocks.spawn(x: 10 + (20 * n), y: 10) } }
          (pass == 4).then { rocks.each { |r| (r.x == 30).then { r.remove } } }
          (pass == 6).then { 2.times { |n| rocks.spawn(x: 100 + (20 * n), y: 40) } }
        end
      end
      b.finalize_program
    end.program
    interpreted = Reference.new.run(program, frames: 10).sprites(:rocks).map { |row| [row.x, row.y] }.sort
    drawn = assert_emulator_loads_rom(assemble_rom(program), frames: 12).sprites(:rocks).map { |row| [row.x, row.y] }.sort

    assert_equal [[10, 10], [50, 10], [100, 40], [120, 40]], interpreted
    assert_equal interpreted, drawn
  end

  # Marking a row hidden is a store, and stepping to the next a few more.
  MOST_INSTRUCTIONS_AN_EMPTY_SLOT = 12

  def test_an_empty_slot_costs_a_few_instructions_a_frame
    require_emulator!
    small = sprite_writing_work(4)
    big = sprite_writing_work(40)
    each = (big - small) / 36.0

    assert_operator each, :<=, MOST_INSTRUCTIONS_AN_EMPTY_SLOT,
                    "two things live: #{small} instructions a frame in a pool of 4, #{big} in a pool of 40"
  end
end
