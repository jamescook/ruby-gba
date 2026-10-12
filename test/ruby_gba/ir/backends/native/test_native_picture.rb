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

  # A tear-free screen is two pictures shown in turn, and a frame's drawing lands on one of them.
  # This game only ever adds to what is there, so each picture holds half the bars, and the one
  # shown is the one finished last: what was painted before the loop is on one page alone.
  def test_a_tear_free_screen_shows_the_page_finished_last
    program = program_of do
      screen :bitmap, tear_free: true
      n = var :n, 0
      clear_screen :blue
      game_loop do
        draw_rect_at n * 4, 20, 2, 10, :white
        n.add! 1
      end
    end

    assert_native_matches_reference program, frames: 7

    odd, even = reference_snapshots(program, frames: 7, buttons: {}).last(2).map(&:picture)
    assert odd != even, "the two pages should hold different pictures"
  end

  # A tear-free screen told which colors it shows draws exactly what one that was not told does:
  # the list is the console's business, and a color is still named.
  def test_a_tear_free_screen_given_its_colors
    program = program_of do
      screen :bitmap, tear_free: true, colors: %i[black blue white red]
      n = var :n, 0
      game_loop do
        clear_screen :blue
        draw_rect_at 20 + n * 4, 30, 10, 10, :white
        draw_rect_at 100, 80 - n * 2, 6, 6, :red
        n.add! 1
      end
    end

    last = assert_native_matches_reference(program, frames: 5)

    %i[blue white red].each { |name| assert_includes last.picture, Color.resolve(name), "#{name} should be drawn" }
  end

  # Pictures painted into the picture where the program says: one with see-through pixels, one
  # hanging off two edges, and one of a set picked by a number that runs past the set.
  def test_pictures_blitted_onto_a_bitmap_screen
    program = program_of do
      screen :bitmap
      image :ring, "#" => :yellow, "." => :transparent do "########\n#......#\n" * 4 end
      image :calm, "#" => :green do "####\n" * 4 end
      image :hurt, "#" => :red do "####\n" * 4 end
      n = var :n, 0
      game_loop do
        clear_screen :blue
        blit :ring, 20 + n, 30
        blit :ring, 236, 156 - n
        blit %i[calm hurt], 100, 100, showing: n >> 1
        n.add! 1
      end
    end

    last = assert_native_matches_reference(program, frames: 6)

    seen = reference_snapshots(program, frames: 6, buttons: {}).flat_map(&:picture).uniq
    %i[yellow green red].each { |name| assert_includes seen, Color.resolve(name), "#{name} should have been drawn" }
    refute_includes last.picture, Color.resolve(:green), "a number past the set should draw none of it"
  end

  # A sprite on a bitmap screen remembers the picture under it and puts it back as it moves, so
  # it leaves no trail over a field painted once; hidden it is gone, and shown again it is back.
  def test_a_sprite_on_a_bitmap_screen_leaves_no_trail
    program = program_of do
      screen :bitmap
      image :ball, "o" => :white, "." => :transparent do "..oooo..\n.oooooo.\n" * 4 end
      clear_screen :blue
      fill_rect 0, 60, 240, 20, :red
      fill_rect 200, 0, 2, 160, :yellow # stripes he crosses, so a patch put back a pixel out shows
      fill_rect 170, 0, 6, 160, :green
      ball = sprite :ball, at: [236, 50] # starts partly off the right edge
      n = var :n, 0
      game_loop do
        ball.move :left, by: 6
        ball.move :down, by: 2
        (n == 5).then { ball.hide }
        (n == 8).then { ball.show }
        n.add! 1
      end
    end

    last = assert_native_matches_reference(program, frames: 13)

    assert_includes last.picture, Color.resolve(:white), "the ball should be in the last picture compared"
  end

  # Drawing held inside a part of the screen is cut off at its edges: a clear clears that part, a
  # rectangle and a picture crossing an edge lose what falls outside, and drawing after the block
  # is free again.
  def test_drawing_held_inside_an_area_is_cut_off_at_its_edges
    program = program_of do
      screen :bitmap
      image :ring, "#" => :yellow, "." => :transparent do "########\n#......#\n" * 4 end
      n = var :n, 0
      game_loop do
        clear_screen :black
        inside 40, 30, 100, 60 do
          clear_screen :blue
          draw_rect_at 30 + n * 3, 20, 30, 20, :red
          blit :ring, 136, 86 - n
        end
        draw_rect_at 0, 150, 240, 4, :white
        n.add! 1
      end
    end

    last = assert_native_matches_reference(program, frames: 6)

    assert_equal Color.resolve(:black), last.picture[0], "outside the area the clear before it should stand"
    assert_includes last.picture, Color.resolve(:white), "and drawing after the block should land anywhere"
  end

  # A game with a tear-free scene, a plain painted one and one drawn from tiles: the two pages
  # come and go with the scenes, and each scene's picture is its own.
  def test_a_tear_free_scene_beside_a_plain_one_and_a_tiled_one
    program = program_of do
      state = var :state, 0
      ticks = var :ticks, 0
      image :brick, "#" => :red do "########\n" * 8 end
      tiles :wall, "#" => :brick
      scene(:tear_free) do
        screen :bitmap, tear_free: true
        draw_rect_at ticks * 6, 20, 4, 10, :white
      end
      scene(:plain) do
        screen :bitmap
        draw_rect_at ticks * 6, 60, 4, 10, :yellow
      end
      scene(:tiled) do
        screen :tiled
        background :wall, tiles: :wall, map: ["#" * 30] * 4
      end
      game_loop do
        ticks.add! 1
        state.set! ticks / 4 % 3
        case_var :state do
          when_val 0, :tear_free
          when_val 1, :plain
          when_val 2, :tiled
        end
      end
    end

    assert_native_matches_reference program, frames: 26

    seen = reference_snapshots(program, frames: 26, buttons: {}).flat_map(&:picture).uniq
    %i[white yellow red].each { |name| assert_includes seen, Color.resolve(name), "#{name} should have been drawn" }
  end

  # The window moved over the picture: nothing is redrawn, the picture slides, and the backdrop
  # shows where the window is off its edge. A shake moves it for a few frames and puts it back.
  def test_the_window_moves_over_the_picture
    program = program_of do
      screen :bitmap
      n = var :n, 0
      clear_screen :blue
      fill_rect 100, 60, 40, 40, :yellow
      game_loop do
        (n < 5).then { camera n * 7, n * -3 }
        (n == 5).then { camera 0, 0 }
        (n == 6).then { shake_screen intensity: 3, frames: 4 }
        n.add! 1
      end
    end

    assert_native_matches_reference program, frames: 12

    seen = reference_snapshots(program, frames: 12, buttons: {}).map(&:picture)
    assert_includes seen[4], Color.resolve(:black), "the backdrop should show past the picture's edge"
    assert_operator seen.uniq.length, :>, 5, "the picture should be somewhere new on most frames"
  end

  # One column of a picture stretched to a height the game works out: taller than the screen,
  # shorter than the picture, nothing at all, and several pixels across.
  def test_a_column_of_a_picture_stretched_to_a_height
    program = program_of do
      screen :bitmap
      image :wall, "r" => :red, "g" => :green, "b" => :blue, "." => :transparent do
        "rgb.\ngbr.\nbrg.\nrrgg\n"
      end
      n = var :n, 0
      game_loop do
        clear_screen :black
        draw_column_at :wall, slice: n & 3, x: 20, top: 80 - n * 30, height: n * 60, width: 3
        draw_column_at :wall, slice: 1, x: 60 + n, top: 70, height: 3
        draw_column_at :wall, slice: 9, x: 100, top: 150, height: 40 - n * 10
        n.add! 1
      end
    end

    last = assert_native_matches_reference(program, frames: 6)

    assert_includes last.picture, Color.resolve(:red), "the tall column should be in the last picture compared"
  end

  # A picture drawn when it changes and then left alone, on one page and on two: the tear-free
  # screen has to be painted once for each of its pages, or the two show different scores.
  def test_a_picture_kept_showing_on_one_page_and_on_two
    [false, true].each do |tear_free|
      program = program_of do
        screen :bitmap, tear_free: tear_free
        score = var :score, 0
        n = var :n, 0
        clear_screen :black
        bar = keep_showing(:bar) { draw_rect_at 10, 10, score * 4, 6, :green }
        game_loop do
          (n == 2).then { score.set! 5 }
          (n == 2).then { bar.changed }
          bar.draw
          n.add! 1
        end
      end

      last = assert_native_matches_reference(program, frames: 8)

      assert_includes last.picture, Color.resolve(:green), "the bar should be showing (tear_free: #{tear_free})"
    end
  end

  # A field cleared under a sprite on a painted screen: nothing of the old field is put back, and
  # the sprite is drawn again over whatever was painted after the clear.
  def test_a_field_cleared_under_a_bitmap_sprite
    program = program_of do
      screen :bitmap
      image :ball, "o" => :white, "." => :transparent do "..oooo..\n.oooooo.\n" * 4 end
      clear_screen :blue
      ball = sprite :ball, at: [100, 70]
      n = var :n, 0
      game_loop do
        ball.move :right, by: 3
        (n == 4).then do
          clear_screen :red
          fill_rect 90, 60, 60, 30, :green
        end
        n.add! 1
      end
    end

    last = assert_native_matches_reference(program, frames: 9)

    assert_includes last.picture, Color.resolve(:white), "the ball should be drawn over the new field"
    refute_includes last.picture, Color.resolve(:blue), "and nothing of the old field should be put back"
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
