# frozen_string_literal: true

require "test_helper"
require "differential"

# Drawing the picture in flat blocks, as the display draws it.
#
# The rule is the emulator's, read out of its renderer and then measured on it: the blocks
# are fixed to the SCREEN, and each takes the colour the picture has at the block's top
# left corner. So the thing to assert is that rule against the picture as drawn, and then
# that the console shows the same picture pixel for pixel, which is what keeps the rule
# honest — every place it bends is a place the two would disagree.
class TestPixelate < Minitest::Test
  include Differential

  WIDTH = 240
  HEIGHT = 160

  # Two tiles with nothing flat about them, so a block's colour depends on where it starts.
  STRIPES = (0...8).map { |row| (0...8).map { |col| (col * 3) + row < 9 ? "#" : "." }.join }.join("\n")
  STEPS = (0...8).map { |row| (0...8).map { |col| col > row ? "#" : "." }.join }.join("\n")
  ROOM = (0...32).map { |row| (0...32).map { |col| (((row * 2) + col) % 3).zero? ? "a" : "b" }.join }

  # The two tiles and the set that names them, said inside a game being built.
  ROOM_TILES = proc do
    image(:stripes, "#" => :red, "." => :blue) { STRIPES }
    image(:steps, "#" => :green, "." => :white) { STEPS }
    tiles :set, "a" => :stripes, "b" => :steps
  end

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A room of those tiles, scrolled off the tile grid, with +said+ run before the loop.
  def tiled_room(&said)
    program do
      screen :tiled
      instance_exec(&ROOM_TILES)
      room = background :room, tiles: :set, map: ROOM
      room.scroll_to 5, 3
      instance_exec(room, &said) if said
      game_loop {}
    end
  end

  def picture_of(program, frames: 2)
    screen = Reference.new.run(program, frames: frames).screen
    Array.new(HEIGHT) { |y| Array.new(WIDTH) { |x| screen.pixel(x, y) } }
  end

  # Every pixel of +blocks+ is the pixel +drawn+ has at the top left corner of its block.
  def assert_blocks_of(drawn, blocks, wide, tall)
    wrong = (0...HEIGHT).to_a.product((0...WIDTH).to_a).reject do |y, x|
      blocks[y][x] == drawn[y - (y % tall)][x - (x % wide)]
    end

    assert_empty wrong.first(5), "#{wrong.size} pixels are not the colour at the corner of their #{wide}x#{tall} block"
    refute_equal drawn, blocks, "the picture changed at all"
  end

  # --- a background of tiles ---

  def test_a_tile_background_is_drawn_in_blocks_fixed_to_the_screen
    assert_blocks_of(picture_of(tiled_room), picture_of(tiled_room { pixelate 4 }), 4, 4)
  end

  def test_the_console_draws_the_same_blocks
    assert_backends_agree(tiled_room { pixelate 4 }, frames: 2)
  end

  # A block need not fit a tile, and the biggest is sixteen pixels each way.
  def test_every_size_of_block_is_the_same_on_the_console
    [2, 5, 16].each do |size|
      assert_blocks_of(picture_of(tiled_room), picture_of(tiled_room { pixelate size }), size, size)
      assert_backends_agree(tiled_room { pixelate size }, frames: 2, name: "SIZE#{size}")
    end
  end

  def test_a_size_of_one_is_the_picture_as_drawn
    drawn = picture_of(tiled_room)

    assert_equal drawn, picture_of(tiled_room { pixelate 1 })
    assert_equal drawn, picture_of(tiled_room { pixelate 8; pixelate 1 }), "and it comes back untouched"
    assert_backends_agree(tiled_room { pixelate 8; pixelate 1 }, frames: 2)
  end

  # The size is a number the game can work out, and one past either end stops at that end:
  # below one is the picture as drawn and above sixteen is sixteen.
  def test_a_size_the_game_works_out_is_held_to_the_sizes_there_are
    worked_out = lambda do |start|
      tiled_room do
        size = var :size, start
        pixelate size
      end
    end

    assert_blocks_of(picture_of(tiled_room), picture_of(worked_out.call(6)), 6, 6)
    assert_backends_agree(worked_out.call(6), frames: 2, name: "SIX")
    assert_equal picture_of(tiled_room), picture_of(worked_out.call(-3))
    assert_backends_agree(worked_out.call(-3), frames: 2, name: "BELOW")
    assert_equal picture_of(tiled_room { pixelate 16 }), picture_of(worked_out.call(40))
    assert_backends_agree(worked_out.call(40), frames: 2, name: "ABOVE")
  end

  def test_a_size_written_outside_the_sizes_there_are_is_refused
    error = assert_raises(ArgumentError) { tiled_room { pixelate 17 } }

    assert_match(/from 1 to 16/, error.message)
    assert_match(/17/, error.message)
    assert_match(/1 is the picture as drawn/, assert_raises(ArgumentError) { tiled_room { pixelate 0 } }.message)
  end

  # A number that holds a fraction keeps it in its low bits, so as a size it would be huge.
  def test_a_size_that_holds_a_fraction_is_refused
    error = assert_raises(ArgumentError) do
      tiled_room do
        grown = var :grown, 2.5
        pixelate grown
      end
    end

    assert_match(/whole number of pixels/, error.message)
    assert_match(/to_i/, error.message)
    assert_raises(ArgumentError) { tiled_room { pixelate 2.5 } }
  end

  # The grid stays where it is while the background moves under it, so a scrolling room
  # in blocks is not the same blocks sliding along.
  def test_a_scrolling_background_slides_under_blocks_that_stay_still
    walking = program do
      screen :tiled
      instance_exec(&ROOM_TILES)
      room = background :room, tiles: :set, map: ROOM
      pixelate 6
      game_loop { room.scroll_by 1, 2 }
    end

    [3, 4, 9].each { |frames| assert_backends_agree(walking, frames: frames, name: "WALK#{frames}") }
  end

  # A background whose rows are each bent a different way keeps each row's own bend: a
  # block is the picture row at its top, drawn where each of its rows sits.
  def test_a_bent_background_keeps_each_rows_own_bend
    bent = lambda do |size|
      tiled_room do |room|
        room.scroll_each_row { |row| row / 4 }
        pixelate size if size
      end
    end
    drawn = picture_of(bent.call(nil))
    blocks = picture_of(bent.call(7))

    [[100, 9], [100, 13], [31, 150]].each do |x, y|
      top = y - (y % 7)
      from = (x - (x % 7)) + ((y / 4) - (top / 4))

      assert_equal drawn[top][from], blocks[y][x], "the pixel at (#{x}, #{y})"
    end
    assert_backends_agree(bent.call(7), frames: 2, name: "BENT")
  end

  # A map bigger than the console's grid is brought into view a strip at a time, and has
  # edges: past them the backdrop shows, in blocks or not.
  def test_a_map_bigger_than_the_grid_is_in_blocks_as_the_view_crosses_it
    wandering = program do
      screen :tiled
      instance_exec(&ROOM_TILES)
      big = (0...70).map { |row| (0...80).map { |col| (((row * 2) + col) % 3).zero? ? "a" : "b" }.join }
      field = background :field, tiles: :set, map: big
      field.scroll_to(-13, 430)
      pixelate 5
      game_loop { field.scroll_by 2, 1 }
    end

    [2, 5, 9].each { |frames| assert_backends_agree(wandering, frames: frames, name: "BIG#{frames}") }
  end

  # Each background is put into blocks by itself. A block of the front one whose corner is
  # see-through shows the one behind all the way across, in blocks of its own.
  def test_a_see_through_corner_shows_the_layer_behind_across_its_block
    layered = lambda do |size|
      program do
        screen :tiled
        image(:stripes, "#" => :red, "." => :blue) { STRIPES }
        image(:steps, "#" => :green, "." => :transparent) { STEPS }
        tiles :far, "a" => :stripes
        tiles :near, "b" => :steps
        background :far, tiles: :far, map: ["a" * 32] * 32
        near = background :near, tiles: :near, map: ROOM.map { |row| row.tr("a", " ") }
        near.scroll_to 3, 1
        pixelate size if size
        game_loop {}
      end
    end

    refute_equal picture_of(layered.call(nil)), picture_of(layered.call(5))
    assert_backends_agree(layered.call(5), frames: 2, name: "LAYERED")
  end

  # --- a background that turns and resizes ---

  # A board of the two tiles, turned and resized so that nothing in it sits on a grid.
  def turned_board(size, screen_kind: :rotozoom)
    program do
      screen screen_kind
      instance_exec(&ROOM_TILES)
      board = background :board, tiles: :set, map: ROOM
      board.rotate 20
      board.scale 0.8
      pixelate size if size
      game_loop {}
    end
  end

  def test_a_turned_background_is_in_blocks_of_what_it_shows_at_each_corner
    assert_blocks_of(picture_of(turned_board(nil)), picture_of(turned_board(5)), 5, 5)
    [3, 5, 16].each { |size| assert_backends_agree(turned_board(size), frames: 2, name: "TURN#{size}") }
  end

  # The one size that is not what its number says. The emulator the console's picture is
  # checked against leaves a turned background's blocks of two a single pixel wide: the
  # rows double and the columns do not. A real console is not known to do that, and this
  # pins what the tests can see.
  def test_a_turned_background_in_blocks_of_two_is_only_doubled_down_the_screen
    drawn = picture_of(turned_board(nil))
    doubled = picture_of(turned_board(2))

    assert_equal drawn[40][51], doubled[41][51], "a row shows the row above it"
    assert_equal drawn[40][51], doubled[40][51], "and a column shows itself"
    assert_backends_agree(turned_board(2), frames: 2, name: "TURN2")
  end

  def test_a_turned_background_beside_scrolling_ones_is_in_blocks_too
    assert_backends_agree(turned_board(6, screen_kind: :tiled), frames: 2, name: "TURNTILED")
  end

  # --- sprites ---

  # A 16x16 picture with a different colour at every corner and holes along two edges.
  PATCH = (0...16).map do |row|
    (0...16).map do |col|
      next "." if (col.zero? && row.even?) || (col == 15 && row < 4)

      "ABCD"[(col + (2 * row)) % 4]
    end.join
  end.join("\n")
  PATCH_COLORS = { "." => :transparent, "A" => :red, "B" => :green, "C" => :blue, "D" => :white }.freeze

  # Sprites over a plain floor, off every grid, with +said+ run before the loop.
  def sprites_at(*places, &said)
    cast_on_floor do
      places.each_with_index { |at, i| sprite :"patch#{i}", at: at, facing: { right: :patch } }
      instance_exec(&said) if said
      game_loop {}
    end
  end

  # A sprite is put into blocks by itself, and the rule has two edges to it. A block that
  # starts off the sprite's left or top shows the sprite's own first column or row. And the
  # sprite's last block runs on to the end of that block, past the sprite's own right edge
  # — but never past its bottom one.
  def test_a_sprite_is_in_blocks_held_inside_itself
    drawn = picture_of(sprites_at([37, 21]))
    blocks = picture_of(sprites_at([37, 21]) { pixelate 4 })
    floor = drawn[100][100]

    assert_equal drawn[21][40], blocks[21][41], "the block began above the sprite, so it shows its first row"
    assert_equal drawn[24][37], blocks[25][38], "and one that began to its left shows its first column"
    assert_equal drawn[24][40], blocks[27][43], "inside, a block is its top left corner"
    assert_equal drawn[28][52], blocks[28][55], "the last block runs past the sprite's right edge"
    refute_equal floor, blocks[28][55]
    assert_equal floor, blocks[37][40], "but nothing is drawn below its bottom edge"
    assert_backends_agree(sprites_at([37, 21]) { pixelate 4 }, frames: 2, name: "SPRITE4")
  end

  def test_sprites_of_every_block_size_and_at_every_edge_are_the_same_on_the_console
    places = [[37, 21], [-5, 61], [203, -6], [231, 100], [60, 151], [101, 23]]

    [2, 3, 5, 9, 16].each do |size|
      assert_backends_agree(sprites_at(*places) { pixelate size }, frames: 2, name: "EDGES#{size}")
    end
  end

  # A game over the plain floor, with +cast+ declaring what stands on it.
  def cast_on_floor(&cast)
    program do
      screen :tiled
      image(:floor, "#" => :gray) { (["########"] * 8).join("\n") }
      tiles :floor, "#" => :floor
      background :floor, tiles: :floor, map: ["#" * 30] * 20
      image(:patch, PATCH_COLORS) { PATCH }
      instance_exec(&cast)
    end
  end

  # A picture of +width+ by +height+ that draws only inside the box given, in the patch's
  # colours, so a pose stored trimmed to what it draws has edges that are not its canvas's.
  def self.art_inside(width, height, left, top, right, bottom)
    (0...height).map do |row|
      (0...width).map do |col|
        next "." unless (left..right).cover?(col) && (top..bottom).cover?(row)

        "ABCD"[(col + (3 * row)) % 4]
      end.join
    end.join("\n")
  end

  SMALL_IN_BIG = art_inside(32, 32, 16, 16, 27, 29)
  LOW_IN_BIG = art_inside(32, 32, 2, 1, 30, 12)
  WIDE = art_inside(96, 48, 5, 3, 90, 44)

  # A pose is stored trimmed to what it draws, and it is that trimmed box the blocks are
  # held inside — not the canvas the picture was drawn on.
  def test_a_trimmed_pose_is_held_inside_what_it_draws
    trimmed = lambda do |size|
      cast_on_floor do
        image(:small, PATCH_COLORS) { SMALL_IN_BIG }
        sprite :small, at: [50, 30]
        pixelate size
        game_loop {}
      end
    end

    [3, 7, 16].each { |size| assert_backends_agree(trimmed.call(size), frames: 2, name: "TRIM#{size}") }
  end

  # A picture bigger than any one of the console's sprites is drawn as several, and each
  # is put into blocks by itself.
  def test_a_picture_cut_into_several_sprites_is_in_blocks_a_piece_at_a_time
    cut_up = lambda do |size, at|
      cast_on_floor do
        image(:wide, PATCH_COLORS) { WIDE }
        sprite :wide, at: at
        pixelate size
        game_loop {}
      end
    end

    [[3, [41, 27]], [5, [70, 90]], [16, [-20, 100]], [9, [170, 5]]].each do |size, at|
      assert_backends_agree(cut_up.call(size, at), frames: 2, name: "CUT#{size}")
    end
  end

  # A pose drawn backwards or upside down is the stored one reversed by the console, and
  # its blocks are of what it shows, not of what is stored.
  def test_mirrored_and_upside_down_poses_are_in_blocks_of_what_they_show
    turned_round = lambda do |size|
      cast_on_floor do
        image(:small, PATCH_COLORS) { SMALL_IN_BIG }
        poses = { right: :small, left: mirror(:small), up: upside_down(:small), down: mirror(upside_down(:small)) }
        %i[right left up down].each_with_index do |way, i|
          one = sprite :"facing_#{way}", at: [11 + (i * 53), 40 + (i * 7)], facing: poses
          one.face way
        end
        pixelate size
        game_loop {}
      end
    end

    [3, 6].each { |size| assert_backends_agree(turned_round.call(size), frames: 3, name: "FLIP#{size}") }
  end

  # Where two sprites cross, each is in blocks of its own and the one in front still wins:
  # its last block covers the one behind, and its see-through blocks show it.
  def test_sprites_that_overlap_are_each_in_blocks_of_their_own
    crossing = lambda do |size|
      sprites_at([40, 40], [51, 46], [58, 35], [44, 52]) { pixelate size }
    end

    [3, 4, 7].each { |size| assert_backends_agree(crossing.call(size), frames: 2, name: "CROSS#{size}") }
  end

  def test_sprites_that_move_and_animate_stay_in_step_with_the_console
    moving = cast_on_floor do
      image(:small, PATCH_COLORS) { SMALL_IN_BIG }
      image(:low, PATCH_COLORS) { LOW_IN_BIG }
      walker = sprite :walker, at: [20, 30], frames: %i[low small], rate: 2
      pixelate 5
      game_loop { walker.move 3, 1 }
    end

    [3, 4, 6, 9].each { |frames| assert_backends_agree(moving, frames: frames, name: "MOVE#{frames}") }
  end

  # A sprite that turns or resizes is drawn in a box twice its picture's size, and its
  # blocks are of the turned picture. Its first part block is what the picture would show
  # one column before the box, which is nothing unless the picture is turned and enlarged
  # until it runs out of the box — the last of these.
  def test_sprites_that_turn_and_resize_are_in_blocks_of_the_turned_picture
    turning = lambda do |size, at, angle, scale|
      cast_on_floor do
        spun = sprite :spun, at: at, facing: { right: :patch }
        spun.face_angle angle
        spun.scale scale
        pixelate size
        game_loop {}
      end
    end

    [[3, [50, 40], 30, 1.0], [5, [101, 77], 0, 1.5], [4, [3, 60], 200, 0.7], [7, [215, 9], 75, 1.3],
     [6, [130, 140], 45, 2.0], [3, [77, 33], 45, 2.0], [16, [90, 60], 10, 1.9], [2, [208, 50], 0, 1.0]].each do |size, at, angle, scale|
      assert_backends_agree(turning.call(size, at, angle, scale), frames: 3, name: "SPIN#{size}#{angle}")
    end
  end

  # The one place a sprite's rows are not what the rule above says, and it is the
  # emulator's arithmetic: the box of a turning sprite 64 pixels tall is 128, which can
  # start so far down the screen that its end runs past the 256 lines the console counts
  # in. In blocks, every row of such a sprite that shows is then the box's last row.
  def test_a_tall_turning_sprite_whose_box_runs_off_the_count_of_lines_matches_the_console
    tall = lambda do |at, size|
      cast_on_floor do
        image(:slab, PATCH_COLORS) { TestPixelate.art_inside(64, 64, 0, 0, 63, 63) }
        slab = sprite :slab, at: at
        slab.scale 2.0
        pixelate size
        game_loop {}
      end
    end

    [[[50, 160], 4], [[90, 160], 7], [[120, 60], 5]].each do |at, size|
      assert_backends_agree(tall.call(at, size), frames: 3, name: "TALL#{at[1].abs}")
    end
  end

  # A picture the game paints while it runs is kept whole, whatever it holds, so its
  # blocks are held inside the whole of it.
  def test_a_sprite_the_game_paints_is_in_blocks_of_the_whole_picture
    painted = cast_on_floor do
      colors :ink, %i[transparent white red blue]
      sheet = list :sheet, capacity: 64, width: :byte
      repeat(64) { sheet.push 0 }
      tag = image :tag, from: sheet, width: 16, height: 8, colors: :ink
      sprite :tag, at: [41, 27]
      repeat(32) { |i| sheet[i + 32] = 0x21 }
      tag.changed
      pixelate 3
      game_loop {}
    end

    assert_backends_agree(painted, frames: 3, name: "PAINTED")
  end

  def test_a_pool_of_sprites_is_in_blocks_one_by_one
    pooled = cast_on_floor do
      things = pool :thing, x: 0, y: 0, capacity: 6, image: :patch
      things.spawn x: 13, y: 9
      things.spawn x: 99, y: 70
      things.spawn x: 110, y: 77
      things.spawn x: 230, y: 151
      pixelate 6
      game_loop {}
    end

    assert_backends_agree(pooled, frames: 3, name: "POOL")
  end

  # Text on this screen is drawn as a sprite for each character, so it is in blocks too.
  def test_text_drawn_as_sprites_is_in_blocks
    lettered = lambda do |size|
      cast_on_floor do
        score = var :score, 407
        draw_text "SCORE", 13, 9, :white
        draw_number score, 61, 9, :yellow, digits: 4
        pixelate size
        game_loop {}
      end
    end

    refute_equal picture_of(lettered.call(1), frames: 3), picture_of(lettered.call(3), frames: 3)
    [2, 3, 8].each { |size| assert_backends_agree(lettered.call(size), frames: 3, name: "TEXT#{size}") }
  end

  # --- a place in the stack ---

  # A room, two sprites on it and a score over them, each in a layer of its own.
  def stacked(&said)
    program do
      screen :tiled
      layers :world, :actors, :ui
      image(:stripes, "#" => :red, "." => :blue) { STRIPES }
      image(:steps, "#" => :green, "." => :white) { STEPS }
      image(:patch, PATCH_COLORS) { PATCH }
      tiles :set, "a" => :stripes, "b" => :steps
      layer(:world) { background(:room, tiles: :set, map: ROOM).scroll_to 5, 3 }
      layer :actors do
        sprite :hero, at: [37, 21], facing: { right: :patch }
        sprite :guard, at: [150, 90], facing: { right: :patch }
      end
      layer(:ui) { draw_text "SCORE 407", 13, 9, :yellow }
      instance_exec(&said) if said
      game_loop {}
    end
  end

  # `under:` names a layer, and that layer and everything in front of it are left as drawn.
  def test_a_layer_and_everything_in_front_of_it_can_be_left_as_drawn
    drawn = picture_of(stacked, frames: 3)
    everything = picture_of(stacked { pixelate 6 }, frames: 3)
    game_only = picture_of(stacked { pixelate 6, under: :ui }, frames: 3)
    room_only = picture_of(stacked { pixelate 6, under: :actors }, frames: 3)
    yellow = Color.resolve(:yellow)
    lettering = ->(picture) { picture.flatten.each_index.select.with_index { |_at, i| picture[i / WIDTH][i % WIDTH] == yellow } }
    solid = PATCH.lines(chomp: true)
    hero = (0...16).to_a.product((0...16).to_a).reject { |row, col| solid[row][col] == "." }
                   .map { |row, col| [21 + row, 37 + col] }

    refute_equal lettering.call(drawn), lettering.call(everything), "with no place said, the score is in blocks too"
    assert_equal lettering.call(drawn), lettering.call(game_only), "the score is as drawn"
    assert_equal everything[100], game_only[100], "and the game behind it is in blocks"
    assert_equal(hero.map { |y, x| drawn[y][x] }, hero.map { |y, x| room_only[y][x] }, "a sprite in front of the line is as drawn")
    assert_equal everything[130], room_only[130], "and the room behind it is in blocks"
    assert_backends_agree(stacked { pixelate 6, under: :ui }, frames: 3, name: "UNDERUI")
    assert_backends_agree(stacked { pixelate 6, under: :actors }, frames: 3, name: "UNDERACT")
  end

  # Which things are in blocks is settled as the cartridge is built, so a game says one place.
  def test_a_game_that_names_two_places_is_refused
    error = assert_raises(ArgumentError) do
      stacked do
        pixelate 6, under: :ui
        pixelate 3
      end
    end

    assert_match(/one place/, error.message)
    assert_match(/:ui/, error.message)
  end

  # --- beside the other things a display does to a picture ---

  # A fade is done to the finished picture and blocks to each part before that, so the two
  # do not get in each other's way — placed in the stack or not, and at different places.
  # (`blended:` allows the one step the emulator reads the tint higher by; a block in the
  # wrong place is out by a whole colour.)
  def test_blocks_and_a_fade_are_both_in_force_at_once
    [-> { pixelate 6; fade :black, 50 },
     -> { pixelate 6, under: :ui; fade :black, 50, under: :ui },
     -> { pixelate 5; fade :white, 60, under: :actors },
     -> { pixelate 4, under: :actors; tint :red, 40 }].each_with_index do |said, i|
      assert_backends_agree(stacked(&said), frames: 3, blended: true, name: "MIXED#{i}")
    end
  end

  # The size is set where `pixelate` is called, so a game that moves it itself, a step a
  # frame from inside its loop, shows each size on the frame it said it.
  def test_a_size_moved_from_inside_the_game_loop_keeps_step_with_the_console
    growing = program do
      screen :tiled
      instance_exec(&ROOM_TILES)
      background(:room, tiles: :set, map: ROOM).scroll_to 5, 3
      blocks = var :blocks, 1
      game_loop do
        blocks.approach! 16, 2
        pixelate blocks
      end
    end

    [2, 3, 5, 8, 11].each { |frames| assert_backends_agree(growing, frames: frames, name: "GROW#{frames}") }
  end

  # A see-through layer is mixed with what is behind it after each has been put into blocks.
  def test_a_see_through_layer_is_in_blocks_before_it_is_mixed
    misty = lambda do |size|
      program do
        screen :tiled
        layers :world, :mist, :actors
        image(:stripes, "#" => :red, "." => :blue) { STRIPES }
        image(:steps, "#" => :green, "." => :transparent) { STEPS }
        image(:patch, PATCH_COLORS) { PATCH }
        tiles :far, "a" => :stripes
        tiles :near, "b" => :steps
        layer(:world) { background :far, tiles: :far, map: ["a" * 32] * 32 }
        layer(:mist, transparency: 40) { background(:near, tiles: :near, map: ["b" * 32] * 32).scroll_to 3, 2 }
        layer(:actors) { sprite :hero, at: [37, 21], facing: { right: :patch } }
        pixelate size
        game_loop {}
      end
    end

    [3, 8].each { |size| assert_backends_agree(misty.call(size), frames: 3, blended: true, name: "MIST#{size}") }
  end

  # The size of a block belongs to the display, so it outlasts the screen it was said on:
  # a painted title handing over to a game drawn from tiles is in blocks on both.
  def test_blocks_outlast_a_change_of_screen
    handover = program do
      state = var :state, 0
      ticks = var :ticks, 0
      scene :title do
        screen :bitmap
        clear_screen :black
        fill_rect 31, 17, 50, 33, :red
        fill_rect 100, 61, 14, 9, :green
      end
      scene :world do
        screen :tiled
        image(:stripes, "#" => :red, "." => :blue) { STRIPES }
        image(:patch, PATCH_COLORS) { PATCH }
        tiles :set, "a" => :stripes
        background(:room, tiles: :set, map: ["a" * 32] * 32).scroll_to 5, 3
        sprite :hero, at: [37, 21], facing: { right: :patch }
      end
      pixelate 5
      game_loop do
        ticks.add! 1
        (ticks == 6).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :title
          when_val 1, :world
        end
      end
    end

    assert_backends_agree(handover, frames: 4, console_frames: 6, name: "ONTITLE")
    assert_backends_agree(handover, frames: 12, console_frames: 14, name: "ONWORLD")
  end

  # A layer holds things, and blocks are something done to the picture from a place in it.
  def test_pixelate_inside_a_layer_block_is_refused_and_says_what_to_write
    error = assert_raises(ArgumentError) { stacked { layer(:ui) { pixelate 4 } } }

    assert_match(/changes the whole screen/, error.message)
    assert_match(/under: :ui/, error.message)
  end

  def test_a_place_in_the_stack_needs_a_screen_that_has_one
    error = assert_raises(ArgumentError) { painted_screen { pixelate 4, under: :ui } }

    assert_match(/screen :tiled/, error.message)
  end

  # --- a screen the game paints ---

  # Rectangles and single pixels off every grid, on the screen that holds a whole colour
  # in each pixel. +said+ is run after they are painted.
  def painted_screen(&said)
    program do
      screen :bitmap
      clear_screen :black
      9.times { |i| fill_rect 3 + (i * 25), 5 + (i * 13), 14, 9, %i[red green blue][i % 3] }
      12.times { |i| pixel 7 + (i * 19), 150 - (i * 11), :white }
      instance_exec(&said) if said
      halt
    end
  end

  def test_a_painted_screen_is_shown_in_blocks_and_nothing_painted_changes
    drawn = picture_of(painted_screen)

    assert_blocks_of(drawn, picture_of(painted_screen { pixelate 5 }), 5, 5)
    assert_equal drawn, picture_of(painted_screen { pixelate 5; pixelate 1 }), "the picture is all still there"
    [2, 5, 16].each { |size| assert_backends_agree(painted_screen { pixelate size }, name: "PAINT#{size}") }
  end

  # A window moved over the picture moves the picture under the grid, like a scroll. Moved
  # off the picture's LEFT edge is the one case the grid moves too: a row's first block
  # starts where the picture does, since that is the first pixel the display has to show.
  def test_blocks_of_a_painted_screen_start_where_a_moved_picture_does
    [[9, -3], [-7, 4], [-240, 0], [3, 200]].each do |x, y|
      moved = painted_screen do
        camera x, y
        pixelate 5
      end

      assert_backends_agree(moved, name: "CAM#{x.abs}#{y.abs}")
    end

    off_left = picture_of(painted_screen { camera(-7, 0); pixelate 5 })
    drawn = picture_of(painted_screen { camera(-7, 0) })

    assert_equal drawn[5][7], off_left[5][11], "the first block of the row starts at column 7, not 5"
    assert_equal drawn[5][12], off_left[5][12], "and the next one five further on"
  end

  # The tear-free screen keeps two pictures and shows them in turn, and the blocks are of
  # the one being shown.
  def test_the_tear_free_screen_is_shown_in_blocks
    tear_free = lambda do |size|
      program do
        screen :bitmap, tear_free: true
        pixelate size
        game_loop do
          clear_screen :black
          9.times { |i| fill_rect 2 + (i * 26), 5 + (i * 13), 14, 9, %i[red green blue][i % 3] }
        end
      end
    end

    assert_blocks_of(picture_of(tear_free.call(1), frames: 4), picture_of(tear_free.call(7), frames: 4), 7, 7)
    assert_backends_agree(tear_free.call(7), frames: 4, name: "TEARFREE")
  end
end
