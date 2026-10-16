# frozen_string_literal: true

require "test_helper"
require "differential"
require "tmpdir"

# A POOL'S PICTURES GO INTO SPRITE MEMORY THE FIRST TIME ONE OF ITS THINGS SHOWS THEM, not all
# at once when its scene takes over.
#
# A scene's sprite pictures are copied in as it arrives, and the processor waits while they are.
# For a pool that is every pose any of its things could ever show: a pot's shards, an explosion,
# a spark, none of them on screen when the player walks into the room. A game whose arrival pass
# already ran close to the end of its frame lost a whole frame to pictures nobody was looking
# at. The console's own games load an effect's pictures when one is spawned; here each pose goes
# in the first time a thing of the pool shows it.
class TestPoolPicturesSentWhenShown < Minitest::Test
  include Differential

  # Fifteen colours, so every picture is stored the small way (half a byte a pixel).
  INKS = (1..15).map { |i| RubyGBA::Graphics::Color.rgb(i * 2, 31 - (i * 2), 10) }.freeze

  # The names of the eight pictures the pool below can show.
  POSES = (0...8).map { |n| :"shard_#{n}" }.freeze

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

  # THE PICTURE COMES OUT RIGHT on the frame a pose is first shown, for a thing spawned showing
  # it, for a thing turned to another pose, and back in the scene after another scene's picture
  # has gone into the same memory and come out again.
  private def room_with_shards
    program do |t|
      screen :tiled
      POSES.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      # The other scene's pictures fill as much sprite memory as the pool's, so every pose of
      # the pool is written over while it is up.
      banners = (0...8).map { |n| :"banner_#{n}" }
      banners.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(100 + n) }
      state = var :state, 0
      tick = var :tick, 0
      scene(:playing) do
        shards = pool :shard, x: 0, y: 0, look: 0, capacity: 3, facing: POSES.to_h { |name| [name, name] }
        (tick == 2).then { shards.spawn(x: 8, y: 8, look: 0) }
        (tick == 4).then { shards.spawn(x: 96, y: 8, look: 5) }
        shards.each do |shard|
          (tick == 6).then { shard.look.set! 3 }
          shard.face POSES, showing: shard.look
        end
      end
      scene(:away) { sprite :banner, at: [8, 8], frames: banners, rate: 60 }
      game_loop do
        tick.add! 1
        (tick == 8).then { state.set! 1 }
        (tick == 11).then { state.set! 0 }
        case_var(:state) { when_val 0, :playing; when_val 1, :away }
      end
    end
  end

  def test_a_pose_shows_right_the_first_time_a_thing_shows_it
    prog = room_with_shards
    [3, 5, 7].each { |frames| assert_backends_agree(prog, frames: frames, name: "SHARD") }
  end

  def test_a_pose_shows_right_back_in_the_scene_after_another_scene_used_the_memory
    prog = room_with_shards
    [9, 12, 13].each { |frames| assert_backends_agree(prog, frames: frames, name: "SHARD") }
  end

  # A 96x48 picture whose drawn part runs from +from+ along to the far corner. Drawn whole it is
  # wider than the largest piece the console draws, so it is cut into several; a small one is one.
  def corner_art(number, from)
    (0...48).flat_map do |y|
      (0...96).map do |x|
        next :transparent if x < from + 48 || y < from

        INKS[((x * 5) + (y * 3) + number) % 15]
      end
    end
  end

  # POSES CUT INTO DIFFERENT NUMBERS OF PIECES. A pose of fewer pieces than the pool's largest is
  # filled out with blank ones, which draw a blank tile kept at the end of the pool's pictures —
  # so that tile has to be in sprite memory too, even though no pose's own run of tiles holds it.
  # The game opens on another scene, so the memory the pool lands in holds that scene's pictures
  # rather than nothing.
  private def room_of_ragged_poses
    program do |t|
      screen :tiled
      # The small one is drawn in the far corner, so the blank pieces, which stand at the near
      # corner, are not under it.
      image :whole, width: 96, height: 48, data: t.corner_art(0, -48), transparent: true
      image :small, width: 96, height: 48, data: t.corner_art(1, 32), transparent: true
      banners = (0...8).map { |n| :"banner_#{n}" }
      banners.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(100 + n) }
      state = var :state, 1
      tick = var :tick, 0
      scene(:playing) do
        things = pool :thing, x: 0, y: 0, look: 0, capacity: 2, facing: { whole: :whole, small: :small }
        (tick == 4).then do
          things.spawn(x: 8, y: 8, look: 1)
          things.spawn(x: 96, y: 8, look: 0)
        end
        things.each { |thing| thing.face %i[whole small], showing: thing.look }
      end
      scene(:away) { sprite :banner, at: [8, 8], frames: banners, rate: 60 }
      game_loop do
        tick.add! 1
        (tick == 3).then { state.set! 0 }
        case_var(:state) { when_val 0, :playing; when_val 1, :away }
      end
    end
  end

  def test_a_pose_of_fewer_pieces_shows_nothing_where_its_blank_pieces_are
    prog = room_of_ragged_poses
    [6, 7].each { |frames| assert_backends_agree(prog, frames: frames, name: "RAGGED") }
  end

  # THE SCENE'S ARRIVAL DOES NOT WAIT FOR POSES NOTHING SHOWS. Two games whose play scene holds
  # a pool that nothing is spawned into: one pool can show one picture, the other all eight,
  # which is fourteen kilobytes more for the arrival to copy if it copied them. The console is
  # as busy over the first frames either way.
  #
  # Asked of the emulator's own count of the cycles the game was awake, because the copy stops
  # the processor and runs no instructions: a count of instructions, or of the share of a frame
  # left over, would not see it. Copying the seven poses is over twenty thousand cycles; what the
  # bigger pool adds besides is its table and a few more bytes to clear, a few dozen.
  private def empty_room(poses)
    program do |t|
      screen :tiled
      poses.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      var :state, 0
      scene(:playing) do
        shards = pool :shard, x: 0, y: 0, look: 0, capacity: 3, facing: poses.to_h { |name| [name, name] }
        shards.each { |shard| shard.face poses, showing: shard.look }
      end
      scene(:away) {}
      game_loop { case_var(:state) { when_val 0, :playing; when_val 1, :away } }
    end
  end

  private def awake_cycles(prog)
    require_emulator!
    Dir.mktmpdir do |dir|
      path = File.join(dir, "room.gba")
      assemble_rom(prog, name: "ROOM").write(path)
      probe = RubyGBA::Diagnostics::Emulator.probe(path)
      begin
        probe.profile(frames: 3, settle: 0).cycles.values.sum
      ensure
        probe.close
      end
    end
  end

  def test_the_arrival_does_not_copy_poses_nothing_shows
    one = awake_cycles(empty_room(POSES.first(1)))
    eight = awake_cycles(empty_room(POSES))

    assert_operator eight - one, :<, 2_000,
                    "seven more 64x64 poses cost the arrival next to nothing while nothing shows them"
  end
end
