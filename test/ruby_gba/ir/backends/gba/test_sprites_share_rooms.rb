# frozen_string_literal: true

require "test_helper"
require "differential"

# THE THINGS OF A POOL KEPT TO ONE FRAME AT A TIME SHARE THEIR ROOMS BY POSE.
#
# When a pool's pictures do not fit in sprite memory, it is given a room of one frame for each
# thing it can hold, and a pose is copied into a room when a thing shows it. Two things showing
# the same pose draw from one room, so the pose is copied once, and a pose let go of stays in
# its room until another pose needs the room.
class TestSpritesShareRooms < Minitest::Test
  include Differential

  # Fifteen colours, so every picture is stored the small way (half a byte a pixel).
  INKS = (1..15).map { |i| RubyGBA::Graphics::Color.rgb(i * 2, 31 - (i * 2), 10) }.freeze

  # Twenty 64x64 pictures are 40K, more than sprite memory holds, so the pool is kept to one
  # frame at a time.
  POSES = (0...20).map { |n| :"shard_#{n}" }.freeze

  # A 64x64 picture filling its square and differing from every other: a slanted stripe pattern
  # shifted by the picture's number, with the number written along the top row.
  def big_art(number)
    (0...64).flat_map do |y|
      (0...64).map do |x|
        next INKS[(number >> (x % 8)) & 1] if y.zero?

        INKS[((x * 5) + (y * 3) + number) % 15]
      end
    end
  end

  # A program built through the DSL; the block is handed this test, for its pictures.
  private def program(&block)
    b = Builder.new
    b.instance_exec(self, &block)
    b.finalize_program
    b.program
  end

  # Three things: two showing one pose, and one showing another.
  private def two_alike_and_one_not
    program do |t|
      screen :tiled
      POSES.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      tick = var :tick, 0
      shards = pool :shard, x: 0, y: 0, look: 0, capacity: 3, facing: POSES.to_h { |name| [name, name] }
      game_loop do
        tick.add! 1
        (tick == 2).then do
          shards.spawn(x: 0, y: 8, look: 2)
          shards.spawn(x: 80, y: 8, look: 2)
          shards.spawn(x: 160, y: 8, look: 7)
        end
        shards.each { |shard| shard.face POSES, showing: shard.look }
      end
    end
  end

  def test_two_things_showing_one_pose_draw_from_one_room
    v = assert_emulator_loads_rom(assemble_rom(two_alike_and_one_not, name: "ROOMS"), frames: 6)
    tiles = v.sprites(:shard).to_h { |row| [row.x, row.tile] }

    assert_equal [0, 80, 160], tiles.keys.sort, "all three things are drawn"
    assert_equal tiles[0], tiles[80], "the two things showing one pose draw from one room"
    refute_equal tiles[0], tiles[160], "the thing showing another pose draws from a room of its own"
  end

  # Things that spawn, share a pose, change pose, are removed, and spawn again into a room a pose
  # was let go of in, with more different poses over the run than there are rooms; and then the
  # game leaves for a scene whose pictures go into the same memory, and comes back.
  private def busy_room
    program do |t|
      screen :tiled
      POSES.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      banners = (0...8).map { |n| :"banner_#{n}" }
      banners.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(100 + n) }
      state = var :state, 0
      tick = var :tick, 0
      scene(:playing) do
        shards = pool :shard, x: 0, y: 0, look: 0, capacity: 3, facing: POSES.to_h { |name| [name, name] }
        (tick == 2).then do
          shards.spawn(x: 0, y: 8, look: 1)
          shards.spawn(x: 80, y: 8, look: 1)
          shards.spawn(x: 160, y: 8, look: 4)
        end
        (tick == 7).then { shards.spawn(x: 80, y: 80, look: 1) }
        shards.each do |shard|
          ((tick == 4) & (shard.x == 0)).then { shard.look.set! 5 }
          ((tick == 6) & (shard.x == 80)).then { shard.remove }
          ((tick == 9) & (shard.x == 160)).then { shard.look.set! 9 }
          ((tick == 9) & (shard.y == 80)).then { shard.look.set! 12 }
          ((tick == 10) & (shard.x == 0)).then { shard.look.set! 4 }
          shard.face POSES, showing: shard.look
        end
      end
      scene(:away) { sprite :banner, at: [8, 8], frames: banners, rate: 60 }
      game_loop do
        tick.add! 1
        (tick == 12).then { state.set! 1 }
        (tick == 15).then { state.set! 0 }
        case_var(:state) { when_val 0, :playing; when_val 1, :away }
      end
    end
  end

  def test_things_sharing_rooms_are_drawn_as_the_game_means
    prog = busy_room
    [3, 5, 7, 8, 10, 11].each { |frames| assert_backends_agree(prog, frames: frames, name: "BUSY") }
  end

  def test_things_sharing_rooms_are_drawn_as_the_game_means_back_from_another_scene
    prog = busy_room
    [14, 16, 17].each { |frames| assert_backends_agree(prog, frames: frames, name: "BUSY") }
  end

  # --- what the report says ---

  # A pool of three things that can show +poses+ 64x64 pictures, in a game built through the DSL.
  private def pool_game(poses)
    art = method(:big_art)
    names = POSES.first(poses)
    RubyGBA.build("ROOMS", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      names.each_with_index { |name, n| image name, width: 64, height: 64, data: art.call(n) }
      shards = pool :shard, x: 0, y: 0, look: 0, capacity: 3, facing: names.to_h { |name| [name, name] }
      game_loop { shards.each { |shard| shard.face names, showing: shard.look } }
    end
  end

  private def report_for(rom)
    out = StringIO.new
    RubyGBA::Diagnostics::BuildReport.render(rom, out: out)
    out.string
  end

  # A game with no scenes has one screen, what every screen shows.
  private def only_screen(rom)
    screens = rom.built.video_memory.sprites.screens
    assert_equal [nil], screens.map(&:scene)
    screens.first
  end

  def test_the_report_says_what_the_shared_rooms_take
    screen = only_screen(pool_game(20))

    assert_equal 3 * 2048, screen.room_bytes, "a room of one 64x64 frame for each of the three things"
    assert_equal 0, screen.fixed, "...and nothing else"
    assert_equal 3 * 2048, screen.least_needed, "...which is the least the game could need"
  end

  # Eight poses fit, so the pool is kept whole and copies nothing as it plays. The report still
  # says how little it could come to: that is how far from the wall a growing game really is.
  def test_the_report_says_the_least_a_pool_kept_whole_could_need
    rom = pool_game(8)
    screen = only_screen(rom)

    assert_equal 8 * 2048, screen.used
    assert_equal 0, screen.room_bytes
    assert_equal 3 * 2048, screen.least_needed, "a room of one frame for each of the three things"
    assert_match(/need 6\.0K at the least/, report_for(rom))
  end

  # A scene of still pictures that is the fullest, and a scene with a pool that fits whole. The
  # least is said for each scene, and the play scene's is the one a growing game needs to see.
  private def menu_and_play
    art = method(:big_art)
    names = POSES.first(8)
    statues = POSES.last(12)
    RubyGBA.build("ROOMS", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      POSES.each_with_index { |name, n| image name, width: 64, height: 64, data: art.call(n) }
      var :state, 0
      scene(:playing) do
        shards = pool :shard, x: 0, y: 0, look: 0, capacity: 3, facing: names.to_h { |name| [name, name] }
        shards.each { |shard| shard.face names, showing: shard.look }
      end
      scene(:menu) { statues.each_with_index { |name, n| sprite name, at: [n * 8, 40] } }
      game_loop { case_var(:state) { when_val 0, :playing; when_val 1, :menu } }
    end
  end

  def test_the_report_says_the_least_each_scene_could_need
    rom = menu_and_play
    screens = rom.built.video_memory.sprites.screens.to_h { |screen| [screen.scene, screen] }

    assert_equal 8 * 2048, screens.fetch(:playing).used
    assert_equal 3 * 2048, screens.fetch(:playing).least_needed, "the play scene, not only the fullest"
    assert_equal 12 * 2048, screens.fetch(:menu).least_needed, "still pictures have no frames to give up"
    assert_match(/scene :playing .*need 6\.0K at the least/, report_for(rom))
  end

  # A 48x48 picture whose drawn part grows from the corner with its number, so no two are cut
  # into the same pieces, and each is bigger than any one picture the console draws.
  def growing_art(number)
    reach = 16 + (number % 33)
    (0...48).flat_map do |y|
      (0...48).map do |x|
        next :transparent if x >= reach || y >= reach

        INKS[((x * 5) + (y * 3) + number) % 15]
      end
    end
  end

  # Two things walking through poses cut into different pieces, a pose apart, so they show the
  # same pose on no frame, and then the same one on every frame.
  private def giants
    poses = (0...64).map { |n| :"giant_#{n}" }
    program do |t|
      screen :tiled
      poses.each_with_index { |name, n| image name, width: 48, height: 48, data: t.growing_art(n), transparent: true }
      tick = var :tick, 0
      walkers = pool :giant, x: 0, y: 0, look: 0, capacity: 2, facing: poses.to_h { |name| [name, name] }
      game_loop do
        tick.add! 1
        (tick == 1).then do
          walkers.spawn(x: 8, y: 8, look: 0)
          walkers.spawn(x: 120, y: 8, look: 1)
        end
        walkers.each do |giant|
          giant.look.set!((giant.look + 1) % 64)
          ((tick == 6) & (giant.x == 120)).then { giant.look.set! 6 }
          giant.face poses, showing: giant.look
        end
      end
    end
  end

  private def sprite_memory_of(prog)
    backend = GBA.new
    backend.lower(prog)
    backend.build_record(prog).video_memory.sprites
  end

  def test_things_sharing_rooms_with_poses_cut_into_pieces_are_drawn_as_the_game_means
    prog = giants
    assert_equal 2, sprite_memory_of(prog).one_frame,
                 "the giants' poses do not fit, so both things keep one frame at a time"
    [3, 5, 8, 10].each { |frames| assert_backends_agree(prog, frames: frames, name: "GIANTS") }
  end

  # Not a pool: two sprites the author declared, showing the same frames at different rates, so
  # they show the same pose on some frames and different ones on others.
  private def two_dancers
    program do |t|
      screen :tiled
      POSES.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      sprite :left, at: [8, 8], frames: POSES, rate: 1
      sprite :right, at: [120, 8], frames: POSES, rate: 2
      game_loop {}
    end
  end

  # The same pictures in a different order: stored once whole, but pose 1 of one is not pose 1 of
  # the other, so a room holding one's pose 1 must not be drawn from as the other's.
  private def same_pictures_in_another_order
    program do |t|
      screen :tiled
      POSES.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      sprite :left, at: [8, 8], frames: POSES + [POSES.last], rate: 1
      sprite :right, at: [120, 8], frames: [POSES.first] + POSES, rate: 1
      game_loop {}
    end
  end

  def test_sprites_showing_the_same_pictures_in_another_order_draw_their_own_poses
    [3, 4, 7].each { |frames| assert_backends_agree(same_pictures_in_another_order, frames: frames, name: "ORDER") }
  end

  def test_two_sprites_the_author_declared_share_rooms_too
    prog = two_dancers
    assert_equal 2 * 2048, sprite_memory_of(prog).screens.sum(&:room_bytes), "a room of one frame each"
    [3, 4, 7, 10].each { |frames| assert_backends_agree(prog, frames: frames, name: "DANCERS") }
  end
end
