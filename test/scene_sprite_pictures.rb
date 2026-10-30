# frozen_string_literal: true

# A GAME OF SCENES WHOSE SPRITE PICTURES ARE MORE THAN A CONSOLE HOLDS TOGETHER, AND FEW ENOUGH ALONE.
# Three scenes take turns, each with a sprite of its own stepping through 22 pictures of 16×16, a
# picture a frame: four tiles of 8×8 a picture, 88 a scene, 264 between the three. A sprite every
# scene shows stands beside them. A Game Boy Color holds 256 sprite tiles at once, so each scene
# brings its own pictures in as it takes over.
#
# Played on every lowering for its pictures, and built by the Color's own tests for its refusals,
# so it is written once, here.
module SceneSpritePictures
  SCENES = %i[forest cave tower].freeze
  POSES = 22

  # Passes each scene is up before the next takes over: the third gives the first back, so a scene
  # brings its pictures in again over another's.
  PASSES_A_SCENE = 6

  module_function

  # The pictures +scene+'s sprite steps through, +poses+ of them.
  def picture_names(scene, poses = POSES) = (0...poses).map { |n| :"#{scene}_#{n}" }

  # A 16×16 picture whose four 8×8 quarters differ from every other picture's quarters, mirrored or
  # upside down too: each quarter has its own number in its first and third rows, and a dot at the
  # left of its second row that no quarter has anywhere else.
  def art(number)
    quarters = (0...4).map do |quarter|
      code = (number * 4) + quarter
      rows = Array.new(8) { "." * 8 }
      rows[0] = (0...8).map { |bit| code[bit] == 1 ? "#" : "." }.join
      rows[1] = "#......."
      rows[2] = (0...8).map { |bit| code[bit + 8] == 1 ? "#" : "." }.join
      rows
    end
    top = quarters[0].zip(quarters[1]).map(&:join)
    bottom = quarters[2].zip(quarters[3]).map(&:join)
    (top + bottom).join("\n")
  end

  # Declare it in +builder+. +scenes+ are the scenes that have pictures of their own, all of them
  # unless said; +poses+ how many each steps through; +clock+, the frames since power-on in :seen
  # every pass.
  def declare(builder, scenes: SCENES, poses: POSES, clock: false, backgrounds: nil)
    builder.instance_eval do
      screen :tiled
      image(:heart, "#" => :red, "." => :black) { SceneSpritePictures.art(1000) }
      sprite :heart, at: [8, 8]
      scenes.each_with_index do |scene, s|
        names = SceneSpritePictures.picture_names(scene, poses)
        names.each_with_index do |name, n|
          image(name, "#" => :white, "." => :blue) { SceneSpritePictures.art((s * poses) + n) }
        end
        if backgrounds
          keys = (0...backgrounds).to_h do |n|
            tile = :"#{scene}_tile_#{n}"
            image(tile, "#" => :green, "." => :black) { SceneSpritePictures.art((s * backgrounds) + n).lines.first(8).map { |row| row.chomp[0, 8] }.join("\n") }
            [n + 1, tile]
          end
          tiles :"#{scene}_tiles", keys
          map = Array.new(18) { |row| Array.new(20) { |col| ((row * 20) + col) % backgrounds + 1 } }
        end
        scene(scene) do
          background :"#{scene}_field", tiles: :"#{scene}_tiles", map: map if backgrounds
          sprite :"#{scene}_walker", at: [40, 40], frames: names, rate: 1
        end
      end
      state = var :state, 0
      tick = var :tick, 0
      seen = clock ? var(:seen, 0) : nil
      game_loop do
        tick.add! 1
        seen&.set! frames_since_power_on
        state.set!((tick / PASSES_A_SCENE) % scenes.length)
        case_var(:state) do
          scenes.each_with_index { |scene, s| when_val s, scene }
        end
      end
    end
  end
end
