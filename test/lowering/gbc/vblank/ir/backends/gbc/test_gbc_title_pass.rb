# frozen_string_literal: true

require "test_helper"

# A TITLE SCREEN'S PASS, as small as Pokémon Pinball's: two animations stepped from tables by a
# step number — four sprites of five poses that bounce, three of two that blink — each pass picking
# every sprite's pose and row from the tables. Every number is a byte, and a Color with its frame to
# spare sleeps through most of it, as the console's own title does.
class TestGBCTitlePass < Minitest::Test
  # The bounce: [pose, frames] each step, round again after the last, as the title's ball keeps it.
  BOUNCE = [[0, 2], [1, 6], [2, 2], [3, 4], [4, 6], [2, 4]].freeze
  BLINK = [[0, 40], [1, 6], [0, 20], [1, 6]].freeze

  TITLE = VBlank.game("TITLE PASS", consoles: %i[gbc]) do
    screen :tiled
    poses = (0...5).map do |p|
      image :"ball#{p}", width: 8, height: 8, colors: [:transparent, :red, :white], places: Array.new(64) { |i| 1 + ((i + p) % 2) }
      :"ball#{p}"
    end
    eyes = (0...2).map do |p|
      image :"eye#{p}", width: 8, height: 8, colors: [:transparent, :black, :yellow], places: Array.new(64) { |i| 1 + ((i * (p + 1)) % 2) }
      :"eye#{p}"
    end
    [[:bounce, poses, 4, TestGBCTitlePass::BOUNCE], [:blink, eyes, 3, TestGBCTitlePass::BLINK]].each do |name, pictures, count, steps|
      sprites = (0...count).map { |n| sprite :"#{name}#{n}", at: [16 + (n * 10), 40], facing: pictures.to_h { |p| [p, p] } }
      step_poses = table :"#{name}_poses", steps.map(&:first)
      step_frames = table :"#{name}_frames", steps.map(&:last)
      rows = table :"#{name}_rows", pictures.each_index.map { |p| 40 + (p * 3) }
      step = var :"#{name}_step", 0
      left = var :"#{name}_left", steps.first.last
      func(:"step_#{name}") do
        pose = step_poses[step]
        sprites.each do |each|
          each.face pictures, showing: pose
          each.y.set! rows[pose]
        end
        left.add!(-1)
        (left == 0).then do
          (step == steps.length - 1).then { step.set! 0 }.else { step.add! 1 }
          left.set! step_frames[step]
        end
      end
    end
    game_loop do
      call :step_bounce
      call :step_blink
    end
  end

  def test_the_pass_leaves_most_of_each_frame_asleep
    rom = TITLE.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 120, settle: 20)

    assert_in_delta 59.7, result.fps, 2.5
    assert_operator result.idle_share, :>, 0.68
  end

  def test_the_title_plays_as_the_interpreter_plays_it
    game_player.run(TITLE.program(console: :gbc), frames: 60)
  end
end
