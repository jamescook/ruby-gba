# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# A game's picture, drawn by the C runtime, shows the same pixel in every place the interpreter's
# does, at every frame boundary. Each test is a small game built through the DSL; the answer is
# the interpreter's picture (see NativeComparison).
class TestNativePicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  def test_rectangles_pixels_and_a_clear_on_a_bitmap_screen
    program = program_of do
      screen :bitmap
      x = var :x, 230
      game_loop do
        clear_screen :blue
        fill_rect 10, 10, 20, 8, :red
        draw_rect_at x, 40, 30, 12, :yellow # runs off the right edge, and is clipped there
        pixel 5, 100, :white
        x.sub! 7
      end
    end

    last = assert_native_matches_reference(program, frames: 4)

    assert(last.picture.uniq.length > 2, "the picture should hold more than a clear")
  end

  def test_text_and_a_live_number
    program = program_of do
      screen :bitmap
      score = var :score, 0
      game_loop do
        clear_screen :black
        draw_text "PONG", :center, 40, :white
        draw_text "HI", 8, 8, [:gray, :white], showing: score > 2
        draw_number score, 100, 100, :green, digits: 2
        score.add! 1
      end
    end

    assert_native_matches_reference program, frames: 5
  end

  def test_a_flash_and_a_fade_mix_into_the_whole_picture
    program = program_of do
      screen :bitmap
      n = var :n, 0
      game_loop do
        clear_screen :cyan
        fill_rect 0, 0, 120, 160, :white
        (n == 1).then { flash_screen :red, frames: 6 }
        (n == 8).then { fade_out frames: 4 }
        n.add! 1
      end
    end

    assert_native_matches_reference program, frames: 14
  end

  # A menu on a bitmap screen is painted into the picture: rows, the cursor, the picked row lit.
  def test_a_menu_on_a_bitmap_screen_follows_the_cursor
    program = program_of do
      screen :bitmap
      chosen = var :chosen, 0
      game_loop do
        clear_screen :black
        menu :main, at: [60, 40], color: :gray, picked: :white do |m|
          m.item("PLAY") { chosen.set! 1 }
          m.item("QUIT") { chosen.set! 2 }
        end
      end
    end

    last = assert_native_matches_reference(program, frames: 8, buttons: { 3 => %i[down], 6 => %i[a] })

    assert_equal 2, last.variables[:chosen]
  end

  # A scene's own scenery is up only while that scene is: until the scene takes the screen
  # over, its background is not drawn, and once it has, it is.
  def test_a_scenes_scenery_shows_only_once_the_scene_takes_over
    program = program_of do
      screen :tiled
      state = var :state, 0
      ticks = var :ticks, 0
      image :brick, "#" => :red do "########\n" * 8 end
      tiles :wall, "#" => :brick
      scene(:waiting) do
        ticks.add! 1
        (ticks >= 3).then { state.set! 1 }
      end
      scene(:walled) { background :wall, tiles: :wall, map: ["#" * 30] * 20 }
      game_loop do
        case_var :state do
          when_val 0, :waiting
          when_val 1, :walled
        end
      end
    end

    assert_native_matches_reference program, frames: 6
  end

  # Two sprites cross: a hit is only where their DRAWN pixels meet, so the dot passes through the
  # hollow ring's middle untouched for a few frames.
  def test_sprites_collide_only_where_their_drawn_pixels_meet
    program = program_of do
      screen :tiled
      image :ring, "#" => :yellow, "." => :transparent do
        "########\n#......#\n#......#\n#......#\n#......#\n#......#\n#......#\n########\n"
      end
      image :dot, "#" => :red, "." => :transparent do
        "........\n........\n........\n...##...\n...##...\n........\n........\n........\n"
      end
      ring = sprite :ring, at: [100, 60]
      dot = sprite :dot, at: [80, 60]
      hits = var :hits, 0
      inside = var :inside, 0
      game_loop do
        dot.move :right, by: 1
        dot.overlaps?(ring).then { hits.add! 1 }.else { (dot.x > 100).then { inside.add! 1 } }
      end
    end

    last = assert_native_matches_reference program, frames: 40
    assert_operator last.variables[:hits], :>, 0, "the dot should cross the ring's rim"
    assert_operator last.variables[:inside], :>, 0, "and pass through its hollow middle without a hit"
  end

  # A sprite over scenery that stays put: where it was is the scenery again, where it is hidden
  # nothing of it is left, and where it comes back it is drawn again.
  def test_a_sprite_moving_over_still_scenery_leaves_no_trail
    program = program_of do
      screen :tiled
      image :brick, "#" => :red, "." => :blue do "#.#.#.#.\n.#.#.#.#\n" * 4 end
      image :ball, "o" => :white, "." => :transparent do "..oooo..\n.oooooo.\n" * 4 end
      tiles :wall, "#" => :brick
      background :wall, tiles: :wall, map: ["#" * 30] * 20
      ball = sprite :ball, at: [236, 70] # starts partly off the right edge
      n = var :n, 0
      game_loop do
        ball.move :left, by: 5
        ball.move :down, by: 2
        (n == 6).then { ball.hide }
        (n == 9).then { ball.show }
        n.add! 1
      end
    end

    last = assert_native_matches_reference(program, frames: 14)

    assert_includes last.picture, Color.resolve(:white), "the ball should be in the last picture compared"
  end

  # A sprite told to draw with another list of colors is matched to it by place, and a number
  # naming no list is its own colors again.
  def test_a_sprite_drawn_with_another_list_of_colors
    program = program_of do
      screen :tiled
      colors :hot, %i[transparent red orange]
      colors :cold, %i[transparent blue cyan]
      image :gem, "." => :transparent, "a" => :green, "b" => :yellow, colors: %i[transparent green yellow] do
        "..aaaa..\n.abbbba.\n" * 4
      end
      gem = sprite :gem, at: [40, 40]
      n = var :n, 0
      game_loop do
        gem.draw_with %i[hot cold], showing: n >> 1
        gem.move :right, by: 3
        n.add! 1
      end
    end

    assert_native_matches_reference program, frames: 8

    seen = reference_snapshots(program, frames: 8, buttons: {}).flat_map(&:picture).uniq
    %i[red blue green].each { |name| assert_includes seen, Color.resolve(name), "#{name} should have been drawn" }
  end

  # A stack of named layers on a picture that stays: the background declared second sits BEHIND
  # the first, and the sprite declared first is drawn over the one declared after it.
  def test_named_layers_decide_what_is_in_front
    program = program_of do
      screen :tiled
      layers :sky, :fence, :back, :front
      image :slat, "#" => :orange, "." => :transparent do "##....##\n" * 8 end
      image :cloud, "#" => :cyan do "########\n" * 8 end
      image :hero, "h" => :white, "." => :transparent do "hhhhhhhh\n" * 8 end
      image :ghost, "g" => :red, "." => :transparent do "gggggggg\n" * 8 end
      tiles :fence, "#" => :slat
      tiles :sky, "#" => :cloud
      layer(:fence) { background :fence, tiles: :fence, map: ["#" * 30] * 10 }
      layer(:sky) { background :sky, tiles: :sky, map: ["#" * 30] * 20 }
      hero = layer(:front) { sprite :hero, at: [50, 50] }
      ghost = layer(:back) { sprite :ghost, at: [54, 54] }
      game_loop do
        hero.move :right, by: 2
        ghost.move :right, by: 2
      end
    end

    last = assert_native_matches_reference(program, frames: 6)

    top_row = last.picture.first(WIDTH)
    assert_equal Color.resolve(:orange), top_row[0], "the fence should be over the sky"
    assert_equal Color.resolve(:cyan), top_row[3], "and the sky should show between its slats"
  end

  # Scenery a named layer puts in FRONT of a sprite: the whole view is rebuilt from its layers,
  # and the sprite shows only between the slats.
  def test_scenery_in_front_of_a_sprite
    program = program_of do
      screen :tiled
      layers :ground, :actors, :fence
      image :slat, "#" => :orange, "." => :transparent do "##....##\n" * 8 end
      image :grass, "#" => :green do "########\n" * 8 end
      image :hero, "h" => :white, "." => :transparent do "hhhhhhhh\n" * 8 end
      tiles :fence, "#" => :slat
      tiles :ground, "#" => :grass
      layer(:ground) { background :ground, tiles: :ground, map: ["#" * 30] * 20 }
      layer(:fence) { background :fence, tiles: :fence, map: ["#" * 30] * 20 }
      hero = layer(:actors) { sprite :hero, at: [48, 48] }
      game_loop { hero.move :right, by: 1 }
    end

    last = assert_native_matches_reference(program, frames: 5)

    assert_includes last.picture, Color.resolve(:white), "the hero should show between the slats"
  end

  # A scene's sprite over the scene's own scenery: the copy of the scenery kept for putting back
  # under a sprite is made again when the scenery changes. The three hand-overs change it three
  # ways: scenery going up where there was none, one scene's replaced by another's, and scenery
  # coming down with none to follow.
  def test_a_sprite_over_each_scenes_own_scenery
    program = program_of do
      screen :tiled
      state = var :state, 0
      ticks = var :ticks, 0
      image :brick, "#" => :red do "########\n" * 8 end
      image :moss, "#" => :green do "########\n" * 8 end
      image :ball, "o" => :white, "." => :transparent do "..oooo..\n" * 8 end
      tiles :wall, "#" => :brick
      tiles :lawn, "#" => :moss
      scene(:nowhere) do
        ball = sprite :ball, at: [60, 100]
        ball.move :left, by: 4
        ticks.add! 1
        (ticks == 3).then { state.set! 1 }
      end
      scene(:indoors) do
        background :wall, tiles: :wall, map: ["#" * 30] * 20
        ball = sprite :ball, at: [20, 20]
        ball.move :right, by: 4
        ticks.add! 1
        (ticks == 7).then { state.set! 2 }
      end
      scene(:outdoors) do
        background :lawn, tiles: :lawn, map: ["#" * 30] * 10
        ball = sprite :ball, at: [100, 30]
        ball.move :down, by: 4
        ticks.add! 1
        (ticks == 11).then { state.set! 0 }
      end
      game_loop do
        case_var :state do
          when_val 0, :nowhere
          when_val 1, :indoors
          when_val 2, :outdoors
        end
      end
    end

    assert_native_matches_reference program, frames: 18
  end

  # The same background put up twice, with one that named no layer put up between: when a scene's
  # own scenery comes down, what is left is stamped again in the order the stack asks for, and
  # that order counts both times the first one went up.
  def test_a_background_put_up_twice_keeps_its_places_in_the_stack
    program = program_of do
      screen :tiled
      layers :under, :over
      state = var :state, 0
      ticks = var :ticks, 0
      %i[red green blue white].each { |name| image(name, "#" => name) { "########\n" * 8 } }
      tiles :reds, "#" => :red
      tiles :greens, "#" => :green
      tiles :blues, "#" => :blue
      tiles :whites, "#" => :white
      func(:put_up_red) { layer(:over) { background :red_band, tiles: :reds, map: ["#" * 10] * 4 } }
      call :put_up_red
      background :green_band, tiles: :greens, map: ["     ##########"] * 4
      layer(:under) { background :blue_band, tiles: :blues, map: ["          ##########"] * 4 }
      call :put_up_red
      scene(:with_scenery) do
        background :floor, tiles: :whites, map: (["    "] * 10) + ["####"]
        ticks.add! 1
        (ticks >= 3).then { state.set! 1 }
      end
      scene(:without) { ticks.add! 1 }
      game_loop do
        case_var :state do
          when_val 0, :with_scenery
          when_val 1, :without
        end
      end
    end

    last = assert_native_matches_reference(program, frames: 8)

    assert_equal 1, last.variables[:state], "the run should reach the scene that takes the floor down"
  end

  # A sprite given a picture for each way it faces, one of them the other mirrored, steps through
  # a walk as it goes; another shows the pose a number picks, and none for a number past them.
  def test_sprites_face_animate_mirror_and_show_a_pose_by_number
    program = program_of do
      screen :tiled
      image :step_a, "#" => :yellow, "." => :transparent do "###.....\n" * 8 end
      image :step_b, "#" => :orange, "." => :transparent do "#####...\n" * 8 end
      image :lamp_off, "#" => :gray, "." => :transparent do "..####..\n" * 8 end
      image :lamp_on, "#" => :white, "." => :transparent do ".######.\n" * 8 end
      walk = %i[step_a step_b]
      hero = sprite :hero, at: [100, 40], rate: 2, facing: { right: walk, left: mirror(walk) }
      lamp = sprite :lamp, at: [40, 100], facing: { off: :lamp_off, on: :lamp_on }
      n = var :n, 0
      game_loop do
        (n < 6).then { hero.move :right, by: 3 }.else { hero.move :left, by: 3 }
        lamp.face %i[off on], showing: n >> 2
        n.add! 1
      end
    end

    assert_native_matches_reference program, frames: 14

    seen = reference_snapshots(program, frames: 14, buttons: {}).flat_map(&:picture).uniq
    %i[yellow orange gray white].each { |name| assert_includes seen, Color.resolve(name), "#{name} should have been drawn" }
  end

  # Art given as numbers into its list of colors, the list holding one color at two places: drawn
  # with another list, each pixel takes the color at ITS place, which its color alone cannot say.
  def test_a_sprite_given_as_places_is_recolored_by_place
    program = program_of do
      screen :tiled
      colors :split, %i[transparent red blue]
      image :twins, width: 8, height: 8, colors: %i[transparent green green],
                    places: ([1] * 4 + [2] * 4) * 8
      twins = sprite :twins, at: [60, 60]
      n = var :n, 0
      game_loop do
        twins.draw_with [:split], showing: n >> 1
        n.add! 1
      end
    end

    assert_native_matches_reference program, frames: 6

    seen = reference_snapshots(program, frames: 6, buttons: {}).flat_map(&:picture).uniq
    %i[red blue green].each { |name| assert_includes seen, Color.resolve(name), "#{name} should have been drawn" }
  end

  def test_the_screen_is_white_until_the_first_frame
    program = program_of do
      screen :bitmap
      clear_screen :red
      game_loop { pixel 1, 1, :blue }
    end

    assert_native_matches_reference program, frames: 2
  end
end
