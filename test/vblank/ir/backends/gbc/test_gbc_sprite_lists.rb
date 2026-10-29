# frozen_string_literal: true

require "test_helper"

# THE COLOR'S EIGHT LISTS OF SPRITE COLOURS. A game whose sprites wear more lists than eight
# still builds: each list borrows one of the eight as a sprite wearing it is placed
# (test/vblank/dsl/test_sprite_borrowed_colors.rb and test/vblank/builder/test_colors_in_use.rb
# play that on every lowering). What cannot fit is a set given to `colors_in_use` with more than
# eight lists, since a set's lists are shown together; that is refused here, naming the set.
class TestGBCSpriteLists < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  def test_a_set_of_more_than_eight_lists_is_refused_naming_the_set
    error = assert_raises(GBC::LoweringError) { GBC.new.build(one_set_of(9)) }

    assert_match(/needs 9 lists of colours at once/, error.message)
    assert_match(/holds 8 lists for sprites/, error.message)
    assert_match(/test_gbc_sprite_lists\.rb:\d+/, error.message)
    assert_match(/give that set 8 lists or fewer/, error.message)
  end

  def test_a_set_of_eight_lists_builds
    assert GBC.new.build(one_set_of(8))
  end

  # SCENES THAT EACH FADE THEIR OWN SPRITES, as a game fades every screen in and out: three
  # scenes, three sprites each, each sprite stepping through 33 lists of its own. That is 297
  # lists in all, more than the 254 a build numbers for the whole game, and 99 for any one
  # scene, since a scene never shows another's sprites. +size+ is the ships' width and height, so
  # a ship of 16 is four pieces. +filler+ lines of code the first scene never runs fill the
  # cartridge's first bank, so the other scenes' code goes in the second.
  def self.fading_scenes(scenes: 3, sprites: 3, steps: 33, size: 8, filler: 0)
    ship = Array.new(size * size) { |i| ((i % size) + (i / size)).even? ? :red : :green }
    VBlank.game("FADING SCENES", consoles: %i[gbc]) do
      screen :tiled
      image :ship, width: size, height: size, data: ship, colors: %i[transparent red green]
      showing = var :showing, 0
      scenes.times do |s|
        scene :"fading#{s}" do
          if s.zero? && filler.positive?
            never = var :never, 0
            (never == 1).then { filler.times { |i| never.set! never + i } }
          end
          ships = (0...sprites).map do |n|
            lists = (0...steps).map do |step|
              colors :"fade#{s}_#{n}_#{step}", [:transparent, Color.rgb(step % 32, (s * sprites) + n, step / 32),
                                                Color.rgb(31 - (step % 32), s, n)]
              :"fade#{s}_#{n}_#{step}"
            end
            [sprite(:"ship#{s}_#{n}", at: [16 + (n * 16), 16 + (s * 16)], facing: { ship: :ship }), lists]
          end
          step = var :"step#{s}", 0
          ships.each { |ship, lists| ship.draw_with lists, showing: step }
          (step == steps - 1).then do
            step.set! 0
            showing.set!((s + 1) % scenes)
          end.else { step.add! 1 }
        end
      end
      game_loop do
        case_var(:showing) { scenes.times { |s| when_val s, :"fading#{s}" } }
      end
    end
  end

  def test_scenes_fading_more_lists_than_a_build_numbers_play_as_the_interpreter_plays_them
    game_player.run(TestGBCSpriteLists.fading_scenes.program(console: :gbc), frames: 110)
  end

  # A sprite's pieces are read from the bank its picture is kept in, put in view for the reading.
  # A scene's own list is copied in from the bank that scene's colours are in, on the sprite's first
  # piece, and the pieces' bank has to be put back after it for the rest. This game is laid out so
  # that the bank put back would otherwise be the code's, not the pieces': the later scenes' code
  # is in the second bank, the ship's pieces in what room is left in the first.
  def test_scenes_fading_sprites_of_many_pieces_play_as_the_interpreter_plays_them
    game = TestGBCSpriteLists.fading_scenes(size: 16, filler: 550)
    code = GBC.new.build(game.program(console: :gbc)).built.code
    assert_operator code.fetch("art_lent_scene_1_colors").bank, :positive?
    refute_equal code.fetch("art_pieces_0").bank, code.fetch("routine _scene_fading1").bank,
                 "the filler no longer puts the pieces and the code in different banks: change how much there is"

    game_player.run(game.program(console: :gbc), frames: 110)
  end

  # Each scene's fade steps every sprite to a list it has not worn on every pass, and each
  # pass still fits its frame, every sprite finding one of the eight for its list, through
  # every handover from one scene to the next.
  def test_scenes_fading_more_lists_than_a_build_numbers_fit_each_frame
    rom = TestGBCSpriteLists.fading_scenes.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 100, settle: 10)

    assert_equal result.frames, result.passes
    assert_equal 0, result.lists_missed
  end

  # A scene wearing more lists than a build numbers is refused, naming the scene.
  def test_one_scene_wearing_more_lists_than_a_build_numbers_is_refused_naming_it
    error = assert_raises(VBlank::BuildError) do
      TestGBCSpriteLists.fading_scenes(scenes: 2, sprites: 8, steps: 33).program(console: :gbc).then { |p| GBC.new.build(p) }
    end

    assert_match(/the scene :fading\d/, error.message)
    assert_match(/254 lists of colours/, error.message)
  end

  private

  # A pool of things each wearing one of +count+ lists, all of them in one set, beside a set of one.
  def one_set_of(count)
    names = (0...count).map { |n| :"set#{n}" }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: %i[transparent red green]
      names.each_with_index { |name, n| colors name, [:transparent, Color.rgb(n, 31 - n, 5), Color.rgb(31 - n, n, 9)] }
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: 2, image: :ship
      things.spawn x: 40, y: 40, kind: 0
      game_loop do
        colors_in_use [names.first(1), names], showing: 1
        things.each { |thing| thing.draw_with names, showing: thing.kind }
      end
    end
    builder.finalize_program
    builder.program
  end
end
