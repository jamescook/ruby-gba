# frozen_string_literal: true

require "test_helper"

# ONE OBJECT OVER ONE CARTRIDGE, however many kinds of question a test has.
#
# Reading a running cartridge is several questions at once, and the interesting tests ask two of
# them in the same breath: which colours is this named thing wearing (its row, and the colour
# table), is the right character drawn while he is hurt (his row, the table, and the picture), is
# this sound heard over the music (the voices, taken apart).
#
# Those used to need two objects — the framework's reader for anything the build knew, and the
# emulator's own low-level handle for the colours and for leaving a layer or a voice out. Two
# objects over one cartridge is two readings of the same frame that can disagree, and they did:
# the low-level handle reports where a sprite's tiles were PUT, which is the picture's corner for
# a sprite facing one way and out by up to a canvas facing the other. A test doing both halves
# then has to carry a comment saying which of its two readers to believe for which field.
#
# So the framework's reader is built on the low-level handle rather than beside it, and everything
# comes off the one object.
class TestOneReaderPerCartridge < Minitest::Test

  EIGHT = (["########"] * 8).join("\n")

  def running(game, frames: 4)
    assert_emulator_loads_rom(game.build_rom(out: nil, err: nil, profile: false), frames: frames)
  end

  # A character wearing somebody else's colours, which is what a game does while you cannot be
  # hit. His art is drawn in red; the list he is told to draw with puts white in the same place.
  def hurt_hero
    RubyGBA.game "HURT" do
      screen :tiled
      image(:hero, colors: [:transparent, :red], "#" => :red) { EIGHT }
      colors :hurt, [:transparent, :white]
      hero = sprite :hero, at: [40, 40]
      game_loop { hero.draw_with :hurt }
    end
  end

  # Twenty colours, which is more than a group of sixteen holds.
  MANY = (0...20).map { |n| Color.rgb(n + 6, 31 - n, (n * 2) % 32) }

  # A hero drawn from two colours and a signpost drawn from twenty. The console stores a sprite's
  # picture one of two ways — half a byte a pixel, out of a group of sixteen colours, or a whole
  # byte out of all 256 — and the build picks by how many colours the art uses. Both kinds are in
  # this one program because the question below is whether a row can be asked for the colours it
  # is drawing from without the caller having to know which kind it is holding.
  def two_kinds_of_picture
    RubyGBA.game "TWOWAY" do
      screen :tiled
      image(:hero, "#" => :red) { EIGHT }
      image :signpost, width: 8, height: 8, data: (0...64).map { |i| MANY[i % MANY.length] }
      sprite :hero, at: [40, 40]
      sprite :signpost, at: [80, 40]
      game_loop { wait_vblank }
    end
  end

  # --- the colours ---

  def test_the_reader_that_knows_the_sprites_reads_the_colours_too
    v = running(hurt_hero)

    assert_equal 512, v.palette.length, "the whole table: the backgrounds' colours, then the sprites'"
  end

  # Naming the half and the group is what makes the table usable, because a sprite's row says
  # which GROUP of sixteen it draws from and nothing about where that group sits.
  def test_a_group_of_the_table_comes_back_on_its_own
    v = running(hurt_hero)
    row = v.sprites(:hero).first

    assert_equal 16, v.palette(:sprites, row.palette).length
    assert_equal 256, v.palette(:sprites).length
  end

  # THE WHOLE POINT, in one test: where he is, which colours he is wearing, and what is on screen
  # there — all off one object, with nothing about which reader to believe for which field.
  def test_one_object_answers_where_he_is_and_what_he_is_wearing
    v = running(hurt_hero)
    row = v.sprites(:hero).first

    assert_equal [40, 40], [row.x, row.y], "where the game put him"
    assert_equal Color.resolve(:white), v.palette(:sprites, row.palette)[1],
                 "wearing the second colour of the list he was told to draw with"
    assert v.pixel_is?(40, 40, :white), "...and that is what is on the screen"
  end

  # A ROW SAYS WHICH OF THE TWO WAYS ITS PICTURE IS STORED. The field naming a group of sixteen
  # means nothing for a picture stored the other way, so a row that simply handed over "the
  # sixteen colours at that group" would give the right ones for most sprites and an arbitrary
  # sixteen for the rest, with nothing on it to say which you were holding.
  def test_a_row_says_how_many_colours_its_picture_draws_from
    v = running(two_kinds_of_picture)

    assert_equal 16, v.sprites(:hero).first.color_count, "two colours, so it is stored the small way"
    assert_equal 256, v.sprites(:signpost).first.color_count, "twenty colours, so it is stored the big way"
  end

  # ...and once it says that, it can hand the colours themselves over — which is the thing a test
  # wanted all along, with no group number and no arithmetic at the call site.
  def test_a_row_hands_over_the_colours_it_is_drawing_from
    v = running(two_kinds_of_picture)
    hero = v.sprites(:hero).first
    signpost = v.sprites(:signpost).first

    assert_equal 16, hero.colors.length
    assert_equal v.palette(:sprites, hero.palette), hero.colors, "its own group of sixteen"
    assert_equal 256, signpost.colors.length
    assert_equal v.palette(:sprites), signpost.colors, "the whole table, which is what it draws from"
    assert_includes hero.colors, Color.resolve(:red)
  end

  # A FIELD A ROW DOES NOT HAVE CANNOT BE READ AT ALL. As a Hash it read back as nothing, so a
  # test asserting on a name it got slightly wrong passed, or failed for a reason that was not
  # the one it looked like — the same quiet wrong answer as a row handing over somebody else's
  # colours.
  def test_a_field_a_sprite_does_not_have_cannot_be_read
    row = running(hurt_hero).sprites(:hero).first

    assert_raises(NoMethodError) { row.colour_count }
  end

  # --- leaving a layer out of the picture ---

  # A hero declared behind a fence: the finished picture cannot say he is there at all.
  def hero_behind_a_fence
    brick = (["########"] * 8).join("\n")
    wall = ([("#" * 30)] * 20).join("\n")
    RubyGBA.game "BEHIND" do
      screen :tiled
      layers :actors, :fence
      image(:brick, "#" => :gray) { brick }
      image(:hero, "#" => :red) { EIGHT }
      tiles :stone, "#" => :brick
      layer(:actors) { sprite :hero, at: [40, 40] }
      layer(:fence) { background :fence, tiles: :stone, map: wall }
      game_loop { wait_vblank }
    end
  end

  def test_the_same_object_leaves_the_scenery_out_of_the_picture
    v = running(hero_behind_a_fence)

    assert v.pixel_is?(44, 44, :gray), "the fence is what you see there"

    v.showing(only: :sprites) do
      v.step

      assert v.pixel_is?(44, 44, :red), "with only the sprites drawn, he is there after all"
    end

    v.step

    assert v.pixel_is?(44, 44, :gray), "and the fence is back afterwards"
  end

  def test_naming_a_layer_the_console_does_not_have_says_which_it_has
    error = assert_raises(ArgumentError) { running(hero_behind_a_fence).showing(only: :attic) }

    assert_match(/attic/, error.message)
    assert_match(/sprites/, error.message)
  end

  # --- leaving a voice out of the sound ---

  def humming
    RubyGBA.game "HUM" do
      screen :bitmap
      enable_sound
      wave :triangle, :C4
      game_loop { wait_vblank }
    end
  end

  # Taking a voice out from under a note it is holding is a cut rather than a rest, so the mix
  # steps and drifts back over about half a second. Measured well past that.
  def test_the_same_object_leaves_a_voice_out_of_the_sound
    v = running(humming, frames: 8)

    assert_operator v.audio_energy_by_frame.last(4).sum, :>, 0, "the wave voice is sounding"

    quiet = v.hearing(without: :wave) do
      v.step(40)
      v.audio_energy_by_frame.last(4).sum
    end

    assert_equal 0, quiet, "and with that voice out there is nothing left making the sound"
  end
end
