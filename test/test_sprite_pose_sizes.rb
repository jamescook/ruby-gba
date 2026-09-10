# frozen_string_literal: true

require "test_helper"
require "differential"

# A SPRITE'S POSES ARE STORED AT THEIR OWN SIZE, not at the biggest one's.
#
# Poses are drawn on one canvas, big enough for the widest frame — a sword swing, a
# jump — and most frames use a fraction of it. Stored at the canvas's size the rest is
# blank that still costs sprite memory, because an object reads a contiguous run of
# tiles and cannot share the blank ones the way a background shares a repeated tile.
#
# The one thing that must not change is the picture: the character's origin is the
# canvas's corner, so a pose trimmed by (x0, y0) is drawn that much further along and
# lands exactly where it did. Corner-aligned instead, a character jitters around its
# own feet as the cycle plays — which is why every test here compares the two backends
# rather than only counting bytes.
class TestSpritePoseSizes < Minitest::Test
  include Differential

  CANVAS = 64
  INK = RubyGBA::Color.rgb(31, 20, 0)
  CLEAR = RubyGBA::Color.rgb(0, 0, 1)

  # A pose drawing a +w+ by +h+ block at (+ox+, +oy+) on a CANVAS-square canvas.
  def pose(w, h, ox, oy)
    (0...(CANVAS * CANVAS)).map do |i|
      x = i % CANVAS
      y = i / CANVAS
      x >= ox && x < ox + w && y >= oy && y < oy + h ? INK : CLEAR
    end
  end

  # +shapes+ is [w, h, ox, oy] per pose, so a test can make them all alike or all
  # different.
  def program(shapes, rate: 4)
    # Worked out here rather than inside the block: instance_eval makes `self` the
    # builder, where this test's own helpers are not in scope.
    art = shapes.map { |w, h, ox, oy| pose(w, h, ox, oy) }
    canvas = CANVAS
    clear = CLEAR
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      names = art.each_with_index.map do |data, k|
        n = :"pose#{k}"
        image n, width: canvas, height: canvas, data: data, transparent: clear
        n
      end
      sprite :hero, at: [40, 30], frames: names, rate: rate
      game_loop {}
    end
    builder.emit_pending_functions
    builder.program
  end

  # Built through RubyGBA.build so the build record — which is where the sprite-memory
  # figure lives — comes back with it.
  def built(shapes, rate: 4)
    art = shapes.map { |w, h, ox, oy| pose(w, h, ox, oy) }
    canvas = CANVAS
    clear = CLEAR
    RubyGBA.build("POSE", code: "BPOS", maker: "01", validate: false,
                  out: StringIO.new, err: StringIO.new) do
      screen :tiled
      names = art.each_with_index.map do |data, k|
        n = :"pose#{k}"
        image n, width: canvas, height: canvas, data: data, transparent: clear
        n
      end
      sprite :hero, at: [40, 30], frames: names, rate: rate
      game_loop {}
    end
  end

  def sprite_bytes(shapes) = built(shapes).built.video_memory.sprites.used

  # Every pose the same shape in the same place: they trim alike, and the sprite keeps
  # the plain draw (one size in its own entry, one stride between poses).
  ALIKE = Array.new(6) { [24, 32, 8, 8] }

  # Poses that really differ — a character winding up and swinging. These cannot share
  # a size, which is the case the pose table exists for.
  VARIED = [[8, 8, 8, 8], [16, 16, 8, 8], [32, 32, 8, 8], [16, 32, 8, 8], [8, 16, 8, 8], [32, 16, 8, 8]].freeze

  def test_a_cycle_costs_what_its_art_contains_not_what_its_canvas_does
    trimmed = sprite_bytes(ALIKE)
    canvas_sized = 6 * (CANVAS * CANVAS / 2) # six 64x64 poses, half a byte a pixel

    assert_operator trimmed, :<, canvas_sized / 2,
                    "six poses of 24x32 art on a 64x64 canvas should cost well under half"
  end

  # A CYCLE THAT DID NOT FIT NOW DOES, which is the whole reason this was wanted: twenty
  # poses on a 64x64 canvas want 40K of the console's 32K and the build refuses them.
  def test_a_long_cycle_that_did_not_fit_now_builds
    twenty = Array.new(20) { |k| [24, 32, 8 + (k % 3), 8] }

    assert_operator sprite_bytes(twenty), :<, 32 * 1024,
                    "twenty poses must fit the console's sprite memory"
  end

  # THE PICTURE IS UNCHANGED, which is the whole bargain. The interpreter draws from the
  # untrimmed image and knows nothing about any of this, so the console matching it over
  # a played cycle is the proof that trimming moved nothing.
  def test_a_cycle_of_alike_poses_draws_the_same_on_both_backends
    assert_backends_agree(program(ALIKE), frames: 24)
  end

  # ...and the same for poses that trimmed to DIFFERENT sizes, where the size, the tiles
  # and the offset all change with the pose and are read from the table.
  def test_a_cycle_of_differently_sized_poses_draws_the_same_on_both_backends
    assert_backends_agree(program(VARIED), frames: 24)
  end

  # THE TWO PATHS ARE REALLY TWO PATHS, pinned by what they cost rather than by reading
  # the build's own bookkeeping. Poses of different sizes cannot all be the biggest one's
  # size, so the varied cycle must come out SMALLER than six copies of its largest pose —
  # which is only true if each was stored at its own size.
  #
  # Without this, a change that quietly sent everything down the uniform path would
  # leave the table unexercised and every other test here still green.
  def test_poses_of_different_sizes_are_not_all_stored_at_the_biggest
    biggest = 32 * 32 / 2                # the largest pose in VARIED, half a byte a pixel
    assert_operator sprite_bytes(VARIED), :<, VARIED.length * biggest,
                    "each pose should cost its own size, not the biggest one's"
  end

  # A pose that draws nothing at all still has to be a legal size rather than a zero one.
  def test_a_wholly_see_through_pose_is_still_drawable
    blank = [[0, 0, 0, 0], [24, 32, 8, 8]]
    assert_backends_agree(program(blank), frames: 12)
  end

  # A SPRITE STORED THE BIG WAY POINTS AT THE RIGHT POSE. A picture drawn from more than
  # fifteen colours keeps a whole byte a pixel, so one of its 8x8 tiles is 64 bytes —
  # while a tile NUMBER counts in 32s whichever way the picture is stored. So the step
  # from one pose to the next is two per tile there and one in every other sprite in the
  # suite, and counting tiles instead of those units silently draws the wrong pose.
  INKS = (0...20).map { |i| RubyGBA::Color.rgb(i + 5, 31 - i, 3) }

  # An 8x8 block running through all twenty inks from +from+, on a 16x16 canvas.
  def wide_pose(from)
    (0...(16 * 16)).map do |i|
      x = i % 16
      next CLEAR unless x < 8 && (i / 16) < 8

      INKS[(from + ((i / 16) * 8) + x) % INKS.length]
    end
  end

  def test_a_sprite_stored_the_big_way_shows_the_pose_it_selected
    b = RubyGBA::IR::Build
    prog = b.program(
      b.screen(:tiled),
      b.bitmap(:p0, width: 16, height: 16, pixels: wide_pose(0).pack("v*"), transparent: CLEAR),
      b.bitmap(:p1, width: 16, height: 16, pixels: wide_pose(7).pack("v*"), transparent: CLEAR),
      b.object(:hero, poses: %i[p0 p1], pose: b.int(1),
                      x: b.int(40), y: b.int(40), active: b.int(1)),
      b.loop_(b.wait_vblank, b.present_objects([:hero]))
    )

    assert_backends_agree(prog, frames: 4)
  end
end
