# frozen_string_literal: true

require "test_helper"
require "differential"

# A POSE PICKED BY A NUMBER THE GAME WORKS OUT: `hero.face [:a, :b, :c], showing: step`.
# An animation step, a state, a variant of an effect — the pose a game wants is usually a
# number, and written as a test per pose it is code that grows with the poses. This reads the
# pose out of a table instead, so a hundred poses cost what three do.
class TestFaceShowing < Minitest::Test
  include Differential

  # A 16x8 picture with a mark at column +n+, so which pose shows can be told from a pixel.
  def self.marked(n) = Array.new(8) { |row| (0...16).map { |col| col == n && row < 4 ? "#" : "." }.join }.join("\n")

  # A sprite of +count+ poses, each its own direction, picked each frame by a step that
  # walks 0, 1, 2 ... and then past the end.
  private def stepping(count, screen: :tiled)
    proc do
      screen screen
      names = (0...count).map do |n|
        image(:"pose#{n}", "." => :transparent, "#" => :red) { TestFaceShowing.marked(n % 16) }
        :"pose#{n}"
      end
      hero = sprite :hero, at: [40, 40], facing: names.to_h { |name| [name, name] }
      step = var :step, 0
      game_loop do
        hero.face names.reverse, showing: step
        step.add! 1
      end
    end
  end

  private def built(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program
  end

  private def picture_after(frames, count: 4)
    Reference.new.run(built(&stepping(count)), frames: frames).sprites(:hero).first.picture
  end

  def test_the_number_picks_the_pose_and_one_past_the_list_leaves_it
    # The first frame is drawn before the loop has said anything; each pick shows a frame later.
    assert_equal %i[pose0 pose3 pose2 pose1 pose0 pose0], (1..6).map { |frames| picture_after(frames) }
  end

  def test_the_console_shows_the_same_poses
    game = built(&stepping(4))
    (2..6).each { |frames| assert_backends_agree(game, frames: frames) }
  end

  # On a bitmap screen a pose changed by `face` shows a frame apart on the two backends
  # whichever way it is written, so this holds the pick to what a test per pose draws, on
  # each backend.
  def test_a_bitmap_sprite_picks_what_a_test_per_pose_picks
    picked = built(&stepping(4, screen: :bitmap))
    tested = built do
      screen :bitmap
      names = (0...4).map do |n|
        image(:"pose#{n}", "." => :transparent, "#" => :red) { TestFaceShowing.marked(n) }
        :"pose#{n}"
      end
      hero = sprite :hero, at: [40, 40], facing: names.to_h { |name| [name, name] }
      step = var :step, 0
      game_loop do
        names.reverse.each_with_index { |name, n| (step == n).then { hero.face name } }
        step.add! 1
      end
    end
    (2..5).each do |frames|
      assert_equal backend_pictures(tested, frames: frames), backend_pictures(picked, frames: frames), "frame #{frames}"
    end
  end

  # The line that picks costs the same whatever the number of poses; only the table grows.
  def test_a_hundred_poses_cost_the_code_of_ten
    sizes = [10, 100].map do |count|
      rom = RubyGBA.build("FACE#{count}", out: StringIO.new, err: StringIO.new, profile: false, &stepping(count))
      rom.placement.sizes.fetch(:__frame)
    end

    assert_equal sizes.first, sizes.last
  end

  def test_each_instance_of_a_pool_picks_its_own
    game = built do
      screen :tiled
      names = (0...3).map do |n|
        image(:"pose#{n}", "." => :transparent, "#" => :red) { TestFaceShowing.marked(n * 4) }
        :"pose#{n}"
      end
      guards = pool :guard, x: 0, y: 0, pick: 0, capacity: 3, facing: names.to_h { |name| [name, name] }
      3.times { |n| guards.spawn(x: n * 24, y: 40, pick: n) }
      game_loop { guards.each { |g| g.face names, showing: g.pick } }
    end

    assert_backends_agree(game, frames: 3)
    pictures = Reference.new.run(game, frames: 3).sprites(:guard).sort_by(&:x).map(&:picture)
    assert_equal %i[pose0 pose1 pose2], pictures
  end

  private def refused(&game)
    assert_raises(ArgumentError) { built(&game) }.message
  end

  def test_a_pick_that_cannot_be_made_is_a_friendly_error
    poses = proc do
      screen :tiled
      image(:a, "#" => :red) { "########\n" * 8 }
      image(:b, "#" => :blue) { "########\n" * 8 }
    end
    assert_match(/cannot face :c/, refused do
      instance_eval(&poses)
      hero = sprite :hero, at: [0, 0], facing: { a: :a, b: :b }
      game_loop { hero.face %i[a c], showing: var(:n, 0) }
    end)
    assert_match(/from 0 to 1/, refused do
      instance_eval(&poses)
      hero = sprite :hero, at: [0, 0], facing: { a: :a, b: :b }
      game_loop { hero.face %i[a b], showing: 5 }
    end)
    assert_match(/no variable has that name/, refused do
      instance_eval(&poses)
      hero = sprite :hero, at: [0, 0], facing: { a: :a, b: :b }
      game_loop { hero.face %i[a b], showing: :nope }
    end)
    assert_match(/showing: picks/, refused do
      instance_eval(&poses)
      hero = sprite :hero, at: [0, 0], facing: { a: :a, b: :b }
      game_loop { hero.face :a, showing: var(:n, 0) }
    end)
    assert_match(/showing: needs a number/, refused do
      instance_eval(&poses)
      hero = sprite :hero, at: [0, 0], facing: { a: :a, b: :b }
      game_loop { hero.face %i[a b], showing: hero.x > 3 }
    end)
  end
end
