# frozen_string_literal: true

require "test_helper"
require "stringio"
require "console/gba/examples/test_shmup_example"

# The Shmup example's cartridge: it builds, the boss is cut into several of the console's
# objects, and the whole game renders on real hardware, read in the emulator. What the game does
# is in test/console/gba/examples/test_shmup_example.rb.
class TestShmupExampleCartridge < Minitest::Test
  include ShmupExampleBoss

  # The boss as the console really drew it, +frames+ into a run: how far its hull reaches
  # across the screen, and whether either end of that is the gun arm.
  private def console_boss(frames)
    v = assert_emulator_loads_rom(Shmup.build_rom(out: StringIO.new, err: StringIO.new), frames: frames)
    lit = (BOSS_ROW - 20..BOSS_ROW).step(4).flat_map do |y|
      (0...240).step(2).select { |x| v.pixel_is?(x, y, :magenta) }
    end
    return nil if lit.empty?

    low = lit.min
    high = lit.max
    [low, high,
     (low..low + 6).any? { |x| v.pixel_is?(x, BOSS_ROW, :magenta) },
     (high - 6..high).any? { |x| v.pixel_is?(x, BOSS_ROW, :magenta) }]
  end

  # What the build made of the game's sprites, which is where the boss's object count is.
  private def video_memory
    backend = VBlank::IR::Backends::GBA.new
    backend.lower(Shmup.program)
    backend.build_record(Shmup.program).video_memory
  end

  def test_the_example_builds_clean
    rom = Shmup.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0, "the split-across-files game still builds one ROM"
  end

  # --- the boss (boss.rb): one sprite bigger than anything the console draws ---

  # 96x48 is past the console's largest rectangle, so the build cuts it up. What the game
  # says is one `sprite`; what the hardware gets is several objects — and the rest of the
  # game (three enemies, a ship, a shot, the HUD's glyphs) still has to fit beside them.
  def test_the_boss_is_one_sprite_the_console_has_to_draw_as_several
    objects = video_memory.objects

    refute_nil objects, "a game with a picture too big for one object reports what it spent"
    assert_includes objects.big.to_h, :boss_left, "the boss is the picture that needed cutting"
    assert_operator objects.big.to_h[:boss_left], :>, 1, "and it took more than one object"
    assert_operator objects.used, :<=, objects.capacity,
                    "the whole game still fits the sprites the console draws at once"
  end

  # The whole thing runs on the console: the ship and HUD while playing.
  def test_it_renders_on_the_console
    v = assert_emulator_loads_rom(Shmup.build_rom(out: StringIO.new, err: StringIO.new), frames: 3)
    assert v.pixel_is?(119, 132, :cyan), "the ship, got 0x#{format('%04X', v.pixel_gba(119, 132))}"
    assert v.white?(9, 4), "the HUD text, got 0x#{format('%04X', v.pixel_gba(9, 4))}"
  end

  # And the boss renders on the console, which is the half no interpreter can answer: the
  # interpreter draws the picture whole and knows nothing about pieces, so only hardware
  # can say whether the several objects the build cut land shoulder to shoulder. Read
  # straight off the framebuffer: how far the hull reaches, and which end the arm is on.
  def test_the_boss_renders_on_the_console
    low, high, arm_left, arm_right = console_boss(BOSS_FACING_LEFT)

    refute_nil low, "the boss is on screen"
    assert_operator high - low, :>, 64,
                    "the console drew the whole cruiser, wider than one sprite can be"
    assert arm_left, "banking left, the gun arm is at the left end"
    refute arm_right, "and nothing of it is at the right"
  end

  # Turned round on the console: the mirrored pose is the picture reflected about the whole
  # canvas, so the arm swaps ends. Get the reflection wrong — each piece flipped where it
  # stands — and the cruiser turns inside out while still looking plausible.
  def test_the_boss_turns_round_on_the_console
    _low, _high, arm_left, arm_right = console_boss(BOSS_FACING_RIGHT)

    refute arm_left, "bounced off the left edge, nothing of the arm is at the left end"
    assert arm_right, "it is at the right"
  end

  # And the game-over screen renders on the console: run long enough (at rest) to lose all
  # three ships, and the GAME OVER banner is on screen — scene-switched presentation, live
  # on hardware.
  def test_the_game_over_screen_renders_on_the_console
    v = assert_emulator_loads_rom(Shmup.build_rom(out: StringIO.new, err: StringIO.new), frames: 380)
    assert v.pixel_is?(94, 68, :red), "the GAME OVER banner, got 0x#{format('%04X', v.pixel_gba(94, 68))}"
    refute v.pixel_is?(119, 132, :cyan), "the ship is gone on the game-over screen"
  end
end
