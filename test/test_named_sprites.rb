# frozen_string_literal: true

require "test_helper"

# ASKING WHERE A NAMED SPRITE IS — of the console, and of the oracle that stands in for it.
#
# The console keeps a table of 128 sprites and composes the picture from it, and reading that
# table answers questions the finished picture cannot: it tells a hidden sprite from one drawn
# in the backdrop colour, from one behind a background, from one a pixel off the edge. What
# the table says about each row is which SLOT it is in, and a slot is a number nobody wrote.
#
# So a test with a cast used to identify its hero by guessing — by slot number (a magic number
# that moves the day the game declares something earlier), by position (which needs the game to
# keep its own position in a variable, and is a pixel or two out exactly while the thing is
# moving), or by which colours it draws from (useless for a sprite whose colours are being
# swapped, which is the case most worth testing).
#
# The build knows the answer and used to throw it away: a game asks for a sprite by name, and
# the lowering decides which slots it gets. The cartridge carries that now, so the sprites the
# console is drawing come back knowing whose they are.
#
# The oracle answers the same question, which matters more than it sounds: most tests run the
# program in Ruby rather than building a cartridge, and it had the answer all along — it holds
# every declared thing by name and works out every frame which of them it drew and where. It
# has no slots to give out, so a slot number is the one thing missing from its rows, which is
# the half worth losing.
class TestNamedSprites < Minitest::Test

  EIGHT = (["########"] * 8).join("\n")

  # Two sprites, still, at places nothing else on screen shares.
  def two_sprites
    RubyGBA.game "CAST" do
      screen :tiled
      image(:hero, "#" => :red)    { EIGHT }
      image(:coin, "#" => :yellow) { EIGHT }
      sprite :hero, at: [40, 40]
      sprite :coin, at: [100, 80]
      game_loop { wait_vblank }
    end
  end

  def running(game, frames: 4)
    assert_emulator_loads_rom(game.build_rom(out: nil, err: nil, profile: false), frames: frames)
  end

  # The same game played by the oracle instead of the console.
  def drawn(game, frames: 4)
    Reference.new.run(game.program, frames: frames)
  end

  # The whole point: name the sprite, get its rows, know nothing about slots.
  def test_the_rows_of_a_named_sprite_come_back_by_name
    v = running(two_sprites)

    hero = v.sprites(:hero)

    assert_equal 1, hero.length
    assert_equal 40, hero.first[:x]
    assert_equal 40, hero.first[:y]
  end

  # And they are told apart: the other sprite's row is the other one.
  def test_two_sprites_are_not_confused_for_each_other
    v = running(two_sprites)

    assert_equal [100], v.sprites(:coin).map { |s| s[:x] }
    refute_equal v.sprites(:hero).first[:slot], v.sprites(:coin).first[:slot]
  end

  # With no name, every row the console is drawing, each saying whose it is.
  def test_every_row_says_whose_it_is
    v = running(two_sprites)

    assert_equal [:coin, :hero], v.sprites.map { |s| s[:name] }.uniq.sort
  end

  # A sprite the game switched off is not in the table at all, which is the answer a test
  # wants: the picture cannot tell a hidden sprite from one drawn in the backdrop colour.
  def test_a_hidden_sprite_is_absent
    game = RubyGBA.game "CAST" do
      screen :tiled
      image(:hero, "#" => :red)    { EIGHT }
      image(:coin, "#" => :yellow) { EIGHT }
      sprite :hero, at: [40, 40]
      sprite :coin, at: [100, 80], shown: false
      game_loop { wait_vblank }
    end

    v = running(game)

    assert_empty v.sprites(:coin)
    refute_empty v.sprites(:hero)
  end

  # A picture too big for the console to draw in one go is cut into pieces standing shoulder
  # to shoulder. They come back as several rows under the one name rather than as one merged
  # row — which piece is which is the framework's business, and "where is he" wants all of it.
  def test_a_big_picture_comes_back_as_several_rows_under_one_name
    wide = (["#" * 96] * 32).join("\n")
    game = RubyGBA.game "BOSS" do
      screen :tiled
      image(:boss, "#" => :red) { wide }
      sprite :boss, at: [8, 24]
      game_loop { wait_vblank }
    end

    rows = running(game).sprites(:boss)

    assert_operator rows.length, :>, 1, "a 96x32 picture is more than one of the console's sprites"
    assert_equal [:boss], rows.map { |s| s[:name] }.uniq
    assert_equal 24, rows.map { |s| s[:y] }.min, "and they are all up at the sprite's own place"
  end

  # The case the other ways of guessing cannot do at all: a sprite drawn with another list of
  # colours. Matching a row by which colours it draws from finds nothing once they are swapped.
  def test_a_sprite_being_drawn_in_other_colours_is_still_found_by_name
    game = RubyGBA.game "HURT" do
      screen :tiled
      image(:hero, colors: [:transparent, :red], "#" => :red) { EIGHT }
      colors :hurt, [:transparent, :white]
      hero = sprite :hero, at: [40, 40]
      game_loop { hero.draw_with :hurt }
    end

    v = running(game)
    hero = v.sprites(:hero)

    assert_equal 1, hero.length
    assert_equal 40, hero.first[:x]
  end

  # Every slot of a pool is a sprite of its own and all of them are the one thing the author
  # declared, so the pool's name gives back every instance that is live — which is the case a
  # game with a cast asks about most.
  def test_a_pool_gives_back_the_instances_that_are_live
    game = RubyGBA.game "SWARM" do
      screen :tiled
      image(:bullet, "#" => :white) { EIGHT }
      shots = pool :shot, x: 0, y: 0, capacity: 8, image: :bullet
      fired = var :fired, 0
      game_loop do
        (fired == 0).then do
          shots.spawn(x: 20, y: 30)
          shots.spawn(x: 60, y: 30)
          fired.set! 1
        end
      end
    end

    rows = running(game).sprites(:shot)

    assert_equal 2, rows.length, "two spawned, six slots still empty"
    assert_equal [20, 60], rows.map { |s| s[:x] }.sort
  end

  # A hero with two letters of text over him. Text is drawn as a sprite per letter, and the
  # author named no sprite for any of them.
  def hero_and_text
    RubyGBA.game "HUD" do
      screen :tiled
      image(:hero, "#" => :red) { EIGHT }
      sprite :hero, at: [40, 40]
      draw_text "HI", 8, 8, :white
      game_loop { wait_vblank }
    end
  end

  # A letter's row says nothing rather than making a name up.
  def test_a_letter_of_text_belongs_to_no_named_sprite
    named = running(hero_and_text).sprites.group_by { |s| s[:name] }

    assert_operator named[nil].length, :>=, 2, "one row per letter, none of them a named sprite"
    assert_equal 1, named[:hero].length
  end

  # Naming a sprite the game does not have is a friendly error that says what it does have,
  # rather than an empty list that reads as "it is not on screen". The letters are not among
  # them: a list with a blank in it reads as a sprite whose name failed to print.
  def test_naming_a_sprite_the_game_does_not_have_says_which_it_has
    error = assert_raises(ArgumentError) { running(hero_and_text).sprites(:dragon) }

    assert_match(/:dragon/, error.message)
    assert_match(/Its sprites are: :hero\./, error.message)
  end

  # --- and the same question put to the oracle ---
  #
  # Most tests run the program in Ruby rather than building a cartridge, and the oracle knows
  # everything the answer needs: it holds every declared thing by name and works out, every
  # frame, which of them it drew and where. It just never said so.

  def test_the_oracle_gives_back_a_named_sprites_rows
    hero = drawn(two_sprites).sprites(:hero)

    assert_equal 1, hero.length
    assert_equal 40, hero.first[:x]
    assert_equal 40, hero.first[:y]
  end

  # A sprite the game switched off is not among the things it drew, matching what the console's
  # table does — and it is the whole reason to ask the oracle this rather than read its screen,
  # which cannot tell a hidden sprite from one drawn in the backdrop colour.
  def test_the_oracle_leaves_out_a_sprite_the_game_switched_off
    game = RubyGBA.game "CAST" do
      screen :tiled
      image(:hero, "#" => :red)    { EIGHT }
      image(:coin, "#" => :yellow) { EIGHT }
      sprite :hero, at: [40, 40]
      sprite :coin, at: [100, 80], shown: false
      game_loop { wait_vblank }
    end

    i = drawn(game)

    assert_empty i.sprites(:coin)
    refute_empty i.sprites(:hero)
  end

  # Every slot of a pool is a thing of its own and all of them are the one thing the author
  # declared, so the pool's name gives back the instances that are live.
  def test_the_oracle_gives_a_pool_the_instances_that_are_live
    game = RubyGBA.game "SWARM" do
      screen :tiled
      image(:bullet, "#" => :white) { EIGHT }
      shots = pool :shot, x: 0, y: 0, capacity: 8, image: :bullet
      fired = var :fired, 0
      game_loop do
        (fired == 0).then do
          shots.spawn(x: 20, y: 30)
          shots.spawn(x: 60, y: 30)
          fired.set! 1
        end
      end
    end

    rows = drawn(game).sprites(:shot)

    assert_equal 2, rows.length, "two spawned, six slots still empty"
    assert_equal [20, 60], rows.map { |s| s[:x] }.sort
  end

  # Which pose a sprite is showing, said as the picture the author drew rather than as a number
  # counting into its set of them — the same reason a slot number is not here.
  def test_the_oracle_says_which_picture_a_sprite_is_showing
    game = RubyGBA.game "WALK" do
      screen :tiled
      image(:step_a, "#" => :red)   { EIGHT }
      image(:step_b, "#" => :white) { EIGHT }
      sprite :walker, at: [40, 40], frames: %i[step_a step_b], rate: 2
      game_loop { wait_vblank }
    end

    showing = (1..4).map { |frames| drawn(game, frames: frames).sprites(:walker).first[:picture] }

    assert_equal %i[step_a step_b], showing.uniq.sort, "it walks through both of its pictures"
  end

  # A letter of tiled text is drawn as a sprite of its own and the author named no sprite for
  # it, so its row says nothing rather than making a name up — and it stays out of the friendly
  # error, where a blank in the list would read as a name that failed to print.
  def test_the_oracle_names_a_sprite_the_game_does_not_have
    i = drawn(hero_and_text)

    assert_equal [nil, nil], i.sprites.reject { |s| s[:name] }.map { |s| s[:name] }
    error = assert_raises(ArgumentError) { i.sprites(:dragon) }
    assert_match(/:dragon/, error.message)
    assert_match(/Its sprites are: :hero\./, error.message)
  end

  # The question the fake screen cannot answer at all: a sprite declared behind the scenery is
  # nowhere in the picture, and there is still an honest answer to where it is. Scenery in front
  # of a sprite is also the arrangement that makes the oracle rebuild the whole view every
  # frame rather than putting the scene back under each moving thing — the other of its two
  # drawing paths, and the rows have to come out of both.
  def test_the_oracle_finds_a_sprite_the_scenery_is_covering
    brick = (["########"] * 8).join("\n")
    wall = ([("#" * 30)] * 20).join("\n")
    game = RubyGBA.game "BEHIND" do
      screen :tiled
      layers :actors, :fence
      image(:brick, "#" => :gray) { brick }
      image(:hero, "#" => :red) { EIGHT }
      tiles :stone, "#" => :brick
      layer(:actors) { sprite :hero, at: [40, 40] }
      layer(:fence) { background :fence, tiles: :stone, map: wall }
      game_loop { wait_vblank }
    end

    i = drawn(game)

    assert_equal Color.resolve(:gray), i.screen.pixel(44, 44), "the fence is what you see there"
    assert_equal [{ name: :hero, x: 40, y: 40, picture: :hero }], i.sprites(:hero)
  end

  # The two backends put to the same question, which is the point of giving the oracle one that
  # reads the same: a test can stay on the fast path and a cross-backend test can say so.
  def test_the_console_and_the_oracle_agree_about_which_sprite_is_which
    game = two_sprites

    console = running(game).sprites.map { |s| [s[:name], s[:x], s[:y]] }
    oracle = drawn(game).sprites.map { |s| [s[:name], s[:x], s[:y]] }

    assert_equal [[:coin, 100, 80], [:hero, 40, 40]], oracle.sort
    assert_equal console.sort, oracle.sort
  end
end
