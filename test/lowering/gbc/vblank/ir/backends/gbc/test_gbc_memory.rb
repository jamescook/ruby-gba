# frozen_string_literal: true

require "test_helper"

# WHERE A COLOR GAME KEEPS ITS VARIABLES AND LISTS, against what the build checks are told the
# Color has. The checks count a game against the console's description before anything is
# built (Checks::IwramBudget), and the Color's lowering lays the game out here; the two have to
# be talking about the same room, or a game passes the check and is refused anyway.
class TestGBCMemory < Minitest::Test
  include VBlank::IR::Build

  GBC = VBlank::IR::Backends::GBC
  Memory = GBC::Memory
  COLOR = VBlank::Console::COLOR

  def test_the_colors_description_says_how_much_work_memory_there_is
    assert_equal COLOR.work_memory_bytes, Memory::HIGH_END - Memory::SHADOW_OAM
  end

  # What is free for a game is what the least game leaves: the stack, the sprite table's copy and
  # the runtime's own state are in memory before any variable is. Said a little short of it rather
  # than over, so the check never passes a game the lowering then refuses for that reason alone.
  def test_the_colors_description_leaves_a_game_the_room_its_lowering_leaves
    left = room_left_by_least_game

    assert_operator COLOR.free_work_memory_bytes, :<=, left
    assert_operator COLOR.free_work_memory_bytes, :>, left - 64, "the description gives away more than it needs to"
  end

  private def room_left_by_least_game
    memory = Memory.new
    lowering = GBC::Lowering.new(program(loop_(wait_vblank), console: :gbc), memory: memory)
    GBC::Runtime.reserve(memory, art: lowering.art, effects: lowering.music.effects,
                                 together: lowering.groups_up_together?)
    (Memory::LOW_END - Memory::FIRST) + (Memory::HIGH_END - Memory::HIGH_START) - memory.used
  end

  # What the check cannot see, the runtime's own state, can still fill the room, so the lowering
  # refuses too, in words the author can act on.
  def test_a_list_past_the_room_left_is_refused_in_plain_words
    memory = Memory.new
    memory.reserve("the list :rocks", 3 * 1024)
    memory.reserve("the list :stones", 4000)

    error = assert_raises(Memory::Full) { memory.reserve("the list :trail", 2 * 1024) }

    assert_match(/Game Boy Color's work memory/, error.message)
    assert_match(/The list :trail needs 2048 bytes/, error.message)
    assert_match(/smaller capacities/, error.message)
  end
end
