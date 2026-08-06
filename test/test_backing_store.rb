# frozen_string_literal: true

require "test_helper"

# The backing-store primitive: save the pixels under a patch of the screen, draw
# over them, then paint them back — so a moving object leaves no trail. This is
# the low-level op the `sprite` helper is built on, tested here on its own at the
# IR level (no DSL sugar) against both backends: the interpreter, and the console
# via gemba. The proof is "after cover-then-restore, every pixel is exactly what
# it was before" — including a patch hanging off a screen edge.
class TestBackingStore < Minitest::Test
  include RubyGBA::IR::Build

  # A scene with a distinctive patch, save an 8x8 area over it, cover that area
  # with green, then restore. The scene should look untouched afterwards.
  def cover_and_restore(save_xy, restore_xy)
    program(
      screen(:bitmap),
      clear_screen(:blue),
      fill_rect(save_xy[0] + 2, save_xy[1] + 2, 4, 4, :red), # a red patch inside the area
      backing_buffer(:under, width: 8, height: 8),
      save_region(:under, int(save_xy[0]), int(save_xy[1])),
      fill_rect(save_xy[0], save_xy[1], 8, 8, :green),       # a "sprite" covers it
      restore_region(:under, int(restore_xy[0]), int(restore_xy[1])),
      halt
    )
  end

  # ---- interpreter: restore puts back exactly what was captured ----

  def test_restore_reinstates_the_pixels_under_a_covered_patch
    s = Reference.new.run(cover_and_restore([10, 10], [10, 10])).screen

    # the red patch and its blue surround are back; no green survived the restore
    assert_equal Color.resolve(:red), s.pixel(12, 12), "the red patch wasn't restored"
    assert_equal Color.resolve(:blue), s.pixel(10, 10), "the blue surround wasn't restored"
    (10..17).each do |y|
      (10..17).each do |x|
        refute_equal Color.resolve(:green), s.pixel(x, y), "green left behind at (#{x},#{y})"
      end
    end
  end

  def test_a_restore_before_any_save_does_nothing
    # No save_region ran, so there's nothing to put back — the green stays.
    s = Reference.new.run(program(
      screen(:bitmap),
      clear_screen(:blue),
      backing_buffer(:under, width: 8, height: 8),
      fill_rect(10, 10, 8, 8, :green),
      restore_region(:under, int(10), int(10)),
      halt
    )).screen
    assert_equal Color.resolve(:green), s.pixel(12, 12), "an unsaved restore shouldn't paint anything"
  end

  # A patch hanging off the left edge: the off-screen columns have nothing to
  # remember, and the on-screen part still round-trips without wrapping.
  def test_a_patch_off_the_edge_round_trips_the_visible_part
    s = Reference.new.run(program(
      screen(:bitmap),
      clear_screen(:blue),
      fill_rect(0, 20, 4, 4, :red),      # visible detail near the left edge
      backing_buffer(:edge, width: 8, height: 8),
      save_region(:edge, int(-3), int(18)), # 3 columns hang off the left
      fill_rect(0, 18, 5, 8, :green),
      restore_region(:edge, int(-3), int(18)),
      halt
    )).screen
    assert_equal Color.resolve(:red), s.pixel(1, 21), "on-screen detail wasn't restored"
    assert_equal Color.resolve(:blue), s.pixel(0, 18), "on-screen surround wasn't restored"
    # nothing wrapped onto the far right of any of those rows
    (18..25).each { |y| assert_equal Color.resolve(:blue), s.pixel(239, y), "a row wrapped to the right edge at y=#{y}" }
  end

  # ---- moving: restore old, save new, draw new — the sprite loop, no trail ----

  def test_the_move_pattern_leaves_no_trail
    # Save under (10,10); cover it; then "move" one step right: restore the old
    # spot, save under the new spot, cover the new spot. The old spot must be clean.
    s = Reference.new.run(program(
      screen(:bitmap),
      clear_screen(:blue),
      backing_buffer(:m, width: 8, height: 8),
      save_region(:m, int(10), int(10)),
      fill_rect(10, 10, 8, 8, :green),   # object drawn at (10,10)
      restore_region(:m, int(10), int(10)), # move: put back the old spot
      save_region(:m, int(12), int(10)),    # remember the new spot
      fill_rect(12, 10, 8, 8, :green),      # object drawn at (12,10)
      halt
    )).screen
    # the two leftmost columns the object vacated are blue again (no trail)
    assert_equal Color.resolve(:blue), s.pixel(10, 12)
    assert_equal Color.resolve(:blue), s.pixel(11, 12)
    # the object is at its new spot
    assert_equal Color.resolve(:green), s.pixel(15, 12)
  end

  # ---- hardware: the same round-trip on the console ----

  def test_restore_reinstates_the_patch_on_gemba
    rom = ROM.assemble(GBA.new.lower(cover_and_restore([10, 10], [10, 10])),
                       title: "BACKSTOR", code: "BBKS", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 2)
    assert v.red?(12, 12), "the red patch wasn't restored on hardware — got #{v.pixel_gba(12, 12).to_s(16)}"
    assert v.blue?(10, 10), "the blue surround wasn't restored on hardware"
    refute v.pixel_is?(14, 14, :green), "green survived the restore on hardware"
  end

  # ---- misuse ----

  def test_two_sizes_for_one_buffer_is_a_lowering_error
    prog = program(
      screen(:bitmap),
      backing_buffer(:b, width: 8, height: 8),
      backing_buffer(:b, width: 4, height: 4),
      halt
    )
    err = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { GBA.new.lower(prog) }
    assert_match(/two different sizes/, err.message)
  end
end
