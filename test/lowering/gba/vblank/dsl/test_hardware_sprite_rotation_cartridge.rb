# frozen_string_literal: true

require "test_helper"

# Turning a hardware sprite to an arbitrary angle (affine rotation), on the Advance's own
# cartridge: where the picture's parts end up after it turns, read in the emulator, through the
# console's sprite rotate/scale. The friendly guardrails are in
# test/all/vblank/dsl/test_hardware_sprite_rotation.rb.
class TestHardwareSpriteRotationCartridge < Minitest::Test
  include VBlank::Console::Hardware

  # A 16x16 sprite whose LEFT half is red and RIGHT half is green — two big regions,
  # so a probe a few pixels off center reads one clear color and a pixel of sampling
  # slop can't flip the answer. Which half lands where after a turn reveals both that
  # it turned and which way.
  DISC_ART = (["RRRRRRRRGGGGGGGG"] * 16).join("\n")

  # The sprite over a blue floor, at a fixed build-time angle so its resting picture is
  # deterministic. face_angle with a whole number turns the sprite once, up front.
  private def turned_program(angle:, at: [40, 40])
    floor_map = Array.new(20, "#" * 30) # a blue floor filling the 240x160 screen
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      image(:disc, "R" => :red, "G" => :green) { DISC_ART }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: floor_map
      disc = sprite :disc, at: at
      disc.face_angle(angle)
      f = var :f, 0
      game_loop do
        wait_vblank
        f.add! 1
        (f >= 2).then { halt }
      end
    end
    builder.finalize_program
    builder.program
  end

  private def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "ROTATE", code: "BROT", maker: "01")
  end

  # Center of the 16x16 sprite placed at (40, 40); probes sit 4 pixels off it, well
  # inside a half.
  CX = 48
  CY = 48

  # --- it turns, and the halves land where a clockwise turn puts them ---

  # A quarter turn clockwise on real hardware, through the console's sprite rotate/scale: red
  # on top, green on the bottom.
  def test_it_turns_on_the_console
    v = assert_emulator_loads_rom(rom_for(turned_program(angle: 90)), frames: 3)
    assert v.red?(CX, CY - 4),   "the red half is at the top on hardware, got 0x#{format('%04X', v.pixel_gba(CX, CY - 4))}"
    assert v.green?(CX, CY + 4), "the green half is at the bottom, got 0x#{format('%04X', v.pixel_gba(CX, CY + 4))}"
    assert v.blue?(8, 8),        "the floor still shows past the sprite, got 0x#{format('%04X', v.pixel_gba(8, 8))}"
  end

  # --- two sprites turning at once each keep their own angle ---

  # TWO SPRITES TURNING TO DIFFERENT ANGLES, which is the thing that proves each gets a
  # rotation group of ITS OWN. The console holds a turning sprite's angle in one of 32
  # parameter groups and each sprite's entry names which group to read; give two sprites the
  # same group and the picture does not fail, it goes SUBTLY wrong — the group holds whichever
  # angle was written last, so both sprites draw at it and the game looks like it has one
  # rotation. Nothing but a second turning sprite can catch that, which is why this test
  # exists: with one sprite on screen, every group number works equally well.
  #
  # A quarter turn puts the red half on top; a half turn puts it on the right. So if the two
  # shared a group, one of these two would read the other's angle.
  def test_two_sprites_turning_at_once_each_keep_their_own_angle
    v = assert_emulator_loads_rom(rom_for(two_turned_program), frames: 3)

    assert v.red?(CX, CY - 4),    "the quarter-turned sprite has its red half on top, " \
                                  "got 0x#{format('%04X', v.pixel_gba(CX, CY - 4))}"
    assert v.green?(CX, CY + 4),  "...and its green half below"
    assert v.red?(FAR_CX + 4, CY), "the half-turned sprite has its red half on the RIGHT, " \
                                   "got 0x#{format('%04X', v.pixel_gba(FAR_CX + 4, CY))}"
    assert v.green?(FAR_CX - 4, CY), "...and its green half on the left"
  end

  # The second disc's center, far enough along that the two never touch.
  FAR_CX = 108

  # The same disc twice: one turned a quarter, one turned a half.
  private def two_turned_program
    floor_map = Array.new(20, "#" * 30)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      image(:quarter, "R" => :red, "G" => :green) { DISC_ART }
      image(:half, "R" => :red, "G" => :green) { DISC_ART }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: floor_map
      sprite(:quarter, at: [40, 40]).face_angle(90)
      sprite(:half, at: [100, 40]).face_angle(180)
      f = var :f, 0
      game_loop do
        wait_vblank
        f.add! 1
        (f >= 2).then { halt }
      end
    end
    builder.finalize_program
    builder.program
  end
end
