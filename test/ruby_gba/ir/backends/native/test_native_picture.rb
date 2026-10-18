# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# A game's picture, drawn by the C runtime, shows the same pixel in every place the interpreter's
# does, at every frame boundary. Each test is a small game built through the DSL; the answer is
# the interpreter's picture (see NativeComparison).
class TestNativePicture < Minitest::Test
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

  # A tint on the plain bitmap screen is mixed in by the display as it draws, at eight bits a
  # channel, so a red channel at 16 taken half way toward red's 31 is 24, where five bits say 23.
  def test_a_tint_on_a_bitmap_screen_is_mixed_at_eight_bits
    program = program_of do
      screen :bitmap
      game_loop do
        clear_screen rgb(16, 16, 16)
        tint :red, 50
      end
    end

    last = assert_native_matches_reference(program, frames: 3)
    assert_equal 24 | (8 << 5) | (8 << 10), last.picture.first, "red half way to its brightest at eight bits"
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

  # A pose that is another turned top to bottom, and one turned both ways: the red end of a flag
  # drawn at its top left is then at the bottom left, and at the bottom right.
  def test_a_sprite_shows_a_pose_turned_upside_down
    program = program_of do
      screen :tiled
      image :flag, "r" => :red, "b" => :blue, "." => :transparent do
        "rrrr....\n#{"b.......\n" * 7}"
      end
      sprite :flag, at: [80, 60], rate: 2, frames: [:flag, upside_down(:flag), mirror(upside_down(:flag))]
      game_loop {}
    end

    assert_native_matches_reference program, frames: 8

    corners = { top_left: [80, 60], bottom_left: [80, 67], bottom_right: [87, 67], top_right: [87, 60] }
    red_seen_at = reference_snapshots(program, frames: 8, buttons: {}).flat_map do |moment|
      corners.select { |_, (x, y)| moment.picture[(y * WIDTH) + x] == Color.resolve(:red) }.keys
    end
    assert_equal %i[top_left bottom_left bottom_right], red_seen_at.uniq
  end

  # Sprites drawn in an order the game works out, over ground that scrolls, so the whole view is
  # rebuilt every frame. Two pairs, each put in order on its own. In the first whoever stands
  # lower is in front, so the walker coming down is behind the post until its feet pass the
  # post's. In the second whoever stands higher is, so the runner going up is behind the stone
  # until its feet pass the stone's. Each then walks clear of the spot the test watches.
  def test_sprites_in_a_worked_out_order_over_scenery_that_scrolls
    block = "#{'#' * 16}\n" * 16
    program = program_of do
      screen :tiled
      image :turf, "#" => :green, "." => :blue do "##..##..\n..##..##\n" * 4 end
      image(:post, "#" => :red) { block }
      image(:walker, "#" => :white) { block }
      image(:stone, "#" => :yellow) { block }
      image(:runner, "#" => :orange) { block }
      tiles :lawn, "#" => :turf
      ground = background :lawn, tiles: :lawn, map: ["#" * 32] * 32
      post = sprite :post, at: [60, 60]
      walker = sprite :walker, at: [68, 50]
      stone = sprite :stone, at: [140, 60]
      runner = sprite :runner, at: [148, 70]
      draw_in_order post, walker
      draw_in_order stone, runner, front: :lowest
      game_loop do
        ground.scroll_by 2, 1
        walker.move :down, by: 2
        runner.move :up, by: 2
      end
    end

    assert_native_matches_reference program, frames: 12

    moments = reference_snapshots(program, frames: 12, buttons: {})
    assert_equal %i[red white red], colors_in_turn(moments, [70, 66], %i[red white]),
                 "the walker goes behind the post, then in front of it, then clear of that spot"
    assert_equal %i[yellow orange yellow], colors_in_turn(moments, [150, 72], %i[yellow orange]),
                 "and the runner behind the stone, then in front of it, then clear"
  end

  # Two blocks that overlap, the red one listed first, and a list a test keeps an order in by hand.
  private def two_blocks_and_a_list(&game)
    block = "#{'#' * 16}\n" * 16
    program = program_of do
      screen :tiled
      image(:back, "#" => :red) { block }
      image(:fore, "#" => :green) { block }
      sprite :back, at: [60, 60]
      sprite :fore, at: [68, 64]
      instance_exec(list(:order, capacity: 4, width: :byte), &game)
    end
    with_draw_orders_written_by_hand(program) { |names| [[names, :order]] }
  end

  # What the list of a draw order may hold is read as the interpreter reads it: a place below
  # nought counts back from the last, so -1 is the green block and it goes down first, under the
  # red one. And a list shorter than its run draws only the sprites it names.
  def test_a_draw_order_holds_places_as_the_interpreter_reads_them
    program = two_blocks_and_a_list do |order|
      order.push(-1)
      order.push 0
      n = var :n, 0
      game_loop do
        (n == 3).then do
          order[0] = 0
          order[1] = 1
        end
        (n == 6).then { order.pop }
        n.add! 1
      end
    end

    assert_native_matches_reference program, frames: 10

    moments = reference_snapshots(program, frames: 10, buttons: {})
    assert_equal %i[red green red], colors_in_turn(moments, [70, 66], %i[red green]),
                 "red in front, then green, then red alone once the list names only it"
    assert_equal Color.resolve(:black), moments.last.picture[(70 * WIDTH) + 80], "the green block is not drawn at the end"
  end

  # A place that names none of the run's sprites stops the game, as it stops the interpreter.
  def test_a_draw_order_naming_no_sprite_stops_the_game
    program = two_blocks_and_a_list do |order|
      order.push 0
      order.push 2
      game_loop {}
    end

    assert_raises(IndexError) { reference_snapshots(program, frames: 3, buttons: {}) }
    error = assert_raises(RubyGBA::IR::ProgramError) { lowered_snapshots(program, frames: 3, buttons: {}, mode: :checked) }
    assert_match(/draw order names sprite 2 of the 2/, error.message)
  end

  # The colors of +names+ seen at one pixel over a run, in the order they were first seen and
  # seen again: [:red, :white] for a pixel that was red for a while and then white.
  private def colors_in_turn(moments, (x, y), names)
    by_color = names.to_h { |name| [Color.resolve(name), name] }
    moments.filter_map { |moment| by_color[moment.picture[(y * WIDTH) + x]] }.chunk_while { |a, b| a == b }.map(&:first)
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

  # Two backgrounds scrolled at their own speeds under a sprite. Each scrolls over a grid 256
  # pixels each way and comes round again at its edges. The far one goes left, below nought, and
  # down past 256; the near one goes right past 256 and up, below nought.
  def test_backgrounds_scroll_at_their_own_speeds_and_come_round_again
    program = program_of do
      screen :tiled
      image :turf, "#" => :green, "o" => :yellow do ("#o######\n" * 3) + ("########\n" * 5) end
      image :post, "#" => :orange, "." => :transparent do "..####..\n" * 8 end
      image :ball, "o" => :white, "." => :transparent do "..oooo..\n" * 8 end
      tiles :far, "#" => :turf
      tiles :near, "|" => :post
      far = background :far, tiles: :far, map: ["# ## ### ####"] * 12
      near = background :near, tiles: :near, map: ["|   |     |"] * 20
      ball = sprite :ball, at: [100, 60]
      game_loop do
        far.scroll_by(-37, 41)
        near.scroll_by(43, -9)
        ball.move :right, by: 1
      end
    end

    last = assert_native_matches_reference(program, frames: 10)

    assert_operator different_pictures_in(program, frames: 10), :>=, 10, "every frame should show the scenery somewhere new"
    assert_operator last.variables[:__bg_far_sy], :>, 256, "the far one should have gone down past where it comes round"
    assert_operator last.variables[:__bg_near_sx], :>, 256, "and the near one right past where it does"
  end

  # A turned background that is also scrolled. The builder refuses a game that says both, so the
  # scroll is written here as the statement itself; the interpreter draws one, and so must the C.
  def test_a_turned_background_is_scrolled_too
    program = program_of do
      screen :tiled
      image :brick, "#" => :red, "o" => :orange do "#o######\n" * 8 end
      image :floor, "#" => :blue do "########\n" * 8 end
      tiles :room, "#" => :brick, "." => :floor
      room = background :room, tiles: :room, map: ["#..#...#" * 4] * 32
      n = var :n, 0
      game_loop do
        room.rotate 30
        record_statement(RubyGBA::IR::Build.scroll_background(:room, x: RubyGBA::IR::Build.var_ref(:n), y: RubyGBA::IR::Build.int(5)))
        n.add! 7
      end
    end

    assert_native_matches_reference program, frames: 6

    assert_operator different_pictures_in(program, frames: 6), :>=, 5, "the scroll should move the turned picture"
  end

  # Cells of the scenery become other tiles as the game counts: a wall grows over floor and over
  # cells that held nothing, and another opens. A cell off any edge of the map is left alone.
  def test_cells_of_a_background_change_while_the_game_runs
    program = program_of do
      screen :tiled
      image :brick, "#" => :red, "o" => :orange do "#o######\n" * 8 end
      image :floor, "#" => :blue do "########\n" * 8 end
      image :ball, "o" => :white, "." => :transparent do "..oooo..\n" * 8 end
      tiles :room, "#" => :brick, "." => :floor
      room = background :room, tiles: :room, map: ["##########", "#  ......#", "#........#", "##########"]
      n = var :n, 0
      ball = sprite :ball, at: [20, 4]
      game_loop do
        room.set_tile n, 1, "#"
        room.set_tile 9 - n, 3, "."
        room.set_tile 10, 1, "." # one past the right edge, which is the next row's first cell in memory
        room.set_tile(-1, 2, ".")
        room.set_tile 1, -1, "."
        room.set_tile 1, 4, "."
        n.add! 1
        ball.move :right, by: 2
      end
    end

    last = assert_native_matches_reference(program, frames: 7)

    assert_equal Color.resolve(:blue), last.picture[(3 * 8 * WIDTH) + (9 * 8)], "the bottom wall should have opened"
    assert_equal Color.resolve(:red), last.picture[(1 * 8 * WIDTH) + (2 * 8)], "and a wall grown where there was nothing"
  end

  # A background handed its maps by a number read off a table: out to the second, back to the
  # first, on to the third, and then a number that names none. A cell changed in the first map is
  # as declared again when that map comes back, and a cell changed in the second shows while the
  # second does.
  def test_a_background_is_handed_another_of_its_maps
    program = program_of do
      screen :tiled
      image :brick, "#" => :red, "o" => :orange do "#o######\n" * 8 end
      image :floor, "#" => :blue do "########\n" * 8 end
      image :pond, "#" => :cyan do "########\n" * 8 end
      tiles :rooms, "#" => :brick, "." => :floor, "~" => :pond
      rooms = background :rooms, tiles: :rooms, map: {
        hall: ["######", "#....#", "#....#", "######"],
        cave: ["##..##", "#.~~.#", "#.~~.#", "##..##"],
        pool: ["~~~~~~", "~....~", "~....~", "~~~~~~"]
      }
      order = table :order, [0, 0, 1, 1, 0, 0, 2, 2, 5, 5, 5]
      n = var :n, 0
      game_loop do
        (n == 1).then { rooms.set_tile 2, 1, "~" }
        (n == 3).then { rooms.set_tile 0, 0, "." }
        rooms.show_map order[n]
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 11, buttons: {})
    corner = ->(moment) { moment.picture[0] }
    changed = ->(moment) { moment.picture[(1 * 8 * WIDTH) + (2 * 8)] }

    assert_native_matches_reference program, frames: 11

    assert_equal %i[red blue cyan].map { |name| Color.resolve(name) }, moments.map(&corner).uniq.first(3),
                 "the hall, then the cave with its corner opened, then the pool"
    assert_equal Color.resolve(:cyan), changed.call(moments[2]), "the cell changed in the hall should show there"
    assert_equal Color.resolve(:blue), changed.call(moments[6]), "and be as declared when the hall comes back"
    assert_equal moments[8].picture, moments.last.picture, "a number naming no map should leave the pool up"
  end

  # Scenery left showing its second map with a cell changed is as declared the next time it is
  # put up. A scene's own is put up when the scene takes over again; what every screen shows
  # stays as the game left it through that, and is put up again only once a painted screen has
  # been between. After that it can be handed its second map again, which it could not if what
  # says which map it shows had been left saying the second.
  def test_scenery_goes_back_up_as_declared
    program = program_of do
      screen :tiled
      state = var :state, 0
      ticks = var :ticks, 0
      image :brick, "#" => :red, "o" => :orange do "#o######\n" * 8 end
      image :floor, "#" => :blue do "########\n" * 8 end
      image :pond, "#" => :cyan do "########\n" * 8 end
      tiles :rooms, "#" => :brick, "." => :floor, "~" => :pond
      shared = background :shared, tiles: :rooms, map: { first: ["      ####"] * 2, second: ["      ...."] * 2 }
      order = table :order, [0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 2, 2, 2, 0, 0, 0, 0]
      scene(:room) do
        own = background :own, tiles: :rooms, map: { first: ["####"] * 2, second: ["...."] * 2 }
        (ticks == 2).then do
          own.show_map 1
          shared.show_map 1
        end
        (ticks == 3).then do
          own.set_tile 0, 0, "~"
          shared.set_tile 9, 0, "~"
        end
        (ticks == 15).then { shared.show_map 1 }
      end
      scene(:bare) {}
      scene(:painted) do
        screen :bitmap
        fill_rect 100, 100, 20, 20, :yellow
      end
      game_loop do
        ticks.add! 1
        state.set! order[ticks]
        case_var :state do
          when_val 0, :room
          when_val 1, :bare
          when_val 2, :painted
        end
      end
    end

    moments = reference_snapshots(program, frames: 18, buttons: {})
    own_corner = ->(moment) { moment.picture[0] }
    shared_corner = ->(moment) { moment.picture[9 * 8] }

    assert_native_matches_reference program, frames: 18

    assert_equal Color.resolve(:cyan), own_corner.call(moments[4]), "the scene's own cell should have changed"
    assert_equal Color.resolve(:red), own_corner.call(moments[9]), "and be as declared when the scene is back"
    assert_equal Color.resolve(:cyan), shared_corner.call(moments[9]), "while what every screen shows is as it was left"
    assert_equal Color.resolve(:red), shared_corner.call(moments[14]), "until a painted screen has been between"
    assert_equal Color.resolve(:blue), shared_corner.call(moments.last), "after which it can be handed its second map again"
  end

  # Two scenes each declare a background called :room, with maps of different sizes. Each is
  # drawn from its own map, and the two share what the game does to the name: the scroll the
  # second scene gives it, and a changed cell, which is a copy of the second's map that the first
  # scene draws too once a cell is changed while it is up, until it takes over again.
  def test_two_backgrounds_with_one_name_share_what_the_game_does_to_it
    program = program_of do
      screen :tiled
      state = var :state, 0
      ticks = var :ticks, 0
      image :brick, "#" => :red, "o" => :orange do "#o######\n" * 8 end
      image :floor, "#" => :blue do "########\n" * 8 end
      image :pond, "#" => :cyan do "########\n" * 8 end
      tiles :rooms, "#" => :brick, "." => :floor, "~" => :pond
      order = table :order, [0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0]
      scene(:first) do
        room = background :room, tiles: :rooms, map: ["##..", "#..."]
        (ticks == 10).then { room.set_tile 0, 1, "#" }
      end
      scene(:second) do
        room = background :room, tiles: :rooms, map: ["..~~~~", "~~..~~", "......"]
        room.scroll_by 2, 0
        (ticks == 5).then { room.set_tile 2, 0, "#" }
      end
      game_loop do
        ticks.add! 1
        state.set! order[ticks]
        case_var :state do
          when_val 0, :first
          when_val 1, :second
        end
      end
    end

    moments = reference_snapshots(program, frames: 18, buttons: {})

    assert_native_matches_reference program, frames: 18

    assert_equal Color.resolve(:red), moments[1].picture[0], "the first scene should draw its own map"
    assert_equal Color.resolve(:cyan), moments[5].picture[(8 * WIDTH) + 2], "the second its own, scrolled"
    refute_equal moments[9].picture, moments[11].picture, "a cell changed in the first scene should show there"
  end

  # On a bitmap screen a scene's background is painted into the picture where it is declared,
  # and each of two scenes paints its own map, though both call it :room.
  def test_two_bitmap_scenes_each_paint_their_own_background_of_one_name
    program = program_of do
      state = var :state, 0
      ticks = var :ticks, 0
      image :brick, "#" => :red do "########\n" * 8 end
      image :pond, "#" => :cyan do "########\n" * 8 end
      tiles :rooms, "#" => :brick, "~" => :pond
      order = table :order, [0, 0, 0, 1, 1, 1, 0, 0]
      scene(:first) do
        screen :bitmap
        background :room, tiles: :rooms, map: ["##  ", "#   "]
      end
      scene(:second) do
        screen :bitmap
        background :room, tiles: :rooms, map: ["  ~~", "~~  "]
      end
      game_loop do
        ticks.add! 1
        state.set! order[ticks]
        case_var :state do
          when_val 0, :first
          when_val 1, :second
        end
      end
    end

    moments = reference_snapshots(program, frames: 8, buttons: {})

    assert_native_matches_reference program, frames: 8

    assert_equal Color.resolve(:red), moments[1].picture[0], "the first scene should paint its own map"
    assert_equal Color.resolve(:cyan), moments[4].picture[3 * 8], "and the second its own"
  end

  # Named layers put two backgrounds of one name in another order than the program declares
  # them. What the game does to the name is kept by the one declared last, so a changed cell is
  # a copy of the second scene's map, though its background is the further back.
  def test_backgrounds_of_one_name_in_layers_share_the_last_declared_one_s_cells
    program = program_of do
      screen :tiled
      layers :back, :front
      state = var :state, 0
      ticks = var :ticks, 0
      image :brick, "#" => :red do "########\n" * 8 end
      image :pond, "#" => :cyan do "########\n" * 8 end
      tiles :rooms, "#" => :brick, "~" => :pond
      order = table :order, [0, 0, 0, 1, 1, 1, 0, 0, 0]
      scene(:first) do
        layer(:front) { background :room, tiles: :rooms, map: ["##  ", "#   "] }
      end
      scene(:second) do
        room = layer(:back) { background :room, tiles: :rooms, map: ["  ~~", "~~  "] }
        (ticks == 4).then { room.set_tile 0, 0, "#" }
      end
      game_loop do
        ticks.add! 1
        state.set! order[ticks]
        case_var :state do
          when_val 0, :first
          when_val 1, :second
        end
      end
    end

    moments = reference_snapshots(program, frames: 9, buttons: {})

    assert_native_matches_reference program, frames: 9

    assert_equal Color.resolve(:red), moments[5].picture[0], "the changed cell should show in the second scene"
    assert_equal Color.resolve(:cyan), moments[5].picture[3 * 8], "over the second scene's own map"
  end

  # Whether a background is seen through is asked of its name, which the one declared last
  # answers: the first scene's background, declared in a see-through layer, is drawn solid
  # because the second scene's background of the same name is in a solid one.
  def test_backgrounds_of_one_name_are_seen_through_as_the_last_declared_one_is
    program = program_of do
      screen :tiled
      layers :ground, :water
      state = var :state, 0
      ticks = var :ticks, 0
      image :sky, "#" => :blue do "########\n" * 8 end
      image :brick, "#" => :red do "########\n" * 8 end
      tiles :skies, "#" => :sky
      tiles :rooms, "#" => :brick
      layer(:ground) { background :backdrop, tiles: :skies, map: ["####"] * 2 }
      order = table :order, [0, 0, 0, 1, 1, 0, 0]
      scene(:first) do
        layer(:water, transparency: 50) { background :room, tiles: :rooms, map: ["##  "] * 2 }
      end
      scene(:second) do
        layer(:ground) { background :room, tiles: :rooms, map: ["  ##"] * 2 }
      end
      game_loop do
        ticks.add! 1
        state.set! order[ticks]
        case_var :state do
          when_val 0, :first
          when_val 1, :second
        end
      end
    end

    moments = reference_snapshots(program, frames: 7, buttons: {})

    assert_native_matches_reference program, frames: 7

    assert_equal Color.resolve(:red), moments[1].picture[0], "the first scene's background should be drawn solid"
  end

  # A background with a small map and one bigger than any grid the console has. Neither comes
  # round again. The window is walked over each in six steps, from left of and above its first
  # cell to right of and below its last, and past an edge the layer behind shows.
  def test_a_map_bigger_than_the_grid_shows_nothing_past_its_edges
    field = Array.new(66) { |row| Array.new(70) { |col| ((row + col) % 3).zero? ? "." : "#" }.join }
    program = program_of do
      screen :tiled
      image :turf, "#" => :green, "o" => :yellow do "#o######\n" * 8 end
      image :path, "#" => :orange do "########\n" * 8 end
      image :cloud, "#" => :cyan do "########\n" * 8 end
      tiles :land, "#" => :turf, "." => :path
      tiles :sky, "#" => :cloud
      background :sky, tiles: :sky, map: ["#" * 30] * 20
      world = background :world, tiles: :land, map: { hut: ["####", "#..#", "####"], field: field }
      n = var :n, 0
      game_loop do
        world.show_map n / 6
        world.scroll_to ((n % 6) * 150) - 100, ((n % 6) * 130) - 60
        n.add! 1
      end
    end

    # The picture at the start of frame k was drawn from n = k - 3.
    moments = reference_snapshots(program, frames: 15, buttons: {})
    drawn_from = ->(n) { moments[n + 2].picture }

    assert_native_matches_reference program, frames: 15

    assert_equal Color.resolve(:cyan), drawn_from.call(0)[0], "the sky should show left of and above the hut"
    assert_includes drawn_from.call(0), Color.resolve(:orange), "with the hut in view"
    assert_equal [Color.resolve(:cyan)], drawn_from.call(1).uniq, "and nothing of the hut past its far corner"
    assert_equal Color.resolve(:cyan), drawn_from.call(6)[0], "the sky should show left of and above the field"
    assert_includes drawn_from.call(6), Color.resolve(:green), "with the field in view"
    refute_includes drawn_from.call(8), Color.resolve(:cyan), "the field should fill the view from its middle"
    assert_equal [Color.resolve(:cyan)], drawn_from.call(11).uniq, "and nothing of it comes round again past its far corner"
  end

  # A sprite put in a layer by a number, over two backgrounds with gaps in them: in front of both
  # where it was declared, between them, behind both, and where it was declared again for a
  # number that names no layer.
  def test_a_sprite_is_put_in_another_layer_by_a_number
    program = program_of do
      screen :tiled
      layers :stairs, :ground, :walking, :scenery, :upper
      image :plank, "#" => :green, "." => :transparent do "####....\n" * 8 end
      image :rail, "#" => :orange, "." => :transparent do ("########\n" * 3) + ("........\n" * 5) end
      image :hero, "h" => :white do "hhhhhhhh\n" * 8 end
      tiles :floor, "#" => :plank
      tiles :rails, "#" => :rail
      layer(:ground) { background :floor, tiles: :floor, map: ["#" * 30] * 20 }
      layer(:scenery) { background :rails, tiles: :rails, map: ["#" * 30] * 20 }
      hero = layer(:upper) { sprite :hero, at: [40, 40] }
      n = var :n, 0
      game_loop do
        hero.put_in_layer %i[walking stairs], showing: (n / 2) - 1
        hero.move :right, by: 1
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 10, buttons: {})
    whites = moments.map { |moment| moment.picture.count(Color.resolve(:white)) }

    assert_native_matches_reference program, frames: 10

    assert_equal [64, 40, 20, 64], whites.drop(2).chunk_while { |a, b| a == b }.map(&:first),
                 "the whole hero, then what shows under the rails, then what shows past the planks too, then all of it"
  end

  # A pool whose instances are sprites, over still scenery: one spawned every other frame, each
  # drifting its own way and overlapping the one before. The ones that drift neither way are
  # taken out as they pass a line, and the others stay until the pool is full and its oldest is
  # used again. Where two overlap the older is in front, and a sprite declared after the pool is
  # in front of them all.
  def test_a_pool_of_sprites_is_drawn_oldest_in_front
    program = program_of do
      screen :tiled
      image :turf, "#" => :green do "########\n" * 8 end
      image :drop, "w" => :white, "c" => :cyan, "." => :transparent do ("wwwwwwww\n" * 4) + (".cccccc.\n" * 4) end
      image :hat, "#" => :red, "." => :transparent do "..####..\n" * 8 end
      tiles :lawn, "#" => :turf
      background :lawn, tiles: :lawn, map: ["#" * 30] * 20
      drops = pool :drop, x: 0, y: 0, drift: 0, capacity: 3, image: :drop, on_full: :recycle_oldest
      sprite :hat, at: [44, 30]
      n = var :n, 0
      game_loop do
        every(2) { drops.spawn(x: 40 + n, y: 20, drift: (n % 3) - 1) }
        drops.each do |drop|
          drop.x.add! drop.drift
          drop.y.add! 3
          ((drop.y > 30) & (drop.drift == 0)).then { drop.remove }
        end
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 18, buttons: {})
    whites = moments.map { |moment| moment.picture.count(Color.resolve(:white)) }

    assert_native_matches_reference program, frames: 18

    # A drop's top half is 32 white pixels, and no drop covers another's.
    assert_operator whites.max, :>, 2 * 32, "three drops should have been out at once"
    assert_operator whites[12], :<, whites[11], "and one should have been taken out as it passed the line"
  end

  # A mover is stopped by the walls of the map its background is showing. The same push to the
  # right stops at a wall of the first map, and goes on once the second map, which has floor
  # there, is handed over.
  def test_a_mover_is_stopped_by_the_walls_of_the_map_showing
    program = program_of do
      screen :tiled
      image :brick, "#" => :red do "########\n" * 8 end
      image :floor, "#" => :blue do "########\n" * 8 end
      image :hero, "h" => :white do "hhhhhhhh\n" * 8 end
      tiles :rooms, "#" => :brick, "." => :floor, solid: ["#"]
      rooms = background :rooms, tiles: :rooms, map: {
        shut: ["##########", "#....#...#", "#....#...#", "##########"],
        open: ["##########", "#........#", "#....#...#", "##########"]
      }
      hero = sprite :hero, at: [8, 8]
      hero.blocked_by rooms
      n = var :n, 0
      reached = var :reached, 0
      below = var :below, 0
      game_loop do
        hero.move :right, by: 2
        (n == 24).then { rooms.show_map :open }
        hero.can_move?(:down, by: 8).then { below.set! 1 }.else { below.set! 0 }
        reached.set! hero.x
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 50, buttons: {})
    reached = moments.map { |moment| moment.variables[:reached] }

    assert_native_matches_reference program, frames: 50

    assert_equal 32, reached[24], "the wall of the first map should have stopped him"
    assert_equal 64, reached.last, "and he should have walked through where the second map has floor, to its far wall"
    assert_equal [1, 0, 1], moments.drop(2).map { |moment| moment.variables[:below] }.chunk_while { |a, b| a == b }.map(&:first),
                 "the way down is open, then shut beside the pillar under the gap, then open again"
  end

  # A sprite that turns, over still scenery: at another angle every frame, about its own middle,
  # hanging off the left edge at first, hidden for two frames, and leaving no trail.
  def test_a_sprite_turns_over_still_scenery_and_leaves_no_trail
    program = program_of do
      screen :tiled
      image :brick, "#" => :red, "." => :blue do "#.#.#.#.\n.#.#.#.#\n" * 4 end
      image :arrow, "w" => :white, "y" => :yellow, "." => :transparent do
        ["wwwwwwwwwwww....", "wwwwwwwwwwwwyy..", "wwwwwwwwwwwwyyyy", "wwwwwwwwwwwwyyyy",
         "wwwwwwwwwwwwyyyy", "wwwwwwwwwwwwyy..", "wwwwwwwwwwww....", "................"].join("\n")
      end
      tiles :wall, "#" => :brick
      background :wall, tiles: :wall, map: ["#" * 30] * 20
      arrow = sprite :arrow, at: [-6, 30]
      n = var :n, 0
      game_loop do
        arrow.turn 37
        arrow.move :right, by: 4
        (n == 5).then { arrow.hide }
        (n == 7).then { arrow.show }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 14, buttons: {})
    rows_holding_white = moments.map { |moment| moment.picture.each_slice(WIDTH).count { |row| row.include?(Color.resolve(:white)) } }

    assert_native_matches_reference program, frames: 14

    assert_operator rows_holding_white.max, :>, 8, "the arrow is 7 rows tall as drawn, and turned it should stand taller"
    assert_includes rows_holding_white, 0, "and it should have been hidden for a while"
  end

  # A sprite that grows from under half its size to past twice it, where the box the console
  # gives it cuts its edges off, turning as it goes and drawn in another list of colors on some
  # frames. It is drawn straight onto still scenery, so what it covered is put back each frame.
  def test_a_sprite_resizes_as_it_turns_and_is_drawn_in_other_colors
    program = program_of do
      screen :tiled
      colors :hot, %i[transparent red orange]
      image :turf, "#" => :green, "." => :blue do "##..##..\n..##..##\n" * 4 end
      image :gem, "." => :transparent, "a" => :white, "b" => :yellow, colors: %i[transparent white yellow] do
        ("aaaaaaaabbbbbbbb\n" * 8) + ("bbbbbbbbaaaaaaaa\n" * 4) + ("................\n" * 4)
      end
      tiles :lawn, "#" => :turf
      background :lawn, tiles: :lawn, map: ["#" * 30] * 20
      gem = sprite :gem, at: [100, 60]
      size = var :size, 0.4
      n = var :n, 0
      game_loop do
        gem.scale size
        gem.face_angle n * 50
        gem.draw_with %i[hot], showing: (n / 3) % 2
        size.add! 0.2
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 13, buttons: {})
    covered = moments.map { |moment| moment.picture.count { |color| ![Color.resolve(:green), Color.resolve(:blue)].include?(color) } }

    assert_native_matches_reference program, frames: 13

    assert_operator covered[3], :<, 16 * 12 / 2, "it should start well under the size it was drawn at"
    assert_operator covered[9], :>, 16 * 12 * 2, "and grow to well over it"
    seen = moments.flat_map(&:picture).uniq
    %i[white red].each { |name| assert_includes seen, Color.resolve(name), "#{name} should have been drawn" }
  end

  # A turning, growing sprite on a picture that is rebuilt every frame: between a ground that
  # scrolls under it and a fence with gaps that scrolls over it.
  def test_a_sprite_turns_between_scenery_that_scrolls
    program = program_of do
      screen :tiled
      layers :ground, :actors, :fence
      image :turf, "#" => :green, "." => :blue do "##..##..\n..##..##\n" * 4 end
      image :post, "#" => :red, "." => :transparent do "##......\n" * 8 end
      image :kite, "w" => :white, "c" => :cyan, "." => :transparent do
        ("wwwwwwwwcccccccc\n" * 8) + ("cccc....wwww....\n" * 8)
      end
      tiles :lawn, "#" => :turf
      tiles :posts, "#" => :post
      ground = layer(:ground) { background :lawn, tiles: :lawn, map: ["#" * 32] * 32 }
      fence = layer(:fence) { background :posts, tiles: :posts, map: ["#" * 32] * 32 }
      kite = layer(:actors) { sprite :kite, at: [226, 70] }
      n = var :n, 0
      game_loop do
        ground.scroll_by 1, 2
        fence.scroll_by(-3, 0)
        kite.turn(-29)
        kite.scale.add! 0.125
        kite.move :left, by: 6
        n.add! 1
      end
    end

    last = assert_native_matches_reference(program, frames: 12)

    assert_includes last.picture, Color.resolve(:white), "the kite should be in the last picture compared"
    assert_operator different_pictures_in(program, frames: 12), :>=, 11, "and every frame should have shown it somewhere new"
  end

  # Water you can see the floor through, on a picture that stays: the water's gaps show the floor
  # plain, a sprite in front of the water is solid, and a sprite moves over it leaving no trail.
  def test_a_see_through_background_shows_what_is_behind_it
    program = program_of do
      screen :tiled
      layers :floor, :water, :swimmers
      image :slab, "#" => :red, "." => :yellow do "####....\n....####\n" * 4 end
      image :wave, "~" => :blue, "." => :transparent do "~~~~~~..\n" * 8 end
      image :duck, "d" => :white, "." => :transparent do "..dddd..\n.dddddd.\n" * 4 end
      tiles :slabs, "#" => :slab
      tiles :waves, "~" => :wave
      layer(:floor) { background :slabs, tiles: :slabs, map: ["#" * 30] * 20 }
      layer(:water, transparency: 40) { background :waves, tiles: :waves, map: ["~" * 30] * 20 }
      duck = layer(:swimmers) { sprite :duck, at: [20, 40] }
      game_loop do
        duck.move :right, by: 5
        duck.move :down, by: 1
      end
    end

    last = assert_native_matches_reference(program, frames: 8)

    drawn = %i[red yellow blue white].map { |name| Color.resolve(name) }
    assert_operator last.picture.count { |color| !drawn.include?(color) }, :>, 240 * 160 / 2,
                    "most of the picture should be water mixed with the floor under it"
    assert_includes last.picture, Color.resolve(:white), "the duck is in front of the water, so it is solid"
    assert_includes last.picture, Color.resolve(:red), "and the floor shows plain through the water's gaps"
  end

  # Sprites you can see through, their two amounts said apart so that they glow: two of them
  # crossing each other over scenery that stays, drawn straight onto it and taken off again.
  def test_see_through_sprites_cross_over_still_scenery
    program = program_of do
      screen :tiled
      layers :ground, :ghosts
      image :turf, "#" => :green, "." => :blue do "##..##..\n..##..##\n" * 4 end
      image :ghost, "g" => :gray, "e" => :red, "." => :transparent do
        ("..gggggggggggg..\n" * 4) + ("gggeeggggeeggggg\n" * 4) + ("gggggggggggggggg\n" * 8)
      end
      tiles :lawn, "#" => :turf
      layer(:ground) { background :lawn, tiles: :lawn, map: ["#" * 30] * 20 }
      left, right = layer(:ghosts, shows: 60, shows_behind: 100) do
        [sprite(:ghost, at: [60, 50]), sprite(:ghost, at: [100, 56])]
      end
      n = var :n, 0
      game_loop do
        left.move :right, by: 4
        right.move :left, by: 4
        (n == 6).then { right.hide }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 10, buttons: {})

    assert_native_matches_reference program, frames: 10

    colors_shown = moments.map { |moment| moment.picture.uniq.length }
    assert_equal colors_shown[2], colors_shown.max,
                 "where one ghost is over the other it is mixed with the turf and never with the ghost behind, " \
                 "so no color shows that a ghost alone over the turf does not"
    refute_includes moments.last.picture, Color.resolve(:gray), "no ghost should be drawn solid"
  end

  # The same ghosts where the ground scrolls under them, so the whole view is rebuilt every
  # frame: one of them turning, and both showing less of themselves as the game goes on.
  def test_see_through_sprites_over_scenery_that_scrolls
    program = program_of do
      screen :tiled
      layers :ground, :ghosts
      image :turf, "#" => :green, "." => :blue do "##..##..\n..##..##\n" * 4 end
      image :ghost, "g" => :gray, "e" => :red, "." => :transparent do
        ("..gggggggggggg..\n" * 4) + ("gggeeggggeeggggg\n" * 4) + ("gggggggggggggggg\n" * 8)
      end
      tiles :lawn, "#" => :turf
      n = var :n, 0
      ground = layer(:ground) { background :lawn, tiles: :lawn, map: ["#" * 32] * 32 }
      left, right = layer(:ghosts, shows: 90 - (n * 6), shows_behind: 70) do
        [sprite(:ghost, at: [60, 50]), sprite(:ghost, at: [100, 56])]
      end
      game_loop do
        ground.scroll_by 3, 1
        left.move :right, by: 4
        right.move :left, by: 4
        right.turn 20
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 10, buttons: {})

    assert_native_matches_reference program, frames: 10

    refute_includes moments.last.picture, Color.resolve(:gray), "no ghost should be drawn solid"
    assert_operator moments.flat_map(&:picture).uniq.length, :>=, 20, "and they should have faded through several amounts"
  end

  # Mist whose amount the game works out, over ground that scrolls, so the whole view is rebuilt
  # every frame: it thickens, clears altogether, and comes back.
  def test_a_see_through_amount_the_game_works_out
    program = program_of do
      screen :tiled
      layers :ground, :walkers, :mist
      image :turf, "#" => :green, "." => :orange do "##..##..\n..##..##\n" * 4 end
      image :fog, "f" => :white, "." => :transparent do "ffffff..\n" * 8 end
      image :hero, "h" => :red do "hhhhhhhh\n" * 8 end
      tiles :lawn, "#" => :turf
      tiles :fogs, "f" => :fog
      thick = var :thick, 0
      ground = layer(:ground) { background :lawn, tiles: :lawn, map: ["#" * 32] * 32 }
      layer(:walkers) { sprite :hero, at: [116, 76] }
      layer(:mist, transparency: 100 - thick) { background :fogs, tiles: :fogs, map: ["f" * 30] * 20 }
      n = var :n, 0
      game_loop do
        ground.scroll_by 2, 1
        thick.set! (n % 6) * 20
        n.add! 1
      end
    end

    # The first two moments are before anything the loop decided is drawn.
    moments = reference_snapshots(program, frames: 14, buttons: {}).drop(2)
    whites = moments.map { |moment| moment.picture.count(Color.resolve(:white)) }
    reds = moments.map { |moment| moment.picture.count(Color.resolve(:red)) }

    assert_native_matches_reference program, frames: 14

    assert_operator moments.flat_map(&:picture).uniq.length, :>=, 12, "the mist should have been drawn at several thicknesses"
    assert_equal [0, 240 * 160 * 6 / 8], whites.minmax, "from no mist at all to mist that hides what is under it"
    assert_equal [2 * 8, 8 * 8], reds.minmax,
                 "under solid mist the hero shows only in its gaps, two columns of him; with none, all of him"
  end

  # Mist over a picture that STAYS, with a sprite in front of it drawn straight onto the picture:
  # nothing scrolls and no scenery is in front of a sprite, so only the amount changing, on some
  # frames and not on others, has the picture built again.
  def test_a_see_through_amount_changes_over_a_picture_that_stays
    program = program_of do
      screen :tiled
      layers :ground, :mist, :walkers
      image :turf, "#" => :green, "." => :orange do "##..##..\n..##..##\n" * 4 end
      image :fog, "f" => :white, "." => :transparent do "ffffff..\n" * 8 end
      image :hero, "h" => :red, "." => :transparent do "hhhhhh..\n" * 8 end
      tiles :lawn, "#" => :turf
      tiles :fogs, "f" => :fog
      thick = var :thick, 30
      layer(:ground) { background :lawn, tiles: :lawn, map: ["#" * 30] * 20 }
      hero = layer(:walkers) { sprite :hero, at: [40, 76] }
      layer(:mist, shows: thick, shows_behind: 100 - thick) { background :fogs, tiles: :fogs, map: ["f" * 30] * 20 }
      n = var :n, 0
      game_loop do
        hero.move :right, by: 3
        ((n % 3) == 0).then { thick.add! 15 }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 12, buttons: {})

    assert_native_matches_reference program, frames: 12

    # The picture's first pixel is mist over turf, and the hero never reaches it.
    assert_operator moments.drop(2).map { |moment| moment.picture.first }.uniq.length, :>=, 3,
                    "the mist over the turf should have been drawn at several amounts"
  end

  # A game with a see-through layer fades by walking its colors, so the layer goes on showing
  # what is behind it while the whole picture darkens, flashes and is tinted.
  def test_a_fade_and_a_tint_over_a_see_through_layer
    program = program_of do
      screen :tiled
      layers :floor, :water
      image :slab, "#" => :red, "." => :yellow do "####....\n....####\n" * 4 end
      image :wave, "~" => :cyan, "." => :transparent do "~~~~~~..\n" * 8 end
      tiles :slabs, "#" => :slab
      tiles :waves, "~" => :wave
      floor = layer(:floor) { background :slabs, tiles: :slabs, map: ["#" * 32] * 32 }
      layer(:water, shows: 94, shows_behind: 63) { background :waves, tiles: :waves, map: ["~" * 30] * 20 }
      n = var :n, 0
      level = var :level, 0.0
      game_loop do
        floor.scroll_by 1, 0
        (n < 6).then { fade :black, n * 15 }
        (n == 6).then { fade :white, level }
        (n == 8).then { fade :black, 0 }
        (n == 9).then { tint :green, 40 }
        (n == 11).then { flash_screen :red }
        level.add! 12.5
        n.add! 1
      end
    end

    assert_native_matches_reference program, frames: 18

    assert_operator different_pictures_in(program, frames: 18), :>=, 12
  end

  # A layer named see-through that shows all of itself is solid, so a fade over it is the
  # display's own. Seeing through and fading are one unit of the display, and it does one of
  # them: the picture is built again as the fade comes on and as it lifts.
  def test_a_fade_over_a_layer_that_shows_all_of_itself
    program = program_of do
      screen :tiled
      layers :floor, :glass, :walkers
      image :slab, "#" => :red, "." => :yellow do "####....\n....####\n" * 4 end
      image :pane, "p" => rgb8(40, 80, 120), "." => :transparent do "pppppp..\n" * 8 end
      image :hero, "h" => :white do "hhhhhhhh\n" * 8 end
      tiles :slabs, "#" => :slab
      tiles :panes, "p" => :pane
      layer(:floor) { background :slabs, tiles: :slabs, map: ["#" * 30] * 20 }
      layer(:glass, transparency: 0) { background :panes, tiles: :panes, map: ["p" * 30] * 20 }
      hero = layer(:walkers) { sprite :hero, at: [30, 30] }
      n = var :n, 0
      game_loop do
        hero.move :right, by: 4
        (n == 3).then { fade :black, 50 }
        (n == 6).then { fade :black, 0 }
        n.add! 1
      end
    end

    last = assert_native_matches_reference(program, frames: 10)

    assert_includes last.picture, Color.resolve(:white), "the hero should be back once the fade has lifted"
  end

  # A fade set on a painted screen is the display's own, and it is still on when a scene drawn
  # from tiles takes over. While it is, that scene's water is solid; the water shows the floor
  # again once the fade lifts. A sprite moves over it the whole time.
  def test_a_see_through_layer_is_solid_under_a_fade_the_display_does
    program = program_of do
      layers :floor, :water, :swimmers
      image :slab, "#" => :red, "." => :yellow do "####....\n....####\n" * 4 end
      image :wave, "~" => :blue, "." => :transparent do "~~~~~~..\n" * 8 end
      image :duck, "d" => :white, "." => :transparent do "..dddd..\n.dddddd.\n" * 4 end
      tiles :slabs, "#" => :slab
      tiles :waves, "~" => :wave
      state = var :state, 0
      n = var :n, 0
      scene(:title) do
        screen :bitmap
        clear_screen :green
        (n == 1).then { fade :black, 25 }
      end
      scene(:pool) do
        screen :tiled
        layer(:floor) { background :slabs, tiles: :slabs, map: ["#" * 30] * 20 }
        layer(:water, transparency: 40) { background :waves, tiles: :waves, map: ["~" * 30] * 20 }
        duck = layer(:swimmers) { sprite :duck, at: [20, 40] }
        duck.move :right, by: 5
        (n == 8).then { fade :black, 0 }
      end
      game_loop do
        case_var :state do
          when_val 0, :title
          when_val 1, :pool
        end
        (n == 3).then { state.set! 1 }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 13, buttons: {})

    assert_native_matches_reference program, frames: 13

    darker_blue = 23 << 10 # blue, a quarter of the way to black, worked out at eight bits
    assert_includes moments[7].picture, darker_blue, "under the fade the water should be solid"
    refute_includes moments.last.picture, Color.resolve(:blue), "and with the fade lifted it shows the floor through it"
  end

  # A fade placed in the stack: what is behind the layer it names goes dark, and that layer and
  # everything in front of it stay as drawn. Here the line falls between two backgrounds, and
  # the fade deepens a little each frame until the floor is gone.
  def test_a_fade_placed_between_two_backgrounds
    program = program_of do
      screen :tiled
      layers :floor, :frame
      image :slab, "#" => :red, "." => :yellow do "####....\n....####\n" * 4 end
      image :bar, "=" => :white, "." => :transparent do ("========\n" * 2) + ("........\n" * 6) end
      tiles :slabs, "#" => :slab
      tiles :bars, "=" => :bar
      layer(:floor) { background :slabs, tiles: :slabs, map: ["#" * 30] * 20 }
      layer(:frame) { background :bars, tiles: :bars, map: ["=" * 30] * 20 }
      n = var :n, 0
      game_loop do
        fade :black, n * 10, under: :frame
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 13, buttons: {})

    assert_native_matches_reference program, frames: 13

    assert_operator moments.map(&:picture).uniq.length, :>=, 8, "the floor should have darkened through several amounts"
    assert_equal [Color.resolve(:black), Color.resolve(:white)], moments.last.picture.uniq.sort,
                 "at the end the floor is black and the bars in front of the line are as drawn"
  end

  # The line falling between sprites, and the fade going toward white: the score in front of it
  # stays as drawn while the player behind it, the ground, and a sprite that named no layer all
  # go white. Then a plain fade takes the placed one's place, and reaches the score too.
  def test_a_fade_placed_between_sprites
    program = program_of do
      screen :tiled
      layers :ground, :players, :score
      image :turf, "#" => :green do "########\n" * 8 end
      image :hero, "#" => :red do "########\n" * 8 end
      image :digit, "#" => :blue do "########\n" * 8 end
      image :stray, "#" => :orange do "########\n" * 8 end
      tiles :lawn, "#" => :turf
      layer(:ground) { background :lawn, tiles: :lawn, map: ["#" * 30] * 20 }
      hero = layer(:players) { sprite :hero, at: [40, 40] }
      layer(:score) { sprite :digit, at: [100, 8] }
      sprite :stray, at: [160, 100]
      n = var :n, 0
      game_loop do
        hero.move :right, by: 3
        (n < 8).then { fade :white, n * 15, under: :score }
        (n == 8).then { fade :white, 100 }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 12, buttons: {})

    assert_native_matches_reference program, frames: 12

    white = Color.resolve(:white)
    placed = moments[8].picture
    assert_equal [Color.resolve(:blue), white], placed.uniq.sort, "everything but the score should be white under the placed fade"
    assert_equal [white], moments.last.picture.uniq, "and the score too once a fade over the whole screen takes its place"
  end

  # A placed fade walked over frames, out and back in, as a game goes to its game-over screen and
  # comes back: the field and the ship in it go dark and return, and the score never changes.
  def test_a_placed_fade_walked_out_and_back_in
    program = program_of do
      screen :tiled
      layers :field, :ships, :ui
      image :star, "*" => :yellow, "." => :transparent do "...*....\n" * 8 end
      image :ship, "#" => :red do "########\n" * 8 end
      image :digit, "#" => :white do "########\n" * 8 end
      tiles :stars, "*" => :star
      field = layer(:field) { background :stars, tiles: :stars, map: ["*" * 32] * 32 }
      ship = layer(:ships) { sprite :ship, at: [40, 60] }
      layer(:ui) { sprite :digit, at: [8, 8] }
      n = var :n, 0
      game_loop do
        field.scroll_by 0, 1
        ship.move :right, by: 2
        (n == 2).then { fade_out frames: 8, under: :ui }
        (n == 14).then { fade_in }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 26, buttons: {})

    assert_native_matches_reference program, frames: 26

    white = Color.resolve(:white)
    assert_equal [Color.resolve(:black), white], moments[13].picture.uniq.sort, "faded out, only the score should show"
    assert_includes moments.last.picture, Color.resolve(:red), "the ship should be back once the fade has come in"
    drawn = moments.drop(1) # a sprite is first drawn in the gap after the first frame
    assert_equal [64], drawn.map { |moment| moment.picture.count(white) }.uniq, "the score should never have changed"
  end

  # A placed fade and a see-through layer both want the display's one blend, and the fade has it:
  # the water is solid while the fade is on, and shows the floor again when a tint takes the
  # fade's place.
  def test_a_placed_fade_holds_a_see_through_layer_solid_until_a_tint_takes_its_place
    program = program_of do
      screen :tiled
      layers :floor, :water, :ui
      image :slab, "#" => :red, "." => :yellow do "####....\n....####\n" * 4 end
      image :wave, "~" => :blue, "." => :transparent do "~~~~~~..\n" * 8 end
      image :digit, "#" => :white do "########\n" * 8 end
      tiles :slabs, "#" => :slab
      tiles :waves, "~" => :wave
      layer(:floor) { background :slabs, tiles: :slabs, map: ["#" * 30] * 20 }
      layer(:water, transparency: 40) { background :waves, tiles: :waves, map: ["~" * 30] * 20 }
      layer(:ui) { sprite :digit, at: [8, 8] }
      n = var :n, 0
      game_loop do
        (n == 2).then { fade :black, 0, under: :ui }
        (n == 4).then { fade :black, 25, under: :ui }
        (n == 8).then { tint :red, 0 }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 12, buttons: {})

    assert_native_matches_reference program, frames: 12

    blue = Color.resolve(:blue)
    darker_blue = 23 << 10 # blue, a quarter of the way to black, worked out at eight bits
    refute_includes moments[1].picture, blue, "before the fade the water shows the floor through it"
    refute_includes moments[3].picture, blue, "and under a placed fade of nothing, which takes no blend"
    assert_includes moments[7].picture, darker_blue, "under the fade the water should be solid, and darker"
    refute_includes moments.last.picture, darker_blue, "and with the fade gone it is not"
    refute_includes moments.last.picture, blue, "and shows the floor through it again"
  end

  # The line falling in the middle of the stack, with no scenery at all: the backdrop and the
  # sprite behind the line fade, and the sprite in the line's own layer and the one in front of
  # it do not. A sprite put in the front layer as the game runs is still reached, since the line
  # goes by the layer a thing was declared in. Then the fade is placed under the front layer
  # instead, and reaches the middle one too.
  def test_a_fade_placed_under_a_middle_layer_over_the_bare_backdrop
    block = "########\n" * 8
    program = program_of do
      screen :tiled
      layers :back, :middle, :front
      image(:far, "#" => :red) { block }
      image(:mid, "#" => :green) { block }
      image(:near, "#" => :blue) { block }
      image(:mover, "#" => :orange) { block }
      layer(:back) { sprite :far, at: [20, 20] }
      layer(:middle) { sprite :mid, at: [60, 20] }
      layer(:front) { sprite :near, at: [100, 20] }
      mover = layer(:back) { sprite :mover, at: [140, 20] }
      n = var :n, 0
      game_loop do
        mover.put_in_layer :front
        (n == 2).then { fade :white, 50, under: :middle }
        (n == 6).then { fade :white, 50, under: :front }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 10, buttons: {})

    assert_native_matches_reference program, frames: 10

    # Half way to white, a channel at nought is 15 and one at its brightest stays there.
    at = ->(moment, x, y) { moment.picture[(y * WIDTH) + x] }
    under_middle = moments[5]
    assert_equal 15 | (15 << 5) | (15 << 10), at.(under_middle, 200, 100), "the backdrop should be half way to white"
    assert_equal 31 | (15 << 5) | (15 << 10), at.(under_middle, 24, 24), "and so should the sprite behind the line"
    assert_equal Color.resolve(:green), at.(under_middle, 64, 24), "the sprite in the line's own layer is as drawn"
    assert_equal Color.resolve(:blue), at.(under_middle, 104, 24), "and so is the one in front of it"
    refute_equal Color.resolve(:orange), at.(under_middle, 144, 24), "one declared behind the line fades wherever it is put"
    assert_equal 15 | (31 << 5) | (15 << 10), at.(moments.last, 64, 24), "under the front layer the middle sprite fades too"
    assert_equal Color.resolve(:blue), at.(moments.last, 104, 24), "and the front one still does not"
  end

  # What a placed fade leaves as drawn, the interpreter knows by NAME, and a background can be
  # given the name the build made for a sprite. The two then stand or fall together: here the
  # floor is behind the line, and is left as drawn because the score sharing its name is in front.
  def test_a_placed_fade_leaves_a_background_that_shares_a_kept_sprites_name
    program = program_of do
      screen :tiled
      layers :floor, :ui
      image :slab, "#" => :red do "########\n" * 8 end
      image :digit, "#" => :white do "########\n" * 8 end
      tiles :slabs, "#" => :slab
      digit = layer(:ui) { sprite :digit, at: [8, 8] }
      layer(:floor) { background digit.object_name, tiles: :slabs, map: ["#" * 30] * 20 }
      game_loop { fade :black, 50, under: :ui }
    end

    last = assert_native_matches_reference(program, frames: 4)

    assert_equal [Color.resolve(:red), Color.resolve(:white)], last.picture.uniq.sort, "the floor should not have faded"
  end

  # A background drawn from another list of colors while the game runs: every pixel keeps the
  # place it was drawn at and shows that place of the other list. Then its own colors again.
  def test_a_background_is_drawn_with_another_list_of_colors
    program = program_of do
      screen :tiled
      colors :day, %i[transparent blue white]
      colors :dusk, %i[transparent orange red]
      image :sky, width: 8, height: 8, colors: :day, places: ([1] * 4 + [2] * 4) * 8
      tiles :skies, "s" => :sky
      sky = background :sky, tiles: :skies, map: ["s" * 30] * 20
      n = var :n, 0
      game_loop do
        (n == 3).then { sky.draw_with :dusk }
        (n == 6).then { sky.draw_with :own }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 10, buttons: {})

    assert_native_matches_reference program, frames: 10

    colors_of = ->(moment) { moment.picture.uniq.sort }
    assert_equal %i[blue white].map { |name| Color.resolve(name) }.sort, colors_of.(moments[2]), "its own colors first"
    assert_equal %i[orange red].map { |name| Color.resolve(name) }.sort, colors_of.(moments[5]), "then the other list's"
    assert_equal colors_of.(moments[2]), colors_of.(moments.last), "and its own again"
  end

  # One of several lists, picked by a number the game counts, over scenery that scrolls: the
  # shimmer steps through its lists, and a number past the last of them is its own colors.
  def test_a_background_is_drawn_with_one_of_several_lists_by_a_number
    program = program_of do
      screen :tiled
      colors :dim, %i[transparent blue]
      colors :pale, %i[transparent cyan]
      colors :bright, %i[transparent white]
      image :shaft, "|" => :blue, "." => :transparent, colors: :dim do "..||....\n" * 8 end
      image :deep, "#" => :black do "########\n" * 8 end
      tiles :shafts, "|" => :shaft
      tiles :water, "#" => :deep
      background :water, tiles: :water, map: ["#" * 30] * 20
      light = background :light, tiles: :shafts, map: ["|" * 32] * 32
      n = var :n, 0
      game_loop do
        light.scroll_by 1, 0
        light.draw_with %i[pale bright], showing: (n >> 1) - 1
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 12, buttons: {})

    assert_native_matches_reference program, frames: 12

    lit = moments.map { |moment| (moment.picture.uniq - [Color.resolve(:black)]).first }
    assert_equal %i[blue cyan white blue].map { |name| Color.resolve(name) }, lit.compact.chunk_while { |a, b| a == b }.map(&:first),
                 "its own colors for a number below the lists, each list in turn, and its own again past them"
  end

  # A layer whose tiles are drawn from two lists, stepped together by one number, with a list the
  # steps leave out staying as drawn. Under it all, a fade over the whole screen and then one
  # placed in the stack reach the colors it is drawn with now.
  def test_a_background_drawn_from_several_lists_steps_them_together_under_a_fade
    program = program_of do
      screen :tiled
      layers :backdrop, :ui
      colors :sea, %i[transparent blue]
      colors :sky, %i[transparent cyan]
      colors :sand, %i[transparent yellow]
      colors :sea_dusk, %i[transparent red]
      colors :sky_dusk, %i[transparent orange]
      colors :sea_night, %i[transparent black]
      colors :sky_night, %i[transparent gray]
      image :wave, width: 8, height: 8, colors: :sea, places: [1] * 64
      image :cloud, width: 8, height: 8, colors: :sky, places: [1] * 64
      image :beach, width: 8, height: 8, colors: :sand, places: [1] * 64
      image :digit, "#" => :white do "########\n" * 8 end
      tiles :shore, "~" => :wave, "c" => :cloud, "." => :beach
      backdrop = layer(:backdrop) { background :shore, tiles: :shore, map: ["c" * 30] * 6 + ["~" * 30] * 8 + ["." * 30] * 6 }
      layer(:ui) { sprite :digit, at: [8, 8] }
      n = var :n, 0
      game_loop do
        backdrop.draw_with({ sea: %i[sea_dusk sea_night], sky: %i[sky_dusk sky_night] }, showing: (n >> 2) - 1)
        (n == 8).then { fade :black, 50 }
        (n == 10).then { fade :black, 50, under: :ui }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 14, buttons: {})

    assert_native_matches_reference program, frames: 14

    # The sky, the sea and the sand, each read at one pixel, as they change over the run.
    seen = moments.map { |moment| [[4, 4], [4, 60], [4, 150]].map { |x, y| moment.picture[(y * WIDTH) + x] } }
    as_named = ->(*names) { names.map { |name| Color.resolve(name) } }
    darkened = ->(*names) { as_named.(*names).map { |color| half_way_to_black(color) } }
    assert_equal [as_named.(:cyan, :blue, :yellow), as_named.(:orange, :red, :yellow),
                  darkened.(:orange, :red, :yellow), darkened.(:gray, :black, :yellow), darkened.(:cyan, :blue, :yellow)],
                 seen.chunk_while { |a, b| a == b }.map(&:first),
                 "as drawn; the sky and the sea stepped together and the sand left alone; that darkened by a fade " \
                 "over the screen; the next step darkened by a fade placed in the stack; and past the last step, " \
                 "its own colors under that fade"
    assert_includes moments.last.picture, Color.resolve(:white), "the placed fade leaves the score in front of it as drawn"
  end

  # A color under the display's fade of half toward black: each channel is widened to eight bits
  # and loses half of itself there, red keeping the odd step and green and blue losing it, and is
  # brought back to five bits.
  private def half_way_to_black(color)
    (0..2).sum do |channel|
      level = (color >> (5 * channel)) & 31
      wide = (level << 3) | (level >> 2)
      kept = channel.zero? ? wide - (wide / 2) : wide / 2
      (kept >> 3) << (5 * channel)
    end
  end

  # A scene's own background, drawn with another list, while the scene goes and comes back. Its
  # art is given as places, with one color at two of them and a place that is see-through, so
  # each pixel can only be recolored right by the place it was drawn at. Coming back, the scene
  # puts the background up again, and later hands it another map.
  def test_a_scenes_background_drawn_with_another_list_as_the_scene_comes_back
    program = program_of do
      screen :tiled
      colors :day, %i[transparent blue blue white]
      colors :dusk, %i[transparent orange red yellow]
      image :sky, width: 8, height: 8, colors: :day, places: [0, 1, 2, 3, 0, 1, 2, 3] * 8
      tiles :skies, "s" => :sky
      state = var :state, 0
      n = var :n, 0
      scene(:outside) do
        sky = background :sky, tiles: :skies, map: { whole: ["s" * 30] * 20, half: ["s" * 15] * 20 }
        (n == 2).then { sky.draw_with :dusk }
        (n == 11).then { sky.show_map :half }
      end
      scene(:inside) { n.add! 0 }
      game_loop do
        case_var :state do
          when_val 0, :outside
          when_val 1, :inside
        end
        (n == 5).then { state.set! 1 }
        (n == 7).then { state.set! 0 }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 15, buttons: {})

    assert_native_matches_reference program, frames: 15, played: moments

    black = Color.resolve(:black)
    shown = ->(*names) { [black, *names.map { |name| Color.resolve(name) }].sort }
    seen = moments.map { |moment| moment.picture.uniq.sort }.chunk_while { |a, b| a == b }.map(&:first)
    assert_equal [[black], shown.(:blue, :white), shown.(:orange, :red, :yellow), [black], shown.(:orange, :red, :yellow)], seen,
                 "nothing before the scene's first frame, then its own colors, the other list's by place, nothing " \
                 "while the scene is away, and the other list's again"
    assert_equal moments[9].picture.count(black) + (15 * 20 * 48), moments.last.picture.count(black),
                 "and the map it is handed last, half as wide, is still drawn in them"
  end

  # A see-through layer on each of two screens that take turns: the game says how see-through
  # both are before every frame, and each scene shows its own.
  def test_a_see_through_layer_on_each_of_two_scenes
    program = program_of do
      screen :tiled
      layers :floor, :water, :glow
      image :slab, "#" => :red, "." => :yellow do "####....\n....####\n" * 4 end
      image :wave, "~" => :blue, "." => :transparent do "~~~~~~..\n" * 8 end
      image :ray, "r" => :white, "." => :transparent do "..rr....\n" * 8 end
      tiles :slabs, "#" => :slab
      tiles :waves, "~" => :wave
      tiles :rays, "r" => :ray
      state = var :state, 0
      n = var :n, 0
      layer(:floor) { background :slabs, tiles: :slabs, map: ["#" * 30] * 20 }
      scene(:pool) { layer(:water, transparency: 50) { background :waves, tiles: :waves, map: ["~" * 30] * 20 } }
      scene(:shrine) { layer(:glow, shows: 20 + (n * 5), shows_behind: 100) { background :rays, tiles: :rays, map: ["r" * 30] * 20 } }
      game_loop do
        case_var :state do
          when_val 0, :pool
          when_val 1, :shrine
        end
        (n == 3).then { state.set! 1 }
        (n == 7).then { state.set! 0 }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 11, buttons: {})

    assert_native_matches_reference program, frames: 11

    assert_operator moments.map(&:picture).uniq.length, :>=, 5, "the pool, then the shrine's glow growing, then the pool again"
  end

  # Every row of a background sits its own distance across, read from a table the game moves
  # along each frame. Nothing else in the game draws or moves, and the ground behind is still.
  def test_a_background_bends_row_by_row_and_the_bend_travels
    program = program_of do
      screen :tiled
      image :turf, "#" => :green, "o" => :yellow do "#o######\n" * 8 end
      image :reed, "|" => :white, "~" => :blue, "." => :transparent do "~|~~....\n" * 8 end
      tiles :ground, "#" => :turf
      tiles :water, "~" => :reed
      background :ground, tiles: :ground, map: ["#" * 30] * 20
      water = background :water, tiles: :water, map: ["~ ~~ ~~~ ~~~~"] * 24
      sway = table :sway, [0, 1, 3, 6, -2, -5, 0, 2]
      phase = var :phase, 0
      water.scroll_each_row { |row| sway[(row + phase) % 8] }
      game_loop { phase.add! 1 }
    end

    moments = reference_snapshots(program, frames: 9, buttons: {})

    assert_native_matches_reference program, frames: 9

    top_rows = moments.last.picture.each_slice(WIDTH).first(8)

    assert_operator top_rows.uniq.length, :>=, 5, "rows drawn from the same row of art should sit at different places across"
    after_the_first_pass = at_frames(moments).drop(2).map(&:picture)

    assert_equal after_the_first_pass.length, after_the_first_pass.uniq.length, "and the bend should be somewhere new on every frame"
  end

  # A game whose frames end while drawing is held inside an area shows the whole picture all the
  # same, the window moved over all of it: the area holds where drawing lands, not what is shown.
  def test_a_frame_that_ends_inside_an_area_shows_the_whole_picture
    program = program_of do
      screen :bitmap
      clear_screen :blue
      fill_rect 0, 0, 20, 20, :red
      n = var :n, 0
      inside(40, 30, 100, 60) do
        game_loop do
          camera n % 8, 0
          fill_rect 0, 0, 240, 160, :green
          n.add! 1
        end
      end
    end

    last = assert_native_matches_reference program, frames: 6

    assert_equal Color.resolve(:blue), last.picture[(120 * WIDTH) + 30], "outside the area, the picture as it was"
    assert_equal Color.resolve(:green), last.picture[(50 * WIDTH) + 60], "inside it, what the game drew there"
  end

  # A game that never waits for the screen has no gap between frames, and its bend's lines are
  # worked out as they are painted, as the console works each line out as it draws it.
  def test_a_game_with_no_frames_is_bent_too
    program = program_of do
      screen :tiled
      image :reed, "|" => :white, "~" => :blue, "." => :transparent do "~|~~....\n" * 8 end
      tiles :water, "~" => :reed
      background(:water, tiles: :water, map: ["~ ~~ ~~~ ~~~~"] * 24).scroll_each_row { |row| row % 8 }
      halt
    end

    last = assert_native_matches_reference program, frames: 1
    rows_unlike_the_one_above = last.picture.each_slice(WIDTH).each_cons(2).count { |above, row| above != row }

    assert_operator rows_unlike_the_one_above, :>=, 100, "the rows should be bent"
  end

  # A run's moments at its frame boundaries, without the one at its end: a run stops at a frame
  # boundary before a bend's rows are worked out there, so the end shows the last boundary's bend
  # and has asked no block since it.
  private def at_frames(moments) = moments.take_while { |moment| moment.heading != "end" }

  # The block that bends the water also counts each time it is asked: once for every row in the
  # gap between frames, as the console works its rows out, however often the picture is built —
  # and on the screen that does not show the water too, since the console works every bend out
  # every frame. The water is scrolled as well as bent, by rows that sit further across than the
  # grid is wide and below nought.
  def test_a_bend_is_worked_out_once_a_frame
    program = program_of do
      screen :tiled
      image :turf, "#" => :green, "o" => :yellow do "#o######\n" * 8 end
      image :reed, "|" => :white, "~" => :blue, "." => :transparent do "~|~~....\n" * 8 end
      image :ball, "o" => :red, "." => :transparent do "..oooo..\n" * 8 end
      tiles :ground, "#" => :turf
      tiles :water, "~" => :reed
      asked = var :asked, 0
      state = var :state, 0
      n = var :n, 0
      ball = sprite :ball, at: [20, 60]
      scene(:lake) do
        water = background :water, tiles: :water, map: ["~ ~~ ~~~ ~~~~"] * 24
        water.scroll_each_row do |row|
          asked.add! 1
          ((row * 37) % 700) - 300 + n
        end
        water.scroll_by(-5, 3)
      end
      scene(:shore) { background :ground, tiles: :ground, map: ["# ##"] * 20 }
      game_loop do
        case_var :state do
          when_val 0, :lake
          when_val 1, :shore
        end
        ball.move :right, by: 3
        (n == 3).then { state.set! 1 }
        (n == 6).then { state.set! 0 }
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 10, buttons: {})

    assert_native_matches_reference program, frames: 10

    counts = at_frames(moments).map { |moment| moment.variables[:asked] }
    asked_in_pass = counts.each_cons(2).map { |before, after| after - before }

    assert_includes moments.map { |moment| moment.variables[:state] }, 1, "the run should go to the shore and back"
    assert_equal [160], asked_in_pass.uniq, "160 a pass, the shore's passes too: #{counts.inspect}"
  end

  # A bend said twice for one background: the second stands and the first never runs. The one
  # that stands asks whether two sprites touch. A third is written for a background that is not
  # there (as the statement itself, since the builder has no way to say it) and never runs
  # either. The routines the two that never run would have called are called by nothing else.
  def test_only_the_bend_that_stands_is_asked
    program = program_of do
      screen :tiled
      image :reed, "|" => :white, "~" => :blue, "." => :transparent do "~|~~....\n" * 8 end
      image :ball, "o" => :red, "." => :transparent do "..oooo..\n" * 8 end
      tiles :water, "~" => :reed
      water = background :water, tiles: :water, map: ["~ ~~ ~~~ ~~~~"] * 24
      ball = sprite :ball, at: [20, 60]
      coin = sprite :ball, at: [60, 62]
      replaced = var :replaced, 0
      nowhere = var :nowhere, 0
      touching = var :touching, 0
      var :ghost_row, 0
      lonely = table :lonely, [4, 9, 2, 7]
      func(:count_replaced) { replaced.add! 1 }
      func(:count_nowhere) { nowhere.add! 1 }
      water.scroll_each_row do |row|
        call :count_replaced
        lonely[row % 4]
      end
      water.scroll_each_row do |row|
        ball.overlaps?(coin).then { touching.add! 1 }
        (row % 6) + touching
      end
      build = RubyGBA::IR::Build
      record_statement(build.scroll_rows(:nothing_by_this_name, row: :ghost_row, offset: build.int(3), body: [build.call(:count_nowhere)]))
      game_loop { ball.move :right, by: 4 }
    end

    moments = reference_snapshots(program, frames: 14, buttons: {})

    assert_native_matches_reference program, frames: 14

    touching = moments.map { |moment| moment.variables[:touching] }

    assert_operator touching.last, :>, 0, "the bend that stands should have found the sprites touching: #{touching.inspect}"
    assert_equal touching.last, touching[-2], "and apart again by the end: #{touching.inspect}"
    assert_equal [0, 0], moments.last.variables.values_at(:replaced, :nowhere), "the other two should never have run"
  end

  # A background too big for the console's grid, bent. The builder refuses a game that says
  # both, so the bend is written here as the statement itself; the interpreter draws one, with
  # every row worked out once a frame like any bend, and so must the C.
  def test_a_background_bigger_than_the_grid_is_bent_too
    program = program_of do
      screen :tiled
      image :reed, "|" => :white, "~" => :blue, "." => :transparent do "~|~~....\n" * 8 end
      tiles :water, "~" => :reed
      water = background :water, tiles: :water, map: ["~ ~~ ~~~ ~~~~" * 6] * 70
      var :asked, 0
      var :row, 0
      n = var :n, 0
      build = RubyGBA::IR::Build
      record_statement(build.scroll_rows(:water, row: :row,
                                                 offset: build.binop(:-, build.binop(:*, build.var_ref(:row), build.int(3)), build.int(200)),
                                                 body: [build.add(:asked, build.int(1))]))
      game_loop do
        water.scroll_to (n * 40) - 60, (n * 90) - 100
        n.add! 1
      end
    end

    moments = reference_snapshots(program, frames: 9, buttons: {})

    assert_native_matches_reference program, frames: 9

    asked_each_frame = at_frames(moments).map { |moment| moment.variables[:asked] }.each_cons(2).map { |before, after| after - before }

    assert_equal [160], asked_each_frame.uniq, "every row once a frame, however much of the map is in view"
    # Every row of the map and of its art is the same, so unbent the rows of the screen it
    # covers would all match the row above.
    rows_unlike_the_one_above = moments.map { |moment| moment.picture.each_slice(WIDTH).each_cons(2).count { |above, row| above != row } }

    assert_operator rows_unlike_the_one_above.max, :>=, 150, "each row should sit further across than the one above: #{rows_unlike_the_one_above.inspect}"
  end

  # TILES THE GAME PAINTS AS IT RUNS, in a scene's own background that scrolls. Nothing shows
  # until the game says its list changed; what it paints shows the frame after; a write it never
  # says does not; drawn with another list the same pixels change color by place; and the scene
  # coming back shows the list as it is by then, the unsaid write included.
  def test_tiles_painted_from_a_list_show_when_the_game_says_they_changed
    program = program_of do
      screen :tiled
      colors :ink, %i[transparent white red blue]
      colors :dusk, %i[transparent yellow green cyan]
      colors :stone, %i[transparent gray]
      image(:wall, colors: :stone, "#" => :gray) { SOLID_TILE }
      sheet = list :sheet, capacity: 96, width: :byte
      repeat(96) { sheet.push 0 }
      state = var :state, 0
      n = var :n, 0
      scene(:room) do
        board = tiles :board, from: sheet, count: 3, colors: :ink, "#" => :wall
        room = background :room, tiles: :board, map: [[1, 2, "#", 3], ["#", 3, 2, 1]] * 2
        room.scroll_to n, 2
        (n == 2).then do
          repeat(32) { |i| sheet[i] = 0x21 }
          sheet[40] = 0x33
          board.changed
        end
        (n == 4).then { sheet[70] = 0x12 }
        room.draw_with({ ink: [:dusk] }, showing: n - 6)
        (n == 8).then { state.set! 1 }
      end
      scene(:hall) { (n == 11).then { state.set! 0 } }
      game_loop do
        n.add! 1
        case_var(:state) { when_val 0, :room; when_val 1, :hall }
      end
    end

    moments = reference_snapshots(program, frames: 15, buttons: {})

    assert_native_matches_reference program, frames: 15

    colors_shown = moments.map { |moment| moment.picture.uniq.sort }

    assert_operator colors_shown[2].length, :<, colors_shown[4].length, "nothing painted shows before the game says so"
    assert_includes colors_shown[4], Color.resolve(:red), "the list's own colors once it has"
    assert_includes colors_shown[7], Color.resolve(:green), "and the other list's by place when it is drawn with that"
    refute_equal moments[5].picture, moments[14].picture, "the scene came back with the write the game never said"
  end

  # A SPRITE'S PICTURE THE GAME PAINTS, and a canvas drawn into with its words. The picture is
  # shown by two sprites, one of them drawn with another list of colors, and is see-through all
  # over until its first copy. The canvas is cleared, filled, lettered and dotted on different
  # frames, a sprite's picture too.
  def test_a_painted_sprite_picture_and_a_canvas_drawn_with_words
    program = program_of do
      screen :tiled
      colors :ink, %i[transparent white red blue]
      colors :hurt, %i[transparent yellow green cyan]
      image(:floor, "#" => :gray) { SOLID_TILE }
      tiles :floors, "#" => :floor
      background :floor, tiles: :floors, map: ["#" * 30] * 20
      sheet = list :sheet, capacity: 64, width: :byte
      repeat(64) { sheet.push 0 }
      tag = image :tag, from: sheet, width: 16, height: 8, colors: :ink
      first = sprite :tag, at: [40, 20]
      label = canvas :label, width: 32, height: 16, colors: :ink, as: :sprite
      sprite :label, at: [100, 60]
      n = var :n, 0
      game_loop do
        n.add! 1
        (n == 2).then do
          repeat(64) { |i| sheet[i] = 0x10 + (i % 3) }
          tag.changed
        end
        (n == 4).then { first.draw_with :hurt }
        first.move :right, by: 3
        (n == 3).then { label.fill_rect 1, 1, 9, 5, :red }
        (n == 5).then { label.draw_text "HI", 12, 2, :white }
        (n == 7).then { label.pixel 30, 14, :blue }
        (n == 9).then { label.clear :blue }
      end
    end

    moments = reference_snapshots(program, frames: 11, buttons: {})

    assert_native_matches_reference program, frames: 11

    colors_shown = moments.map { |moment| moment.picture.uniq.sort }

    assert_equal [Color.resolve(:gray)], colors_shown[1], "nothing painted shows at first"
    assert_includes colors_shown[3], Color.resolve(:red), "the picture's own colors after its first copy"
    assert_includes colors_shown[5], Color.resolve(:green), "another list's once the sprite is drawn with it"
    assert_includes colors_shown[6], Color.resolve(:white), "letters drawn into the canvas"
    assert_operator moments[10].picture.count(Color.resolve(:blue)), :>=, 32 * 16, "and the canvas cleared to one color"
  end

  # A LIST OF COLORS THAT HOLDS OTHER COLORS AS THE GAME RUNS. Two sprites are drawn with the
  # slot and a third with a plain list beside it; the slot is told each of its sets by number,
  # then a number that names none, which is the colors it was declared with.
  def test_a_list_of_colors_told_to_hold_others_recolors_what_is_drawn_with_it
    program = program_of do
      screen :tiled
      image :ship, width: 8, height: 8, data: Array.new(64, :red), colors: %i[transparent red]
      image :rock, width: 8, height: 8, data: Array.new(64, :red), colors: %i[transparent red]
      colors :slot, %i[transparent blue]
      colors :warm, %i[transparent yellow]
      colors :cold, %i[transparent cyan]
      colors :plain, %i[transparent white]
      ship = sprite :ship, at: [40, 40]
      rock = sprite :rock, at: [80, 40]
      other = sprite :ship, at: [120, 40]
      n = var :n, 0
      game_loop do
        n.add! 1
        ship.draw_with [:plain, :slot], showing: n / 6
        rock.draw_with :slot
        (n == 9).then { other.draw_with :plain }
        recolor :slot, %i[warm cold], showing: (n / 2) - 1
      end
    end

    moments = reference_snapshots(program, frames: 14, buttons: {})

    assert_native_matches_reference program, frames: 14

    rock_colors = moments.map { |moment| moment.picture[(44 * WIDTH) + 84] }.uniq

    assert_empty %i[blue yellow cyan].map { |name| Color.resolve(name) } - rock_colors,
                 "the slot should have held its own colors and each of the others: #{rock_colors.inspect}"
    assert_equal Color.resolve(:blue), moments.last.picture[(44 * WIDTH) + 84], "and its own again for a number naming no set"
    ship_colors = moments.map { |moment| moment.picture[(44 * WIDTH) + 44] }.uniq

    assert_operator ship_colors.length, :>=, 3, "the ship went through the plain list and then the slot: #{ship_colors.inspect}"
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
