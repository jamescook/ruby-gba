# frozen_string_literal: true

require "test_helper"
require "differential"

# A POSE MAY BE ANOTHER POSE MIRRORED, storing no pixels of its own.
#
# "Left is the right one, backwards" is how nearly every 2D game faces a character, and
# saying it used to mean keeping both sets of pixels. The console draws an object
# reversed for nothing, so one set will do — and the build works out which poses are
# mirrors by looking at them, so art drawn both ways by hand gets the saving too.
#
# The mirror is about the object's own box, so the thing that can go wrong is the
# PLACE: a character that stands a little left of centre must stand the same distance
# right of centre facing the other way, not jump. That is why almost every test here
# compares the two backends over a played cycle rather than counting bytes.
class TestSpriteMirror < Minitest::Test
  include Differential

  CANVAS = 32
  INK = RubyGBA::Color.rgb(31, 20, 0)
  EDGE = RubyGBA::Color.rgb(0, 31, 10)
  CLEAR = RubyGBA::Color.rgb(0, 0, 1)

  # A pose that is deliberately NOT symmetric and NOT centred: a block at (+ox+, +oy+)
  # with its left column a different colour, so a mirror that is drawn in the wrong
  # place — or the right place but the wrong way round — shows up as different pixels.
  def lopsided(ox, oy, w = 10, h = 12)
    (0...(CANVAS * CANVAS)).map do |i|
      x = i % CANVAS
      y = i / CANVAS
      next CLEAR unless x >= ox && x < ox + w && y >= oy && y < oy + h

      x == ox ? EDGE : INK
    end
  end

  # Build a program through the DSL. +poses+ is a list of pixel arrays and +mirrors+ a
  # list of indexes into it: each named pose is followed by mirrors of the ones listed,
  # so the sprite's cycle runs through the originals and then their mirrors.
  def program(poses, mirror_of: [], rate: 3, at: [40, 30])
    canvas = CANVAS
    clear = CLEAR
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      names = poses.each_with_index.map do |data, k|
        n = :"pose#{k}"
        image n, width: canvas, height: canvas, data: data, transparent: clear
        n
      end
      names += mirror_of.map { |k| mirror(names[k]) }
      sprite :hero, at: at, frames: names, rate: rate
      game_loop {}
    end
    builder.emit_pending_functions
    builder.program
  end

  def sprite_bytes(poses, mirror_of: [])
    canvas = CANVAS
    clear = CLEAR
    rom = RubyGBA.build("MIRR", code: "BMIR", maker: "01", validate: false,
                        out: StringIO.new, err: StringIO.new) do
      screen :tiled
      names = poses.each_with_index.map do |data, k|
        n = :"pose#{k}"
        image n, width: canvas, height: canvas, data: data, transparent: clear
        n
      end
      names += mirror_of.map { |k| mirror(names[k]) }
      sprite :hero, at: [40, 30], frames: names, rate: 3
      game_loop {}
    end
    rom.built.video_memory.sprites.used
  end

  # THE PICTURE IS THE WHOLE POINT. The interpreter has no sprite hardware and draws
  # the mirrored picture itself, so the console matching it over a played cycle is what
  # says the mirror landed in the right place, the right way round.
  def test_a_mirrored_pose_draws_as_the_mirror_image
    assert_backends_agree(program([lopsided(6, 4)], mirror_of: [0]), frames: 12)
  end

  # ...and for art that is nowhere near the middle of its canvas, which is where a
  # mirror drawn at the source's own offset would land visibly wrong.
  def test_a_mirrored_pose_of_art_pushed_to_one_side_lands_in_the_right_place
    assert_backends_agree(program([lopsided(0, 4)], mirror_of: [0]), frames: 12)
    assert_backends_agree(program([lopsided(CANVAS - 10, 4)], mirror_of: [0]), frames: 12)
  end

  # A whole cycle mirrored — the case a character that walks both ways really is.
  def test_a_mirrored_walk_cycle_draws_the_same_on_both_backends
    walk = [lopsided(6, 4), lopsided(8, 5, 12, 10), lopsided(5, 6, 9, 14)]
    assert_backends_agree(program(walk, mirror_of: [0, 1, 2]), frames: 24)
  end

  # A MIRRORED POSE COSTS NO SPRITE MEMORY, which is the reason for all of it. Six poses
  # made of three pictures and their mirrors must cost what the three cost.
  def test_a_mirrored_pose_stores_no_pixels_of_its_own
    walk = [lopsided(6, 4), lopsided(8, 5, 12, 10), lopsided(5, 6, 9, 14)]

    assert_equal sprite_bytes(walk), sprite_bytes(walk, mirror_of: [0, 1, 2]),
                 "three pictures and their mirrors should cost what the three pictures cost"
  end

  # NOBODY HAS TO SAY SO: art drawn both ways by hand is noticed and stored once, the
  # same way two sprites showing the same picture already share it. Measured against a
  # pair of pictures that are NOT mirrors and cover the same box, so the comparison is
  # about the sharing rather than about how much each pose trims to.
  def test_art_that_is_already_a_mirror_is_noticed_without_being_declared
    right = lopsided(6, 4)
    left = (0...CANVAS).flat_map { |y| right[y * CANVAS, CANVAS].reverse }
    unrelated = right.map { |c| c == INK ? EDGE : c }

    assert_equal sprite_bytes([right, unrelated]) / 2, sprite_bytes([right, left]),
                 "a hand-drawn mirror should be stored once, like a declared one"
    assert_backends_agree(program([right, left]), frames: 12)
  end

  # `mirror` hands back a picture name like any other, so mirroring the same art twice
  # makes one picture rather than two.
  def test_mirroring_the_same_picture_twice_makes_one_picture
    builder = Builder.new
    canvas = CANVAS
    clear = CLEAR
    art = lopsided(6, 4)
    first, second = builder.instance_eval do
      screen :tiled
      image :hero_right, width: canvas, height: canvas, data: art, transparent: clear
      [mirror(:hero_right), mirror(:hero_right)]
    end

    assert_equal first, second
  end

  # A list in, a list out — so a whole direction's frames turn round in one word.
  def test_mirror_turns_a_whole_list_round
    builder = Builder.new
    canvas = CANVAS
    clear = CLEAR
    art = lopsided(6, 4)
    turned = builder.instance_eval do
      screen :tiled
      image :r1, width: canvas, height: canvas, data: art, transparent: clear
      image :r2, width: canvas, height: canvas, data: art.reverse, transparent: clear
      mirror(%i[r1 r2])
    end

    assert_equal 2, turned.length
    assert_kind_of Symbol, turned.first
    refute_equal turned.first, turned.last
  end

  # A POOL TAKES IT TOO, and is the case that most wants it: every slot is a sprite of
  # its own, so a flock facing two ways used to be two sets of pixels shared across all
  # of them. `mirror` reads the same beside `facing:` here as beside a sprite's.
  def test_a_pool_can_face_both_ways_from_one_set_of_pictures
    canvas = CANVAS
    clear = CLEAR
    right = lopsided(6, 4)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :guard_r, width: canvas, height: canvas, data: right, transparent: clear
      guards = pool :guard, x: 0, y: 0, capacity: 4,
                            facing: { right: :guard_r, left: mirror(:guard_r) }
      guards.spawn x: 30, y: 40
      guards.spawn x: 120, y: 40
      game_loop { guards.each { |g| g.face :left } }
    end
    builder.emit_pending_functions

    assert_backends_agree(builder.program, frames: 8)
  end

  def test_mirroring_a_picture_that_is_not_defined_says_so
    builder = Builder.new
    error = assert_raises(ArgumentError) { builder.instance_eval { mirror(:nobody) } }

    assert_match(/:nobody/, error.message)
    assert_match(/not defined/, error.message)
  end

  # A SPRITE THAT TURNS IS NOT MIRRORED. The two attribute bits that reverse an object
  # are the ones that name its rotation group once it is turning, so a turning sprite
  # keeps both sets of pixels — and, more to the point, still draws the right picture.
  def test_a_turning_sprite_with_mirrored_poses_still_draws_correctly
    canvas = CANVAS
    clear = CLEAR
    art = lopsided(6, 4)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :hero_right, width: canvas, height: canvas, data: art, transparent: clear
      hero = sprite :hero, at: [60, 60], frames: [:hero_right, mirror(:hero_right)], rate: 3
      hero.face_angle 30
      game_loop {}
    end
    builder.emit_pending_functions

    assert_backends_agree(builder.program, frames: 12)
  end
end
