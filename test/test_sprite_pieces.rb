# frozen_string_literal: true

require "test_helper"
require "differential"

# A SPRITE CAN BE BIGGER THAN THE CONSOLE'S LARGEST OBJECT.
#
# The console draws twelve rectangles and the largest is 64x64, so a boss, a vehicle, a
# title-screen character used to have to be hand-assembled out of several sprite handles
# the game then moved in step. Nothing about the hardware requires that — several objects
# standing shoulder to shoulder look exactly like one big one — so the framework cuts the
# picture up and moves the pieces itself.
#
# WHAT CAN GO WRONG IS THE PLACE, not the pixels: a piece put one cell out, or a mirrored
# piece reflected about the wrong middle, still draws a plausible-looking picture. So
# nearly every test here compares the two backends pixel for pixel — the interpreter draws
# the whole picture at once and knows nothing about pieces, which makes it the answer key.
class TestSpritePieces < Minitest::Test
  include Differential

  # Seven colors laid out by tile, so a piece drawn in the wrong place shows as a color
  # out of order rather than as a shape that happens to look similar.
  INKS = [
    RubyGBA::Color.rgb(31, 0, 0), RubyGBA::Color.rgb(0, 31, 0), RubyGBA::Color.rgb(0, 0, 31),
    RubyGBA::Color.rgb(31, 31, 0), RubyGBA::Color.rgb(31, 0, 31), RubyGBA::Color.rgb(0, 31, 31),
    RubyGBA::Color.rgb(31, 31, 31),
  ].freeze
  CLEAR = RubyGBA::Color.rgb(1, 1, 1)

  # A ragged character on a +w+ by +h+ canvas: an ellipse of +fill+ across, so the corners
  # of the canvas are empty and the pieces that cover them can be dropped.
  def ragged(w, h, fill: 0.95)
    cx = w / 2.0
    cy = h / 2.0
    (0...(w * h)).map do |i|
      x = i % w
      y = i / w
      dx = (x - cx) / cx
      dy = (y - cy) / cy
      next CLEAR if (dx * dx) + (dy * dy) > fill

      INKS[(((x / 8) + ((y / 8) * 3)) % INKS.size)]
    end
  end

  # A small blob in the top-left corner of a +w+ by +h+ canvas — a pose that draws far
  # less than its canvas, so it needs fewer pieces than one that fills it.
  def corner_blob(w, h, side: 16)
    (0...(w * h)).map do |i|
      x = i % w
      y = i / w
      x < side && y < side ? INKS[2] : CLEAR
    end
  end

  # A program cycling one sprite through these pictures. +mirror_second+ adds each one
  # turned round, so the cycle plays the character both ways.
  def program(pictures, w, h, at: [40, 20], rate: 4, mirror_second: false)
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      names = pictures.each_with_index.map do |data, k|
        n = :"pose#{k}"
        image n, width: w, height: h, data: data, transparent: clear
        n
      end
      names += mirror(names) if mirror_second
      sprite :big, at: at, frames: names, rate: rate
      game_loop {}
    end
    b.emit_pending_functions
    b.program
  end

  # A program showing exactly one picture, whose sprite is named after it.
  def still(picture, w, h, at: [40, 20])
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :big, width: w, height: h, data: picture, transparent: clear
      sprite :big, at: at
      game_loop {}
    end
    b.emit_pending_functions
    b.program
  end

  # The build record for a program, which is where the sprite-memory and object figures
  # live. Lowered here rather than through RubyGBA.build so a program built by hand works.
  def record(prog)
    backend = RubyGBA::IR::Backends::GBA.new
    backend.lower(prog)
    backend.build_record(prog)
  end

  # ---- the picture ----

  def test_a_picture_bigger_than_the_largest_object_draws_the_same_on_both_backends
    assert_backends_agree(still(ragged(96, 96), 96, 96), frames: 4, name: "BIG96")
  end

  def test_a_picture_wider_than_the_largest_object_draws_the_same
    assert_backends_agree(still(ragged(128, 64), 128, 64, at: [50, 40]), frames: 4, name: "BIGWIDE")
  end

  def test_a_picture_taller_than_the_largest_object_draws_the_same
    assert_backends_agree(still(ragged(64, 128), 64, 128, at: [80, 10]), frames: 4, name: "BIGTALL")
  end

  # 24x24 is smaller than the largest object and still not one of the twelve rectangles
  # the console has. It used to be a build error; it is now three pieces.
  def test_a_picture_that_is_not_one_of_the_hardware_sizes_draws_the_same
    assert_backends_agree(still(ragged(24, 24), 24, 24, at: [100, 60]), frames: 4, name: "ODD24")
  end

  # A piece that falls off the left or top edge of the screen has to be clipped by the
  # console the same way the interpreter clips the whole picture.
  def test_a_big_sprite_hanging_off_the_edge_draws_the_same
    assert_backends_agree(still(ragged(96, 96), 96, 96, at: [-30, -20]), frames: 4, name: "BIGEDGE")
  end

  # ---- it is one thing ----

  # Every piece follows the sprite's own x/y, so a move carries the whole picture. It
  # takes a fixed number of steps and then holds, so a run of one more pass on the console
  # than in the interpreter still ends with the sprite in the same place.
  def test_a_big_sprite_moves_as_one_thing
    art = ragged(96, 96)
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :big, width: 96, height: 96, data: art, transparent: clear
      hero = sprite :big, at: [20, 20]
      step = var :step, 0
      game_loop do
        (step < 4).then do
          hero.move 8, 5
          step.add 1
        end
      end
    end
    b.emit_pending_functions

    assert_backends_agree(b.program, frames: 8, name: "BIGMOVE")
  end

  # Poses that need DIFFERENT numbers of pieces: one fills the canvas, one is a blob in
  # the corner. The short pose is filled out with pieces that draw nothing, so the frame
  # never has to test how many there are — and the picture must show only the blob.
  def test_poses_that_need_different_numbers_of_pieces_draw_the_same
    prog = program([ragged(96, 96), corner_blob(96, 96)], 96, 96, rate: 4)

    assert_backends_agree(prog, frames: 8, name: "BIGCYCLE")
  end

  # The padded pose on its own, held still, so the blank pieces are what is on screen for
  # the whole run rather than for part of a cycle.
  def test_a_pose_padded_with_blank_pieces_shows_only_what_it_draws
    b = RubyGBA::IR::Build
    clear = CLEAR
    prog = b.program(
      b.screen(:tiled),
      b.bitmap(:full, width: 96, height: 96, pixels: ragged(96, 96).pack("v*"), transparent: clear),
      b.bitmap(:blob, width: 96, height: 96, pixels: corner_blob(96, 96).pack("v*"), transparent: clear),
      b.object(:big, poses: %i[full blob], pose: b.int(1),
                     x: b.int(40), y: b.int(20), active: b.int(1)),
      b.loop_(b.wait_vblank, b.present_objects([:big]))
    )

    assert_backends_agree(prog, frames: 4, name: "BIGPAD")
  end

  # A big sprite facing the other way is the same pieces reflected about the CANVAS, not
  # about each piece's own middle — get that wrong and the character turns inside out.
  # `face` picks the direction so the compared frame is a known one rather than wherever
  # a cycle happened to land.
  def facing_game(look)
    art = ragged(96, 96, fill: 0.6)
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :big_right, width: 96, height: 96, data: art, transparent: clear
      hero = sprite :big, at: [40, 20], facing: { right: :big_right, left: mirror(:big_right) }
      game_loop { hero.face look }
    end
    b.emit_pending_functions
    b
  end

  def test_a_big_sprite_faces_the_way_it_was_drawn
    assert_backends_agree(facing_game(:right).program, frames: 6, name: "BIGRIGHT")
  end

  def test_a_big_sprite_faces_the_other_way_by_mirroring
    assert_backends_agree(facing_game(:left).program, frames: 6, name: "BIGLEFT")
  end

  # ...and the mirrored direction keeps no pixels of its own, exactly as it does for a
  # picture small enough to be one object.
  def test_a_mirrored_direction_of_a_big_sprite_stores_nothing
    both_ways = record(facing_game(:left).program).video_memory.sprites.used
    one_way = record(still(ragged(96, 96, fill: 0.6), 96, 96)).video_memory.sprites.used

    assert_equal one_way, both_ways,
                 "facing both ways should cost what facing one way costs"
  end

  # Two sprites, one big, one small, stacked: the big one's pieces all sit at its own
  # depth, so the small one is in front of the whole of it rather than of part of it.
  def test_a_big_sprite_keeps_one_place_in_the_stack
    art = ragged(96, 96)
    dot = Array.new(16 * 16, INKS[6])
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :big, width: 96, height: 96, data: art, transparent: clear
      image :dot, width: 16, height: 16, data: dot, transparent: clear
      sprite :big, at: [40, 20]
      sprite :dot, at: [80, 60] # declared later, so in front of the whole big one
      game_loop {}
    end
    b.emit_pending_functions

    assert_backends_agree(b.program, frames: 4, name: "BIGSTACK")
  end

  # A big sprite collides on its whole picture, not on the one piece the console happened
  # to draw first. The answer is shown rather than read out of a variable, so the two
  # backends have to agree about the collision AND about what it makes the game do.
  def collision_game(dot_at)
    art = ragged(96, 96)
    dot = Array.new(16 * 16, INKS[6])
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :big, width: 96, height: 96, data: art, transparent: clear
      image :dot, width: 16, height: 16, data: dot, transparent: clear
      image :flag, width: 16, height: 16, data: dot, transparent: clear
      hero = sprite :big, at: [40, 20]
      pip = sprite :dot, at: dot_at
      flag = sprite :flag, at: [8, 140], shown: false
      game_loop { hero.overlaps?(pip).then { flag.show } }
    end
    b.emit_pending_functions
    b.program
  end

  # Where the flag stands, so a test can read whether the collision fired.
  FLAG_AT = [12, 145].freeze

  def flag_shown?(prog)
    Reference.new.run(prog, frames: 6).screen.pixel(*FLAG_AT) == INKS[6]
  end

  def test_a_big_sprite_collides_across_its_whole_picture
    # (100, 60) is the middle of the hero, well past one 32x32 piece from its corner.
    hit = collision_game([100, 60])

    assert flag_shown?(hit), "the dot is inside the hero's picture, so they collide"
    assert_backends_agree(hit, frames: 6, name: "BIGHITS")
  end

  def test_a_big_sprite_does_not_collide_with_what_it_misses
    miss = collision_game([200, 130])

    refute flag_shown?(miss), "the dot is nowhere near the hero"
    assert_backends_agree(miss, frames: 6, name: "BIGMISS")
  end

  # A fade placed in the stack holds itself off each kept sprite with an invisible twin of
  # it. A sprite drawn as several objects needs a twin per object, or the hole the fade
  # leaves is the shape of only part of the picture.
  def test_a_placed_fade_keeps_the_whole_of_a_big_sprite
    art = ragged(96, 96)
    dot = Array.new(16 * 16, INKS[6])
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :actors, :ui
      image :dot, width: 16, height: 16, data: dot, transparent: clear
      image :big, width: 96, height: 96, data: art, transparent: clear
      layer(:actors) { sprite :dot, at: [20, 120] }
      layer(:ui) { sprite :big, at: [40, 20] }
      game_loop { fade :black, 100, under: :ui }
    end
    b.emit_pending_functions

    assert_backends_agree(b.program, frames: 6, name: "BIGFADE", blended: true)
  end

  def test_the_profile_says_what_the_windows_over_a_big_sprite_cost
    art = ragged(96, 96)
    dot = Array.new(16 * 16, INKS[6])
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :actors, :ui
      image :dot, width: 16, height: 16, data: dot, transparent: clear
      image :big, width: 96, height: 96, data: art, transparent: clear
      layer(:actors) { sprite :dot, at: [20, 120] }
      layer(:ui) { sprite :big, at: [40, 20] }
      game_loop { fade :black, 100, under: :ui }
    end
    b.emit_pending_functions
    objects = record(b.program).video_memory.objects

    big = objects.big.find { |name, _| name == :big }.last

    assert_equal big, objects.twins, "the windows shadow the big sprite object for object"
  end

  # ---- what it costs ----

  # The corners of the canvas draw nothing, and a piece that draws nothing is not stored.
  def test_the_empty_parts_of_a_big_picture_cost_nothing
    thin = record(still(ragged(96, 96, fill: 0.35), 96, 96)).video_memory.sprites.used
    canvas = 96 * 96 / 2 # half a byte a pixel, stored the small way

    assert_operator thin, :<, canvas / 2,
                    "a picture that draws a third of its canvas should not cost the whole of it"
  end

  # A picture the console can draw in one go is still one object — the cutting up is only
  # for a picture that needs it.
  def test_a_picture_the_console_can_draw_in_one_go_is_still_one_object
    assert_nil record(still(ragged(64, 64), 64, 64)).video_memory.objects,
               "a game whose sprites are one object each has nothing to report"
  end

  # 24x24 is not a size the console has, but a 32x32 object holds all of it — so it is cut
  # up into exactly one piece rather than into four.
  def test_a_small_picture_the_console_has_no_size_for_is_still_one_object
    assert_nil record(still(ragged(24, 24, fill: 2.0), 24, 24)).video_memory.objects,
               "a 24x24 picture fits one 32x32 object"
  end

  # That one object overhangs its own picture, so the same picture facing the other way
  # cannot be its reflection — it keeps its own pixels. What must not change is the
  # PICTURE, which is what this checks.
  def test_a_small_odd_picture_faces_both_ways
    art = ragged(24, 24, fill: 2.0)
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :odd_right, width: 24, height: 24, data: art, transparent: clear
      hero = sprite :odd, at: [60, 60], facing: { right: :odd_right, left: mirror(:odd_right) }
      game_loop { hero.face :left }
    end
    b.emit_pending_functions

    assert_backends_agree(b.program, frames: 6, name: "ODDMIRROR")
  end

  def test_the_profile_says_how_many_objects_a_big_sprite_spends
    objects = record(still(ragged(96, 96), 96, 96)).video_memory.objects

    refute_nil objects
    assert_operator objects.used, :>, 1
    assert_equal RubyGBA::Constants::MAX_SPRITES, objects.capacity
    assert_equal [[:big, objects.used]], objects.big
  end

  def test_the_profile_prints_what_a_big_sprite_spends
    art = ragged(96, 96)
    clear = CLEAR
    rom = RubyGBA.build("PIECES", code: "BPIE", maker: "01", validate: false,
                        out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image :big, width: 96, height: 96, data: art, transparent: clear
      sprite :big, at: [40, 20]
      game_loop {}
    end
    out = StringIO.new
    RubyGBA::BuildReport.render(rom, out: out)

    assert_match(/the sprites the console draws at once: \d+ of 128 used/, out.string)
    assert_match(/:big is bigger than one sprite, so it is drawn as \d+/, out.string)
  end

  # ---- friendly errors ----

  def test_a_big_sprite_that_turns_is_a_friendly_error
    art = ragged(96, 96)
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :big, width: 96, height: 96, data: art, transparent: clear
      boss = sprite :big, at: [40, 20]
      game_loop { boss.turn 3 }
    end
    b.emit_pending_functions
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(b.program) }

    assert_match(/:big is 96x96/, err.message)
    assert_match(/turn/, err.message)
  end

  def test_a_picture_too_big_for_any_sprite_is_a_friendly_error
    art = Array.new(320 * 64, INKS[0])
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :huge, width: 320, height: 64, data: art, transparent: clear
      sprite :huge, at: [0, 0]
    end
    b.emit_pending_functions
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(b.program) }

    assert_match(/256 pixels each way at most/, err.message)
    assert_match(/:huge is 320x64/, err.message)
  end

  # Enough big sprites to run the console out of places. The message has to name the
  # sprites that are spending several, since nothing in the program says so.
  def test_running_out_of_places_names_the_sprites_spending_several
    art = ragged(96, 96)
    clear = CLEAR
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :big, width: 96, height: 96, data: art, transparent: clear
      20.times { |k| sprite :"boss#{k}", at: [k * 4, 10], facing: { right: :big } }
    end
    b.emit_pending_functions
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(b.program) }

    assert_match(/draws 128 at most/, err.message)
    assert_match(/:big \(\d+ each\)/, err.message)
  end
end
