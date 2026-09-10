# frozen_string_literal: true

require "test_helper"
require "differential"

# A PART ONE POSE SHARES WITH ANOTHER IS STORED ONCE.
#
# Most of a character does not change between two frames of a walk — the head, the
# torso, the arm that is not moving — and a sprite's poses are stored as PIECES, each
# naming its own first tile. So the pieces that did not change are stored once and
# every frame points at them.
#
# This is the one saving a game written straight against the console cannot have. An
# object reads a CONTIGUOUS run of tiles, so by hand every frame has to be its own run
# and a part that did not move is kept again in each. A table of pieces is under no
# such rule.
#
# The art here is NOISE, seeded so it is the same on every run. Noise because anything
# regular shares by accident — a solid block cut into cells gives cell after cell of
# identical bytes — and then a test would pass without the sharing doing any work.
class TestSpriteTileSharing < Minitest::Test
  include Differential

  CLEAR = RubyGBA::Color.rgb(0, 0, 1)
  INK = RubyGBA::Color.rgb(31, 20, 0)
  INK2 = RubyGBA::Color.rgb(0, 31, 10)

  # A +size+-square picture of noise, +seed+ deciding the pattern.
  def noise(size, seed, ink = INK)
    rng = Random.new(seed)
    Array.new(size * size) { rng.rand(4).zero? ? CLEAR : ink }
  end

  # A creature on a +canvas+-square sheet: a torso over legs, both noise, with a border
  # of nothing around them so the picture is ragged and gets cut into several objects.
  # +still_torso+ is the whole question — a torso that is the same in every frame is
  # what a walk cycle has, and it is what there is to share.
  def creature(canvas, step, still_torso:)
    torso = Random.new(still_torso ? 1 : 500 + step)
    legs = Random.new(1000 + step)
    (0...(canvas * canvas)).map do |i|
      x = i % canvas
      y = i / canvas
      next CLEAR unless x >= 8 && x < canvas - 8 && y >= 8 && y < canvas - 8

      picked = y < canvas / 2 ? torso : legs
      picked.rand(4).zero? ? CLEAR : (y < canvas / 2 ? INK : INK2)
    end
  end

  # A program whose one sprite cycles +art+ (pictures of +canvas+ square).
  def cycling(art, canvas, rate: 4)
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      names = art.each_with_index.map do |data, k|
        n = :"pose#{k}"
        image n, width: canvas, height: canvas, data: data, transparent: clear
        n
      end
      sprite :hero, at: [40, 30], frames: names, rate: rate
      game_loop {}
    end
    b.emit_pending_functions
    b.program
  end

  # ...and the same through RubyGBA.build, which is where the sprite-memory figure is.
  def sprite_bytes(art, canvas, rate: 4)
    clear = CLEAR
    rom = RubyGBA.build("SHARE", code: "BSHR", maker: "01", validate: false,
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
    rom.built.video_memory.sprites.used
  end

  # How many instructions a program lowers to — the only way a test can see WHICH draw
  # a sprite got, since the two draw the same picture and differ only in what they cost.
  def emitted(program)
    backend = RubyGBA::IR::Backends::GBA.new
    backend.lower(program)
    backend.instance_variable_get(:@emit).code.length
  end

  # ---- a whole pose that repeats ----

  # A ping-pong cycle: [a, b, c, b] is how a great many animations are written — a
  # wing, a pendulum, a torch — and the middle frame used to be stored twice.
  PING_PONG = %i[a b c b].freeze

  def ping_pong_art
    made = { a: noise(32, 11), b: noise(32, 12), c: noise(32, 13) }
    PING_PONG.map { |which| made.fetch(which) }
  end

  def test_a_ping_pong_cycle_stores_its_repeated_frame_once
    three = sprite_bytes(ping_pong_art, 32)
    four = sprite_bytes(%i[a b c d].map { |k| noise(32, 10 + k.to_s.ord) }, 32)

    assert_equal (four / 4) * 3, three,
                 "[a b c b] should cost three pictures, where [a b c d] costs four"
  end

  # THE PICTURE IS UNCHANGED, which is the whole bargain. The interpreter draws every
  # pose from its own image and knows nothing about which tiles the console shares, so
  # the two agreeing is the proof that sharing moved nothing.
  #
  # WHICH FRAME IS COMPARED IS THE WHOLE TEST, since only the last one is. At rate 4 a
  # cycle of four poses turns over every 16 frames, and the sprite is put on screen
  # from the pose it held at the top of the pass — so what is showing after 32 frames
  # is the FOURTH pose, the one that repeats the second. Compared at any other moment,
  # a sprite reading its repeated pose from the wrong place passes.
  REPEATED_POSE_SHOWING = 32
  OWN_POSE_SHOWING = 28

  def test_a_ping_pong_cycle_draws_its_repeated_pose_the_same_on_both_backends
    assert_backends_agree(cycling(ping_pong_art, 32), frames: REPEATED_POSE_SHOWING, name: "PPONG")
  end

  # ...and the third pose, which is stored in its own right, to show the ones around
  # the repeat did not move either.
  def test_a_ping_pong_cycle_draws_its_own_poses_the_same_on_both_backends
    assert_backends_agree(cycling(ping_pong_art, 32), frames: OWN_POSE_SHOWING, name: "PPONG3")
  end

  # A FOUR-WAY CHARACTER WITH A REST FRAME IN EVERY DIRECTION, which is what art
  # exported from a drawing tool commonly looks like — and how Pac-Man is drawn, whose
  # shut mouth is the same disc whichever way he faces.
  def four_way(rest_shared:)
    clear = CLEAR
    poses = { rest: noise(16, 21), left: noise(16, 22), right: noise(16, 23),
              up: noise(16, 24), down: noise(16, 25) }
    apart = { left: noise(16, 31), right: noise(16, 32), up: noise(16, 33), down: noise(16, 34) }
    rom = RubyGBA.build("FOUR", code: "BFOU", maker: "01", validate: false,
                        out: StringIO.new, err: StringIO.new) do
      screen :tiled
      poses.each { |name, data| image name, width: 16, height: 16, data: data, transparent: clear }
      apart.each { |name, data| image :"still_#{name}", width: 16, height: 16, data: data, transparent: clear }
      sprite :hero, at: [40, 30], rate: 4,
                    facing: %i[left right up down].to_h { |dir|
                      [dir, [rest_shared ? :rest : :"still_#{dir}", dir]]
                    }
      game_loop {}
    end
    rom.built.video_memory.sprites.used
  end

  def test_a_four_way_character_stores_a_shared_rest_frame_once
    shared = four_way(rest_shared: true)
    apart = four_way(rest_shared: false)

    assert_equal (apart / 8) * 5, shared,
                 "one rest frame shared four ways should cost five pictures, not eight"
  end

  # ---- a PIECE that repeats, which is the case a whole-pose test cannot reach ----

  # Eight frames of a 96x96 creature: every frame is different, so nothing here is a
  # repeated pose. What repeats is the torso, which is several pieces of every frame.
  def walk(still_torso:, frames: 8)
    (0...frames).map { |k| creature(96, k, still_torso: still_torso) }
  end

  def test_a_cycle_stores_the_part_that_does_not_move_once
    still = sprite_bytes(walk(still_torso: true), 96)
    moving = walk(still_torso: false)

    # The moving-torso cycle has nothing to share and does not fit at all, which is the
    # point: what it needs is the figure the still-torso cycle would have cost too.
    err = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { sprite_bytes(moving, 96) }
    wanted = err.message[/(\d+) bytes at once/, 1].to_i

    assert_operator still, :<, wanted * 3 / 4,
                    "a torso that stands still through eight frames should give back a quarter and more"
  end

  # A CYCLE THAT DID NOT FIT NOW DOES, which is why this is worth having at all: sprite
  # memory is a wall a build hits rather than a frame that runs slowly. The two cycles
  # here are the same size, cut the same way, into the same number of objects — the
  # only difference is whether there is anything to share.
  def test_a_cycle_that_did_not_fit_now_builds
    assert_operator sprite_bytes(walk(still_torso: true), 96), :<, 32 * 1024
    assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { sprite_bytes(walk(still_torso: false), 96) }
  end

  # Four frames rather than the eight above: a sprite drawn as nine objects over 26K of
  # art takes long enough to set up that a longer run drifts a pass behind the console,
  # and what is under test here is the picture rather than the budget.
  def test_a_big_shared_cycle_draws_the_same_on_both_backends
    assert_backends_agree(cycling(walk(still_torso: true, frames: 4), 96), frames: 12, name: "BIGSHR")
  end

  # ---- the two edges ----

  # A cycle whose frames are ALL the same picture shares one run between every pose,
  # which is an even distance of NOTHING — so it keeps the plain draw rather than
  # falling to the pose table. The stride is then 0 and every pose reads the same
  # tiles, which is exactly right and is the one case where reading the stride off the
  # poses matters instead of dividing the total by how many there are.
  def test_a_cycle_of_one_picture_shares_it_and_stays_on_the_plain_draw
    one = noise(32, 41)
    clear = CLEAR
    still = RubyGBA.build("ONE", code: "BONE", maker: "01", validate: false,
                          out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image :hero, width: 32, height: 32, data: one, transparent: clear
      sprite :hero, at: [40, 30]
      game_loop {}
    end

    assert_equal still.built.video_memory.sprites.used, sprite_bytes(Array.new(6) { one }, 32),
                 "six copies of one picture should cost one picture"
    assert_backends_agree(cycling(Array.new(6) { one }, 32), frames: 24, name: "SAME6")

    # Which draw it got is a fact about speed, so the only thing that can see it from
    # out here is the size of the code. Six of one picture keeps the plain draw; six
    # where one repeats an earlier one cannot, and carries the table.
    mixed = [one, noise(32, 42), noise(32, 43), noise(32, 42), noise(32, 44), noise(32, 45)]

    assert_operator emitted(cycling(Array.new(6) { one }, 32)), :<, emitted(cycling(mixed, 32)),
                    "a cycle of one picture should keep the plain draw"
  end

  # A REPEAT AND A MIRROR IN ONE CYCLE. A pose that repeats an earlier one shares its
  # tiles with no flip; a pose that is an earlier one BACKWARDS shares them with one.
  # Both point back into the same run, so the two have to agree about where it is.
  def mixed_cycle
    clear = CLEAR
    art = [noise(32, 51), noise(32, 52)]
    b = Builder.new
    b.instance_eval do
      screen :tiled
      art.each_with_index { |d, k| image :"p#{k}", width: 32, height: 32, data: d, transparent: clear }
      sprite :hero, at: [40, 30], rate: 4, frames: [:p0, :p1, mirror(:p0), :p1].flatten
      game_loop {}
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_mirrored_pose_beside_a_repeat_draws_the_same_on_both_backends
    assert_backends_agree(mixed_cycle, frames: OWN_POSE_SHOWING, name: "MIXMIR") # the mirror
  end

  def test_a_repeat_beside_a_mirrored_pose_draws_the_same_on_both_backends
    assert_backends_agree(mixed_cycle, frames: REPEATED_POSE_SHOWING, name: "MIXREP")
  end

  # ---- what the build says it saved ----

  # Nothing in the program says which parts of two poses are the same, so the profile
  # is the only place the number can appear.
  def test_the_profile_says_what_sharing_saved
    clear = CLEAR
    art = ping_pong_art
    rom = RubyGBA.build("SHARE", code: "BSHR", maker: "01", validate: false,
                        out: StringIO.new, err: StringIO.new) do
      screen :tiled
      art.each_with_index { |d, k| image :"p#{k}", width: 32, height: 32, data: d, transparent: clear }
      sprite :hero, at: [40, 30], rate: 4, frames: (0...art.length).map { |k| :"p#{k}" }
      game_loop {}
    end
    out = StringIO.new
    RubyGBA::BuildReport.render(rom, out: out)

    assert_match(/saved where poses share a part/, out.string)
  end
end
