# frozen_string_literal: true

require "test_helper"

# What a Super Nintendo cartridge draws on a tiled screen is what the interpreter draws, pixel for
# pixel, after every pass (SNES::CheckedRun): its backgrounds — put up, scrolled, a cell changed, a
# map handed over — and its sprites, moving, off every edge and back. Colours are picked so that a
# tile drawn from the wrong palette or a sprite one row out shows as a pixel in the wrong place.
class TestSNESPicture < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  def test_a_sprite_moving_off_every_edge_is_drawn_where_the_interpreter_draws_it
    run = checked(frames: 100) do
      screen :tiled
      image :ship, "." => :transparent, "r" => :red, "g" => :green, "b" => :blue, "w" => :white do
        <<~ART
          rrrrrrrrgggggggg
          r..............g
          r..wwww........g
          r..............g
          bbbbbbbbbbbbbbbb
        ART
      end
      ship = sprite :ship, at: [0, 0]
      x = var :x, -20
      y = var :y, -10
      laps = var :laps, 0
      game_loop do
        x.add! 7
        y.add! 6
        (x > 270).then do
          x.set! -30
          laps.add! 1
        end
        (y > 236).then { y.set! -12 }
        ship.move_to x, y
      end
    end

    assert_operator run[:laps], :>=, 2, "the ship went off the right edge and came back from the left twice"
  end

  # Two backgrounds, the front one see-through in places, and cells changed on both: on the back
  # one's 64×64 map, cells in each of its four 32×32 screens, scrolled into view.
  def test_two_backgrounds_and_cells_in_every_screen_of_a_big_map
    big = "#{(['#' * 64] * 64).join("\n")}\n"
    run = SNES::CheckedRun.new
    run.input_each_frame { |frame| frame == 3 ? [:a] : [] }
       .run(program_of do
         screen :tiled
         image(:wall, "#" => :gray) { "########\n" * 8 }
         image(:hole, "." => :transparent, "o" => :red) { "o......o\n" * 8 }
         image(:gem, "g" => :green) { "gggggggg\n" * 8 }
         tiles :back, "#" => :wall, "g" => :gem
         tiles :front, "o" => :hole, "g" => :gem
         back = background :back, tiles: :back, map: big
         front = background :front, tiles: :front, map: "#{'o' * 32}\n" * 32
         changed = var :changed, 0
         game_loop do
           pressed(:a).then do
             back.set_tile 40, 40, "g"
             back.set_tile 33, 2, "g"
             back.set_tile 2, 35, "g"
             front.set_tile 3, 3, "g"
             changed.set! 1
           end
           back.scroll_to 200, 200
         end
       end, frames: 8)

    assert_equal 1, run[:changed]
  end

  def test_several_sprites_overlap_the_later_one_in_front
    run = checked(frames: 12) do
      screen :tiled
      image(:block, "#" => :yellow) { "########\n" * 8 }
      image(:bar, "#" => :magenta) { "################\n" * 4 }
      a = sprite :block, at: [20, 20]
      b = sprite :bar, at: [16, 22]
      t = var :t, 0
      game_loop do
        t.add! 1
        a.move_to 20 + t, 20
        b.move_to 16 + t, 22
      end
    end

    # The bar, declared second, crosses the block's middle: where they overlap it is the bar's.
    assert_equal Color.resolve(:magenta), run.screen.pixel(34, 23)
  end

  def test_a_background_put_up_scrolled_changed_and_handed_another_map
    run = SNES::CheckedRun.new
    run.input_each_frame { |frame| frame == 5 ? [:a] : (frame == 9 ? [:b] : []) }
       .run(program_of do
         screen :tiled
         image :wall, "#" => :gray, "." => rgb(10, 3, 3) do
           "#.######\n" + ("########\n" * 6) + ".######.\n"
         end
         image :water, "~" => :blue, "=" => rgb(12, 12, 31) do
           "~~==~~~~\n" * 8
         end
         tiles :set, "#" => :wall, "~" => :water
         room = background :room, tiles: :set, map: {
           one: "##########\n#~~~~~~~~#\n#~~~##~~~#\n##########\n",
           two: "~~~~~~~~~~\n~########~\n~~~~~~~~~~\n~~~~~~~~~~\n"
         }
         x = var :x, 0
         game_loop do
           x.add! 3
           room.scroll_to x, x / 2
           pressed(:a).then { room.set_tile 2, 1, "#" }
           pressed(:b).then { room.show_map 1 }
         end
       end, frames: 14)

    assert_operator run[:x], :>, 0
  end

  # A 64×64 map is 8192 bytes of video RAM, two blanks' worth and more, handed to a background in
  # one pass. It arrives over several blanks with the screen on, and no frame is black: the checked
  # run holds each pass's picture to the interpreter's, and the frames between are read one by one.
  # The view is on the map's last quarter, the last piece copied, so a piece written after its
  # blank ended, and lost, shows as a picture that differs.
  def test_a_big_map_handed_to_a_background_shows_no_black_frame
    program = program_of do
      screen :tiled
      image(:wall, "#" => :gray) { "########\n" * 8 }
      image(:gem, "g" => :green) { "gggggggg\n" * 8 }
      tiles :set, "#" => :wall, "g" => :gem
      room = background :room, tiles: :set, map: { walls: "#{'#' * 64}\n" * 64, gems: "#{'g#' * 32}\n" * 64 }
      game_loop do
        room.scroll_to 260, 280
        pressed(:a).then { room.show_map 1 }
      end
    end
    press = ->(frame) { frame == 3 ? [:a] : [] }
    SNES::CheckedRun.new.input_each_frame(&press).run(program, frames: 8)
    run = SNES::HeadlessRun.new(watch_picture: true).input_each_frame(&press).run(program, frames: 8)

    assert_operator run.frames_took(4), :>, 1, "the map takes more than one blank"
    assert_empty run.black_frames
  end

  # Each changed cell is a word written on its own, and 200 of them take longer than a blank.
  def test_many_cells_changed_in_one_pass_show_no_black_frame
    program = program_of do
      screen :tiled
      image(:wall, "#" => :gray) { "########\n" * 8 }
      image(:gem, "g" => :green) { "gggggggg\n" * 8 }
      tiles :set, "#" => :wall, "g" => :gem
      room = background :room, tiles: :set, map: "#{'#' * 32}\n" * 32
      i = var :i, 0
      game_loop do
        pressed(:a).then do
          i.set! 0
          repeat(200) do
            room.set_tile i % 25, i / 25, "g"
            i.add! 1
          end
        end
      end
    end
    press = ->(frame) { frame == 3 ? [:a] : [] }
    SNES::CheckedRun.new.input_each_frame(&press).run(program, frames: 8)
    run = SNES::HeadlessRun.new(watch_picture: true).input_each_frame(&press).run(program, frames: 8)

    assert_empty run.black_frames
  end

  # A STATUS BAR shows from its top row to the bottom of the screen, over a field that scrolls under
  # it and is hidden there: the bar's see-through pixels, and its rows past its two, show the
  # backdrop. A sprite goes over it. The bar is moved each pass, to rows either side of 127 (the
  # most one step of the console's line table counts), to the top, past the bottom and above it,
  # and a cell of it changes.
  def test_a_status_bar_hides_the_field_under_it_wherever_it_is_put
    run = checked(frames: 14) do
      screen :tiled
      image(:dark, "#" => :blue) { "########\n" * 8 }
      image(:star, "#" => :yellow, "." => :blue) { "........\n...#....\n..###...\n...#....\n" + ("........\n" * 4) }
      image(:edge, "#" => :gray) { "########\n" * 8 }
      image(:pip, "#" => :green, "." => :transparent) { "..##....\n" * 8 }
      image(:ball, "#" => :white) { "####\n" * 4 }
      tiles :field_tiles, "." => :dark, "*" => :star
      tiles :bar_tiles, "[" => :edge, "o" => :pip
      field = background :field, tiles: :field_tiles, map: Array.new(32) { |row| (0...32).map { |col| (row + col) % 5 == 0 ? "*" : "." }.join }
      bar = status_bar :score, tiles: :bar_tiles, map: ["[oooo[", "[[[[[["], top: 200
      ball = sprite :ball, at: [20, 190]
      tops = table :tops, [200, 0, 127, 128, 150, 224, 300, -5, 60, 126, 223]
      t = var :t, 0
      game_loop do
        field.scroll_by 1, -1
        ball.move_to 20 + (t * 3), 190
        bar.move_to tops[t % 11]
        (t == 4).then { bar.set_tile 2, 0, "[" }
        t.add! 1
      end
    end

    assert_equal 14, run[:t]
  end

  # A bar that a scene puts up, and takes down when another scene takes over, is not made yet.
  def test_a_status_bar_that_a_scene_puts_up_is_refused_in_plain_words
    error = assert_raises(SNES::Lowering::NotMadeYet) do
      SNES.new.build(program_of do
        screen :tiled
        image(:edge, "#" => :gray) { "########\n" * 8 }
        tiles :bar_tiles, "[" => :edge
        state = var :state, 0
        scene(:play) { status_bar :score, tiles: :bar_tiles, map: ["[["], top: 200 }
        game_loop { case_var(:state) { when_val 0, :play } }
        state.set! 0
      end)
    end

    assert_match(/status bar that a scene puts up/, error.message)
  end

  # BACKGROUNDS IN LAYERS are stacked as the layers say, not as they were declared: the near one is
  # declared first and still drawn in front, its see-through cells showing the far one behind, both
  # scrolling at their own speeds, and a sprite that names no layer in front of both.
  def test_backgrounds_in_layers_are_stacked_as_the_layers_say
    run = checked(frames: 10) do
      screen :tiled
      image(:sky, "#" => :blue) { "########\n" * 8 }
      image(:cloud, "#" => :white, "." => :blue) { "..####..\n" * 8 }
      image(:grass, "#" => :green) { "########\n" * 8 }
      image(:tree, "." => :transparent, "L" => :yellow) { "..LLLL..\n" * 8 }
      image(:ball, "#" => :red) { "####\n" * 4 }
      tiles :heavens, "." => :sky, "c" => :cloud
      tiles :scenery, "g" => :grass, "T" => :tree
      layers :distance, :foreground
      near = layer(:foreground) do
        background :ground, tiles: :scenery,
                            map: Array.new(32) { |row| row > 20 ? "g" * 32 : (row == 20 ? ("T  " * 11)[0, 32] : " " * 32) }
      end
      far = layer(:distance) do
        background :sky, tiles: :heavens, map: Array.new(32) { |row| (0...32).map { |col| (row + col) % 7 == 0 ? "c" : "." }.join }
      end
      ball = sprite :ball, at: [40, 150]
      t = var :t, 0
      game_loop do
        far.scroll_by 1, 0
        near.scroll_by 2, 0
        ball.move_to 40 + t, 155
        t.add! 1
      end
    end

    assert_equal 10, run[:t]
  end

  # SPRITES IN LAYERS, between the backgrounds: a walker in front of the floor and behind a fence
  # of bars with gaps, a bird in front of everything, and a mole behind both backgrounds, seen
  # only through a hole in the floor where the fence has a gap too. Each crosses the others.
  def test_sprites_in_layers_go_behind_the_backgrounds_in_front_of_them
    run = checked(frames: 12) do
      screen :tiled
      image(:dirt, "#" => :gray, "." => :transparent) { "########\n" * 8 }
      image(:hole, "#" => :gray, "." => :transparent) { "##....##\n" * 8 }
      image(:bars, "#" => :blue, "." => :transparent) { "##..##..\n" * 8 }
      image(:walker, "#" => :red) { "########\n" * 8 }
      image(:bird, "#" => :yellow) { "####\n" * 4 }
      image(:mole, "#" => :green) { "########\n" * 8 }
      tiles :ground, "#" => :dirt, "o" => :hole
      tiles :fencing, "|" => :bars
      layers :under, :floor, :walkers, :fence, :sky
      mole = layer(:under) { sprite :mole, at: [20, 40] }
      layer(:floor) { background :floor, tiles: :ground, map: Array.new(32) { |row| row == 5 ? "#####o" + ("#" * 26) : "#" * 32 } }
      walker = layer(:walkers) { sprite :walker, at: [10, 40] }
      layer(:fence) { background :fence, tiles: :fencing, map: Array.new(32) { "|" * 32 } }
      bird = layer(:sky) { sprite :bird, at: [60, 42] }
      t = var :t, 0
      game_loop do
        walker.move_to 10 + (t * 3), 40
        bird.move_to 60 - (t * 3), 42
        mole.move_to 36 + t, 38 + t
        t.add! 1
      end
    end

    assert_equal 12, run[:t]
  end

  # A sprite the game puts in another layer as it runs is not made yet.
  def test_a_sprite_moved_between_layers_as_the_game_runs_is_refused_in_plain_words
    error = assert_raises(SNES::Lowering::NotMadeYet) do
      SNES.new.build(program_of do
        screen :tiled
        image(:wall, "#" => :gray) { "########\n" * 8 }
        image(:ball, "#" => :red) { "####\n" * 4 }
        tiles :set, "#" => :wall
        layers :back, :actors, :front
        layer(:back) { background :floor, tiles: :set, map: ["##"] }
        layer(:front) { background :roof, tiles: :set, map: ["##"] }
        ball = layer(:actors) { sprite :ball, at: [0, 0] }
        game_loop { ball.put_in_layer :front }
      end)
    end

    assert_match(/another layer as the game runs/, error.message)
  end

  # A scene's own background goes on the front layer, so one the layers put behind a background
  # every screen shows is not made yet.
  def test_a_scenes_background_behind_one_every_screen_shows_is_refused_in_plain_words
    error = assert_raises(SNES::Lowering::NotMadeYet) do
      SNES.new.build(program_of do
        screen :tiled
        image(:wall, "#" => :gray) { "########\n" * 8 }
        tiles :set, "#" => :wall
        layers :back, :front
        layer(:front) { background :frame, tiles: :set, map: ["##"] }
        state = var :state, 0
        scene(:play) { layer(:back) { background :room, tiles: :set, map: ["##"] } }
        game_loop { case_var(:state) { when_val 0, :play } }
      end)
    end

    assert_match(/behind a background every screen shows/, error.message)
  end

  # A BACKGROUND BENT ROW BY ROW: each of the screen's rows shown at its own sideways offset, worked
  # out by the game at every frame boundary for the frame after, on top of the layer's own scroll.
  # The block counts its rows too, which the checked run holds to the interpreter's count: 224 at
  # each boundary. The other layer stays flat.
  def test_a_background_bent_row_by_row_shows_each_row_where_the_interpreter_does
    run = checked(frames: 8) do
      screen :tiled
      image(:water, "~" => :blue, "|" => :white) { "~~|~~~~~\n~~~~~~|~\n" * 4 }
      image(:sky, "#" => :cyan, "o" => :yellow) { "##o#####\n" * 8 }
      tiles :below, "~" => :water
      tiles :above, "#" => :sky
      sky = background :sky, tiles: :above, map: Array.new(32) { "#" * 32 }
      water = background :water, tiles: :below, map: Array.new(32) { |row| row < 10 ? " " * 32 : "~" * 32 }
      ripple = table :ripple, (0...16).map { |i| (Math.sin(i * 2 * Math::PI / 16) * 5).round }
      phase = var :phase, 0
      rows = var :rows, 0
      water.scroll_each_row do |row|
        rows.add! 1
        ripple[(row - phase) % 16]
      end
      game_loop do
        phase.add! 1
        water.scroll_by 3, 0
        sky.scroll_by 1, 0
      end
    end

    assert_equal 224 * 8, run[:rows]
  end

  # The bend is worked out for all 224 rows at every boundary, so what each row costs is paid 224
  # times a pass. A ripple read from a table at the row less the phase, wrapped to sixteen, fits two
  # frames.
  def test_a_rippling_bend_keeps_up_with_the_screen
    program = program_of do
      screen :tiled
      image(:water, "~" => :blue, "|" => :white) { "~~|~~~~~\n~~~~~~|~\n" * 4 }
      tiles :below, "~" => :water
      water = background :water, tiles: :below, map: Array.new(32) { "~" * 32 }
      ripple = table :ripple, (0...16).map { |i| (Math.sin(i * 2 * Math::PI / 16) * 5).round }
      phase = var :phase, 0
      water.scroll_each_row { |row| ripple[(row - phase) % 16] }
      game_loop { phase.add! 1 }
    end
    run = SNES::HeadlessRun.new.run(program, frames: 6)

    assert_operator (2..6).map { |pass| run.frames_took(pass) }.max, :<=, 2
  end

  # A scene's own background is on a layer another scene's background takes in turn, so bending
  # one row by row is not made yet.
  def test_a_bent_background_that_a_scene_puts_up_is_refused_in_plain_words
    error = assert_raises(SNES::Lowering::NotMadeYet) do
      SNES.new.build(program_of do
        screen :tiled
        image(:wall, "#" => :gray) { "########\n" * 8 }
        tiles :set, "#" => :wall
        state = var :state, 0
        scene(:play) { background(:room, tiles: :set, map: ["##"]).scroll_each_row { |row| row % 3 } }
        game_loop { case_var(:state) { when_val 0, :play } }
      end)
    end

    assert_match(/bent row by row that a scene puts up/, error.message)
  end

  # TILES PAINTED FROM A LIST: each byte two pixels, the left one in the low four bits, each four
  # bits a place in the run's colours. The bytes are written so every place shows at every pixel of
  # a row over the passes, and the copy is owed, so it arrives in the gap after the pass that said
  # `changed`. A second run's list holds fewer bytes than its tiles, so the rest is see-through; it
  # shrinks now and then too, leaving bytes past its end that must not show.
  def test_tiles_painted_from_a_list_show_what_the_list_holds
    run = checked(frames: 10) do
      screen :tiled
      colors = [:transparent, :red, :green, :blue, :yellow, :white, :cyan, :magenta, :gray,
                rgb(31, 16, 0), rgb(16, 0, 31), rgb(0, 16, 16), rgb(20, 20, 4), rgb(4, 20, 20), rgb(28, 8, 8),
                rgb(8, 28, 8)]
      pixels = list :pixels, capacity: 64, width: :byte
      short = list :short, capacity: 32, width: :byte
      image(:floor, "#" => :black) { "########\n" * 8 }
      painted = tiles :painted, from: pixels, count: 2, colors: colors, "#" => :floor
      partial = tiles :partial, from: short, count: 1, colors: %i[transparent orange white]
      background :under, tiles: :painted, map: [[1, 2, "#"], ["#", "#", "#"]]
      background :over, tiles: :partial, map: [[nil, nil, nil], [1, nil, nil]]
      64.times { pixels.push 0 }
      t = var :t, 0
      i = var :i, 0
      game_loop do
        i.set! 0
        repeat(64) do
          pixels[i] = (i * 17) + (t * 33)
          i.add! 1
        end
        painted.changed
        (t < 20).then { short.push ((t % 2) + 1) + 32 } # places 1 or 2, then 2: never see-through
        (t % 3 == 2).then { short.pop }
        partial.changed
        t.add! 1
      end
    end

    assert_equal 10, run[:t]
  end

  # A sprite's picture painted from a list (a canvas a sprite shows), and a canvas shown at once
  # (`changed now: true`), whose pixels are in the pass that drew them.
  def test_a_sprites_picture_and_a_canvas_changed_now_show_what_was_painted
    run = checked(frames: 8) do
      screen :tiled
      tag = canvas :tag, width: 16, height: 16, colors: %i[transparent white green], as: :sprite
      board = canvas :board, width: 32, height: 8, colors: %i[transparent yellow]
      background :board_bg, tiles: :board, map: board.cells
      mark = sprite :tag, at: [40, 40]
      t = var :t, 0
      game_loop do
        tag.pixel (t * 5) % 16, (t * 3) % 16, :green
        board.fill_rect t * 3, 2, 3, 3, :yellow
        board.changed now: true
        mark.move_to 40 + t, 40
        t.add! 1
      end
    end

    assert_equal 8, run[:t]
  end

  # A canvas a sprite shows, with a plain sprite declared before it: each shows its own picture.
  # The canvas's picture is made first, so the pictures' numbers are not the order the sprites
  # name them in, and each sprite's table says the number the picture was made with.
  def test_a_canvas_sprite_after_a_plain_one_shows_its_own_picture
    run = checked(frames: 4) do
      screen :tiled
      image(:ball, "#" => :red) { "########\n" * 8 }
      ball = sprite :ball, at: [10, 10]
      tag = canvas :tag, width: 16, height: 16, colors: %i[transparent white green], as: :sprite
      sprite :tag, at: [40, 40]
      t = var :t, 0
      game_loop do
        tag.pixel t, t, :green
        ball.move_to 10 + t, 10
        t.add! 1
      end
    end

    assert_equal 4, run[:t]
  end

  # A canvas a sprite shows can be any size in whole 8×8 pieces on a Super Nintendo, which cuts
  # every sprite's picture into pieces: hero's sign box, 192×16, typed into a letter at a time.
  def test_a_canvas_sprite_of_any_size_in_whole_pieces_shows_what_was_painted
    run = checked(frames: 6, built_for: :snes) do
      screen :tiled
      box = canvas :box, width: 192, height: 16, colors: %i[transparent white blue], as: :sprite
      sprite :box, at: [24, 144]
      t = var :t, 0
      game_loop do
        (t == 0).then { box.clear :blue }
        box.fill_rect 4 + (t * 30), 4, 20, 8, :white
        t.add! 1
      end
    end

    assert_equal 6, run[:t]
  end

  # ...and a side that is not whole pieces is refused, saying what to make it.
  def test_a_canvas_sprite_not_in_whole_pieces_is_refused_in_plain_words
    error = assert_raises(ArgumentError) do
      program_of(built_for: :snes) do
        screen :tiled
        canvas :box, width: 100, height: 16, colors: %i[transparent white], as: :sprite
        game_loop { wait_vblank }
      end
    end

    assert_match(/100x16.*multiple of 8/, error.message)
  end

  # A SPRITE DRAWN WITH OTHER COLOURS (`draw_with`), as pacman flashes when caught: each place of
  # the picture's own list shows the colour at the same place of the list it is drawn with, one
  # of two lists picked by a number the game works out, and its own colours again with `:own`. A
  # second sprite shows the same picture in its own colours throughout, and the reader of the
  # drawn sprites names the picture each shows.
  def test_a_sprite_drawn_with_other_colours_shows_them
    run = checked(frames: 12) do
      screen :tiled
      colors :flash, %i[transparent white blue cyan]
      colors :dim, %i[transparent gray green black]
      face_art = Array.new(256) { |i| %i[yellow red orange][((i % 16) / 4 + (i / 64)) % 3] }
      image :face, width: 16, height: 16, data: face_art, colors: %i[transparent yellow red orange]
      face = sprite :face, at: [20, 20]
      sprite :face, at: [60, 20]
      t = var :t, 0
      game_loop do
        (t < 8).then { face.draw_with %i[flash dim], showing: (t >> 1) & 1 }.else { face.draw_with :own }
        face.move_to 20 + t, 20
        t.add! 1
      end
    end

    assert_equal 12, run[:t]
    assert_equal %i[face face], run.sprites.map(&:picture)
  end

  # A LAYER HALF SEE-THROUGH: colour math adds what is behind it to it and halves the sum, on every
  # pixel where its own is drawn; where its tiles are see-through, what is behind shows plain, and a
  # sprite in front is solid. 55 is half on the interpreter too: what is behind takes its share
  # rounded down to sixteenths, 8. The console halves the channels' sum; the interpreter mixes them
  # widened to eight bits, which is a step higher for some colours (31 and 30 among them, in the
  # white over the gray), so the checked run holds such a game to the interpreter within a step of
  # each channel — and a layer shown whole where it should be halved is far more than a step.
  def test_a_layer_half_see_through_mixes_with_the_background_behind_it
    run = checked(frames: 8) do
      screen :tiled
      image(:ground, "#" => rgb(30, 30, 30), "+" => :blue) { "####++++\n" * 8 }
      image(:mist, "o" => :white, "." => :transparent) { "oooo....\noooooooo\n" * 4 }
      image(:ball, "#" => :red) { "####\n" * 4 }
      tiles :world_tiles, "#" => :ground
      tiles :air_tiles, "o" => :mist
      layers :world, :air
      layer(:world) { background :world, tiles: :world_tiles, map: Array.new(32) { "#" * 32 } }
      air = layer(:air, transparency: 55) do
        background :air, tiles: :air_tiles, map: Array.new(32) { |row| row.even? ? "o" * 32 : "o " * 16 }
      end
      ball = sprite :ball, at: [30, 30]
      t = var :t, 0
      game_loop do
        air.scroll_by 1, 1
        ball.move_to 30 + t, 30
        t.add! 1
      end
    end

    assert_equal 8, run[:t]
  end

  # A LAYER OF SPRITES HALF SEE-THROUGH, as lake's jellyfish are: each is mixed with the scenery
  # behind it, never with another sprite — a ghost passing over the hero hides the hero and shows
  # the floor through itself — and its see-through pixels show what is behind plain. The ghosts
  # take the console's last four sprite palettes, the only ones its colour math reaches.
  def test_a_layer_of_sprites_half_see_through_mixes_with_the_scenery_behind_it
    run = checked(frames: 10) do
      screen :tiled
      image(:ground, "#" => rgb(30, 30, 30), "+" => :blue) { "####++++\n" * 8 }
      image(:hero, "#" => :green) { "########\n" * 8 }
      image(:ghost, "o" => :white, "." => :transparent) { "oooo....\noooooooo\n" * 8 }
      tiles :world_tiles, "#" => :ground
      layers :world, :actors, :ghosts
      floor = layer(:world) { background :world, tiles: :world_tiles, map: Array.new(32) { "#" * 32 } }
      layer(:actors) { sprite :hero, at: [40, 40] }
      ghost = layer(:ghosts, transparency: 50) { sprite :ghost, at: [20, 36] }
      t = var :t, 0
      game_loop do
        floor.scroll_by 1, 0
        ghost.move_to 20 + (t * 3), 36
        t.add! 1
      end
    end

    assert_equal 10, run[:t]
  end

  # The console mixes a layer with what is behind it only by half: other amounts, and amounts the
  # game works out as it runs, are refused in plain words, and so is a see-through layer with
  # nothing that covers the whole screen behind it, where the console would show it whole.
  def test_amounts_the_console_cannot_mix_are_refused_in_plain_words
    {
      "a different amount" => [40, true, /half see-through.*50 to 56/m],
      "an amount worked out as the game runs" => [:game, true, /as the game runs/],
      "nothing covering the screen behind" => [55, false, /covers the whole screen/]
    }.each do |what, (amount, covered, words)|
      error = assert_raises(SNES::LoweringError, what) { SNES.new.build(see_through_game(amount, covered)) }
      assert_match words, error.message, what
    end
  end

  private def see_through_game(amount, covered)
    program_of do
      screen :tiled
      image(:ground, "#" => :gray, "." => :transparent) { covered ? "########\n" * 8 : "####....\n" * 8 }
      image(:mist, "o" => :white) { "oooooooo\n" * 8 }
      tiles :world_tiles, "#" => :ground
      tiles :air_tiles, "o" => :mist
      layers :world, :air
      layer(:world) { background :world, tiles: :world_tiles, map: Array.new(32) { "#" * 32 } }
      mist = var :mist, 0
      transparency = amount == :game ? 100 - mist : amount
      layer(:air, transparency: transparency) { background :air, tiles: :air_tiles, map: ["oo"] }
      game_loop { mist.add! 1 }
    end
  end

  # +built_for+ builds the program as a Super Nintendo game from the start, for what the builder
  # allows on that console alone; otherwise it is built as the Advance's and then named the SNES's.
  private def program_of(built_for: nil, &game)
    builder = built_for ? Builder.new(options: VBlank::Cartridge::Options.new.with(console: built_for)) : Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end

  private def checked(frames: nil, built_for: nil, &game)
    SNES::CheckedRun.new.run(program_of(built_for: built_for, &game), frames: frames)
  end
end
