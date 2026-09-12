# frozen_string_literal: true

require "test_helper"

# Turning a hardware sprite to an arbitrary angle (affine rotation). On a
# `screen :tiled`, `sprite.face_angle(d)` / `sprite.turn(d)` rotate the picture to
# any angle, pivoting on its own center — the thing `face` (a swap between a few
# fixed poses) can't do. These assert the observable result: where the picture's
# parts end up after it turns, that turning wraps the angle, and the friendly
# guardrails — on the interpreter oracle and on real hardware. The dev never
# touches the OAM affine matrix, a sine table, or fixed-point math.
class TestHardwareSpriteRotation < Minitest::Test
  include RubyGBA::Constants

  # A 16x16 sprite whose LEFT half is red and RIGHT half is green — two big regions,
  # so a probe a few pixels off center reads one clear color and a pixel of sampling
  # slop can't flip the answer. Which half lands where after a turn reveals both that
  # it turned and which way.
  DISC_ART = (["RRRRRRRRGGGGGGGG"] * 16).join("\n")

  # The sprite over a blue floor, at a fixed build-time angle so its resting picture is
  # deterministic. face_angle with a whole number turns the sprite once, up front.
  def turned_program(angle:, at: [40, 40])
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
        f.add 1
        (f >= 2).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "ROTATE", code: "BROT", maker: "01")
  end

  # Center of the 16x16 sprite placed at (40, 40); probes sit 4 pixels off it, well
  # inside a half.
  CX = 48
  CY = 48

  # --- it turns, and the halves land where a clockwise turn puts them ---

  # Upright: left half red is to the LEFT of center, right half green to the RIGHT.
  def test_upright_the_left_half_is_on_the_left
    screen = Reference.new.run(turned_program(angle: 0)).screen
    assert_equal Color.resolve(:red),   screen.pixel(CX - 4, CY), "red left half is on the left"
    assert_equal Color.resolve(:green), screen.pixel(CX + 4, CY), "green right half is on the right"
  end

  # A quarter turn clockwise carries the left up and the right down: red now on top,
  # green on the bottom. (Top goes to the right, right to the bottom, and so on — so
  # the left rises to the top.)
  def test_a_quarter_turn_clockwise_moves_the_left_half_to_the_top
    screen = Reference.new.run(turned_program(angle: 90)).screen
    assert_equal Color.resolve(:red),   screen.pixel(CX, CY - 4), "the red half turned up to the top"
    assert_equal Color.resolve(:green), screen.pixel(CX, CY + 4), "the green half turned down to the bottom"
  end

  # The same quarter turn on real hardware, through the console's sprite rotate/scale.
  def test_it_turns_on_the_console
    v = assert_emulator_loads_rom(rom_for(turned_program(angle: 90)), frames: 3)
    assert v.red?(CX, CY - 4),   "the red half is at the top on hardware, got 0x#{format('%04X', v.pixel_gba(CX, CY - 4))}"
    assert v.green?(CX, CY + 4), "the green half is at the bottom, got 0x#{format('%04X', v.pixel_gba(CX, CY + 4))}"
    assert v.blue?(8, 8),        "the floor still shows past the sprite, got 0x#{format('%04X', v.pixel_gba(8, 8))}"
  end

  # --- turning accumulates and wraps ---

  # turn(100) each of five frames: 100, 200, 300, 400->40, 140. The angle stays in
  # 0..359 the whole way (the wrap after each turn), landing on 140.
  def test_turning_accumulates_and_wraps_into_range
    prog = begin
      builder = Builder.new
      builder.instance_eval do
        screen :tiled
        image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
        image(:disc, "R" => :red, "G" => :green) { DISC_ART }
        tiles :ground, "#" => :floor
        background :field, tiles: :ground, map: Array.new(20, "#" * 30)
        disc = sprite :disc, at: [40, 40]
        f = var :f, 0
        game_loop do
          wait_vblank
          disc.turn(100)
          f.add 1
          (f >= 5).then { halt }
        end
      end
      builder.emit_pending_functions
      builder.program
    end
    i = Reference.new.run(prog)
    assert_equal 140, i[:__obj1_angle], "the angle accumulated and wrapped to 140"
  end

  # --- friendly guardrails ---

  # A bitmap sprite can't turn to an angle (no hardware rotate/scale) — a friendly
  # error that names the fix, not a NoMethodError.
  def test_a_bitmap_sprite_cannot_turn
    builder = Builder.new
    err = assert_raises(ArgumentError) do
      builder.instance_eval do
        screen :bitmap
        image(:hero, "#" => :red) { (["########"] * 8).join("\n") }
        clear_screen :black
        sprite(:hero, at: [10, 10]).face_angle(45)
      end
    end
    assert_match(/screen :tiled/, err.message)
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
  def two_turned_program
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
        f.add 1
        (f >= 2).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  # The console has 32 rotation groups, so at most 32 sprites can turn at once. The
  # 33rd is a friendly build error, not a silently-wrong sprite.
  def test_more_than_32_turning_sprites_is_a_friendly_error
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      33.times do |k|
        image(:"s#{k}", "#" => :red) { (["########"] * 8).join("\n") }
        sprite(:"s#{k}", at: [0, 0]).turn(1)
      end
    end
    builder.emit_pending_functions
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(builder.program) }
    assert_match(/at most 32/, err.message)
  end
end
