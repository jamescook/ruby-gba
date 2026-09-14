# frozen_string_literal: true

require "test_helper"
require "differential"

# A CHARACTER COSTS THE SPRITE MEMORY OF THE FRAME IT IS SHOWING, not of every frame it could
# show, when that is what it takes to fit.
#
# The console draws sprites out of 32K of picture memory. A character with a full set of
# animations can fill that on its own, and then nobody else fits beside it, even though it
# only ever shows one frame at a time.
class TestSpriteOneFrameAtATime < Minitest::Test
  include Differential

  SPRITE_MEMORY = 32 * 1024

  # Fifteen colours, so every picture is stored the small way (half a byte a pixel).
  INKS = (1..15).map { |i| RubyGBA::Color.rgb(i * 2, 31 - (i * 2), 10) }.freeze

  # A 32x32 picture that fills its whole square and differs from every other one made here:
  # a slanted stripe pattern, with the picture's number written along the top row in two inks.
  # No two are the same, and none is another one reversed.
  def frame_art(number)
    (0...32).flat_map do |y|
      (0...32).map do |x|
        next INKS[(number >> x) & 1] if y.zero?

        INKS[((x * 5) + (y * 3)) % 15]
      end
    end
  end

  # A 48x48 picture whose drawn part grows from the corner with its number, so no two are cut
  # into the same pieces.
  def growing_art(number)
    reach = 16 + (number % 33)
    (0...48).flat_map do |y|
      (0...48).map do |x|
        next :transparent if x >= reach || y >= reach

        INKS[((x * 5) + (y * 3) + number) % 15]
      end
    end
  end

  # A program built through the DSL; the block is handed this test, for its pictures.
  def program(&block)
    b = Builder.new
    b.instance_exec(self, &block)
    b.emit_pending_functions
    b.program
  end

  def sprite_memory_used(prog)
    backend = GBA.new
    backend.lower(prog)
    backend.build_record(prog).video_memory.sprites.used
  end

  # --- the character picori is building ---

  # Link in The Minish Cap: a resting pose and a ten-frame walk and run in each of three
  # facings, the fourth facing the third one reversed — 84 poses, 63 of them stored, which is
  # 32,256 of the 32,768 bytes. An enemy of two frames stands beside him. The game picks his
  # pose by name every frame: resting, then walking down, then running left.
  LINK_FACINGS = %i[down up right].freeze

  def link_pose(facing, what, n) = :"link_#{facing}_#{what}#{n}"

  def link_screen
    program do |t|
      screen :tiled
      poses = {}
      picture = 0
      LINK_FACINGS.each do |facing|
        [["idle", 1], ["walk", 10], ["run", 10]].each do |what, count|
          count.times do |n|
            name = t.link_pose(facing, what, n)
            image name, width: 32, height: 32, data: t.frame_art(picture)
            picture += 1
            poses[name] = name
            poses[t.link_pose(:left, what, n)] = mirror(name) if facing == :right
          end
        end
      end
      image :enemy_0, width: 32, height: 32, data: t.frame_art(100)
      image :enemy_1, width: 32, height: 32, data: t.frame_art(101)
      link = sprite :link, at: [40, 40], facing: poses
      sprite :enemy, at: [120, 60], frames: %i[enemy_0 enemy_1], rate: 2
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        10.times { |n| (tick == 3 + n).then { link.face t.link_pose(:down, "walk", n) } }
        10.times { |n| (tick == 13 + n).then { link.face t.link_pose(:left, "run", n) } }
      end
    end
  end

  def test_link_and_an_enemy_fit_in_sprite_memory
    assert_operator sprite_memory_used(link_screen), :<=, SPRITE_MEMORY
  end

  def test_link_shows_the_pose_the_game_picks_resting_walking_and_running_reversed
    [2, 8, 18].each { |frames| assert_backends_agree(link_screen, frames: frames, name: "LINK") }
  end

  # --- a cast ---

  # A hero who keeps one frame at a time, and a pool of guards walking beside him. The guards'
  # four frames are stored once for all of them, which is less than a frame each.
  def cast_screen(guard_frames:)
    program do |t|
      screen :tiled
      hero = (0...63).map { |n| :"hero_#{n}" }
      hero.each_with_index { |name, n| image name, width: 32, height: 32, data: t.frame_art(n) }
      walk = (0...guard_frames).map { |n| :"guard_#{n}" }
      walk.each_with_index { |name, n| image name, width: 32, height: 32, data: t.frame_art(4000 + n) }
      sprite :hero, at: [40, 40], frames: hero, rate: 1
      guards = pool :guard, x: 0, y: 0, capacity: 6, frames: walk, rate: 1
      6.times { |n| guards.spawn(x: 20 + (n * 30), y: 100) }
      game_loop { guards.each { |g| g.x.add! 1 } }
    end
  end

  def test_a_hero_and_a_room_of_guards_are_drawn_as_the_game_means
    assert_backends_agree(cast_screen(guard_frames: 4), frames: 5, name: "CAST")
  end

  # The same guards with more frames than fit: then each of them keeps one frame too.
  def test_guards_with_more_frames_than_fit_each_keep_one
    cast = cast_screen(guard_frames: 64)
    assert_operator sprite_memory_used(cast), :<=, SPRITE_MEMORY
    assert_backends_agree(cast, frames: 5, name: "GUARDS")
  end

  # --- the ways a frame is laid out ---

  # Three facings of 21 frames each and the fourth the third reversed, turning left partway
  # through, so a frame drawn from another one's pictures, reversed, is among the ones compared.
  def turning_screen
    facings = %i[down up right].to_h { |dir| [dir, (0...21).map { |n| :"hero_#{dir}_#{n}" }] }
    program do |t|
      screen :tiled
      facings.values.flatten.each_with_index { |name, n| image name, width: 32, height: 32, data: t.frame_art(n) }
      image :enemy_0, width: 32, height: 32, data: t.frame_art(100)
      image :enemy_1, width: 32, height: 32, data: t.frame_art(101)
      hero = sprite :hero, at: [40, 40], rate: 1, facing: facings.merge(left: mirror(facings[:right]))
      sprite :enemy, at: [120, 60], frames: %i[enemy_0 enemy_1], rate: 2
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick == 2).then { hero.face :right }
        (tick == 4).then { hero.face :left }
      end
    end
  end

  def test_a_character_facing_the_other_way_shows_its_frames_reversed
    assert_backends_agree(turning_screen, frames: 6, name: "TURN")
  end

  # A 48x48 character is bigger than any one picture the console draws, so each frame is cut
  # into pieces — and a frame that draws less is cut into fewer, smaller ones.
  def big_character_screen
    program do |t|
      screen :tiled
      frames = (0...33).map { |n| :"giant_#{n}" }
      frames.each_with_index do |name, n|
        image name, width: 48, height: 48, data: t.growing_art(n), transparent: true
      end
      image :enemy_0, width: 32, height: 32, data: t.frame_art(100)
      image :enemy_1, width: 32, height: 32, data: t.frame_art(101)
      sprite :giant, at: [40, 40], frames: frames, rate: 1
      sprite :enemy, at: [140, 60], frames: %i[enemy_0 enemy_1], rate: 2
      game_loop {}
    end
  end

  def test_a_character_cut_into_pieces_shows_each_frame_whole
    [3, 12, 30].each { |frames| assert_backends_agree(big_character_screen, frames: frames, name: "GIANT") }
  end

  # --- scenes ---

  # A scene's pictures go into the same memory another scene's used. So a character that keeps
  # one frame at a time, in a scene the game leaves and comes back to, finds its frame written
  # over — and has to copy it in again though the frame it is showing never changed. Both
  # animate slowly here so that nothing else would copy it. +cast+ names each character of the
  # :playing scene and whether it keeps one frame (70 of them) or its whole two.
  def two_scene_screen(cast)
    program do |t|
      screen :tiled
      art = 0
      frames = cast.to_h do |name, many|
        names = (0...(many ? 70 : 2)).map { |n| :"#{name}_#{n}" }
        names.each { |pose| image pose, width: 32, height: 32, data: t.frame_art(art += 1) }
        [name, names]
      end
      image :banner, width: 32, height: 32, data: t.frame_art(2000)
      var :state, 0
      tick = var :tick, 0
      scene(:playing) { frames.each_with_index { |(name, poses), n| sprite name, at: [40 + (n * 80), 40], frames: poses, rate: 60 } }
      scene(:paused) { sprite :banner, at: [40, 40] }
      game_loop do
        tick.add! 1
        (tick == 3).then { set! :state, 1 }
        (tick == 5).then { set! :state, 0 }
        (tick == 8).then { set! :state, 1 }
        case_var(:state) { when_val 0, :playing; when_val 1, :paused }
      end
    end
  end

  def test_a_character_back_in_its_scene_shows_its_frame_again
    assert_backends_agree(two_scene_screen(hero: true, enemy: false), frames: 6, name: "SCENES")
  end

  # Every character in the scene keeps one frame, so the scene has no pictures of its own to
  # send when it takes over — and still has to take its memory back, both ways round.
  def test_a_scene_whose_characters_all_keep_one_frame_takes_its_memory_back
    prog = two_scene_screen(hero: true, sidekick: true)
    assert_backends_agree(prog, frames: 6, name: "ROOMS")  # back in :playing
    assert_backends_agree(prog, frames: 10, name: "ROOMS") # ...and back in :paused
  end

  # --- what the report says ---

  # Two sprites showing one set of pictures store them once; a sprite kept to one frame at a
  # time stores none of its own either, and those are different things. The report has to tell
  # them apart, because they are the two ways a game's pictures come to fit and the reader is
  # deciding what to draw next.
  def test_the_report_tells_sharing_apart_from_keeping_one_frame
    hero = (0...63).map { |n| :"hero_#{n}" }
    art = method(:frame_art)
    rom = RubyGBA.build("REPORT", code: "BRPT", maker: "01", validate: false,
                        out: StringIO.new, err: StringIO.new) do
      screen :tiled
      hero.each_with_index { |name, n| image name, width: 32, height: 32, data: art.call(n) }
      image :guard_a, width: 32, height: 32, data: art.call(500)
      image :guard_b, width: 32, height: 32, data: art.call(500) # the same picture, drawn twice
      image :statue, width: 32, height: 32, data: art.call(700)  # ...and one more, so it does not fit
      sprite :hero, at: [40, 40], frames: hero, rate: 1
      sprite :guard_a, at: [80, 40]
      sprite :guard_b, at: [120, 40]
      sprite :statue, at: [160, 40]
      game_loop {}
    end

    sprites = rom.built.video_memory.sprites
    assert_equal 1, sprites.shared, "one guard shows the other's picture, stored once"
    assert_equal 1, sprites.one_frame, "the hero keeps one frame at a time"
  end

  # --- who is kept to one frame ---

  # What has to fit is what every screen shows PLUS one scene's. Here the pictures every screen
  # shows are the most of any one group, and none of them animates; the hero in the scene does.
  def test_a_scene_character_keeps_one_frame_when_the_pictures_on_every_screen_are_the_most
    prog = program do |t|
      screen :tiled
      40.times do |n|
        image :"statue_#{n}", width: 32, height: 32, data: t.frame_art(1000 + n)
        sprite :"statue_#{n}", at: [n, n]
      end
      frames = (0...32).map { |n| :"hero_#{n}" }
      frames.each_with_index { |name, n| image name, width: 32, height: 32, data: t.frame_art(n) }
      var :state, 0
      scene(:playing) { sprite :hero, at: [40, 40], frames: frames, rate: 1 }
      scene(:paused) {}
      game_loop { case_var(:state) { when_val 0, :playing; when_val 1, :paused } }
    end
    assert_operator sprite_memory_used(prog), :<=, SPRITE_MEMORY
  end

  # A POOL'S SLOTS ALL SHOW ONE SET OF PICTURES, stored once. Keeping one slot to a frame gives
  # nothing back while the others still show the set, and keeping all eight costs eight frames,
  # more than the set. Keeping the three-frame sprite beside them to one frame is what fits.
  def test_sprites_that_share_their_pictures_are_not_kept_to_one_frame_when_that_gives_nothing_back
    prog = program do |t|
      screen :tiled
      58.times do |n|
        image :"statue_#{n}", width: 32, height: 32, data: t.frame_art(1000 + n)
        sprite :"statue_#{n}", at: [n, n]
      end
      steps = (0...3).map { |n| :"walker_#{n}" }
      steps.each_with_index { |name, n| image name, width: 32, height: 32, data: t.frame_art(3000 + n) }
      sprite :walker, at: [10, 100], frames: steps, rate: 4
      walk = (0...4).map { |n| :"guard_#{n}" }
      walk.each_with_index { |name, n| image name, width: 32, height: 32, data: t.frame_art(4000 + n) }
      guards = pool :guard, x: 0, y: 0, capacity: 8, frames: walk, rate: 2
      guards.spawn(x: 10, y: 10)
      game_loop { guards.each { |g| g.x.add! 1 } }
    end
    assert_operator sprite_memory_used(prog), :<=, SPRITE_MEMORY
  end

  # Sixty-five different still pictures, one sprite each. None animates, so none has frames to
  # keep one at a time, and together they are more than sprite memory holds.
  def test_still_pictures_that_do_not_fit_are_a_friendly_error
    prog = program do |t|
      screen :tiled
      65.times do |n|
        image :"statue_#{n}", width: 32, height: 32, data: t.frame_art(n)
        sprite :"statue_#{n}", at: [n, n]
      end
      game_loop {}
    end
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
    assert_match(/statue/, err.message)
    assert_match(/one frame at a time/, err.message)
  end
end
