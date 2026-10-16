# frozen_string_literal: true

require "test_helper"

# AN UPSIDE-DOWN POSE COSTS NO SPRITE MEMORY: the console draws an object upside down for
# nothing, so the build stores the picture once and says "that one, turned over". That holds
# whether the game asked for the turn with `upside_down` or drew the turned art by hand — the
# sameness is judged on the pixels.
class TestSpriteUpsideDownStorage < Minitest::Test
  CANVAS = 32
  INK = RubyGBA::Graphics::Color.rgb(31, 20, 0)
  EDGE = RubyGBA::Graphics::Color.rgb(0, 31, 10)
  CLEAR = RubyGBA::Graphics::Color.rgb(0, 0, 1)

  # A block at (+ox+, +oy+) with its top row and its left column different colours, so it is
  # not the same picture turned any way.
  private def lopsided(ox, oy, w = 10, h = 12)
    (0...(CANVAS * CANVAS)).map do |i|
      x = i % CANVAS
      y = i / CANVAS
      next CLEAR unless x >= ox && x < ox + w && y >= oy && y < oy + h

      x == ox || y == oy ? EDGE : INK
    end
  end

  # The same pixels with the rows in the other order: the picture turned over by hand.
  private def turned_by_hand(data) = data.each_slice(CANVAS).to_a.reverse.flatten

  # A sprite whose cycle runs through +poses+ and then the turned pictures +turn+ makes of
  # them: +turn+ is handed the builder and the names, and gives back the extra names.
  private def program(poses, &turn)
    canvas = CANVAS
    clear = CLEAR
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      names = poses.each_with_index.map do |data, k|
        image :"pose#{k}", width: canvas, height: canvas, data: data, transparent: clear
        :"pose#{k}"
      end
      sprite :hero, at: [40, 30], frames: names + instance_exec(names, &turn), rate: 3
      game_loop {}
    end
    builder.finalize_program
    builder.program
  end

  private def sprite_bytes(program)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "UPSIDE", maker: "01", built: backend.build_record(program))
    rom.built.video_memory.sprites.used
  end

  # Three pictures and their turned-over selves cost what the three cost, and so does each
  # turned both ways.
  def test_an_upside_down_pose_stores_no_pixels_of_its_own
    walk = [lopsided(6, 4), lopsided(8, 5, 12, 10), lopsided(5, 6, 9, 14)]
    alone = sprite_bytes(program(walk) { |_names| [] })

    assert_equal alone, sprite_bytes(program(walk) { |names| upside_down(names) })
    assert_equal alone, sprite_bytes(program(walk) { |names| mirror(upside_down(names)) })
  end

  # A sprite that TURNS keeps both: once an object is turning, the two bits that would flip it
  # name its rotation group instead, so the turned-over pose needs pixels of its own.
  def test_a_turning_sprite_keeps_its_upside_down_pose_as_pixels
    walk = [lopsided(6, 4), lopsided(8, 5, 12, 10)]
    alone = sprite_bytes(turning_program(walk) { |_names| [] })

    assert_operator sprite_bytes(turning_program(walk) { |names| [upside_down(names[0])] }), :>, alone
  end

  # #program, with the sprite turning a little every frame.
  private def turning_program(poses, &turn)
    canvas = CANVAS
    clear = CLEAR
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      names = poses.each_with_index.map do |data, k|
        image :"pose#{k}", width: canvas, height: canvas, data: data, transparent: clear
        :"pose#{k}"
      end
      hero = sprite :hero, at: [40, 30], frames: names + instance_exec(names, &turn), rate: 3
      game_loop { hero.turn 3 }
    end
    builder.finalize_program
    builder.program
  end

  def test_art_drawn_upside_down_by_hand_is_stored_once
    art = lopsided(6, 4)
    other = lopsided(8, 5, 12, 10)
    alone = sprite_bytes(program([art, other]) { |_names| [] })

    assert_equal alone, sprite_bytes(program([art, other, turned_by_hand(art)]) { |_names| [] })
  end
end
