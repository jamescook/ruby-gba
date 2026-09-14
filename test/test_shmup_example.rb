# frozen_string_literal: true

require "test_helper"
require "differential"

require "stringio"
require_relative "../examples/shmup"

# The Shmup example: a whole game split across files — examples/shmup/player.rb,
# enemies.rb, hud.rb — each a plain Ruby object that takes the build and calls the DSL
# verbs on it, wired into two scenes (PLAYING and a GAME OVER screen). This proves the
# multi-file pattern and real scenes end to end: the parts declare their own sprites and
# HUD inside the playing scene (so they vanish on the game-over screen), collaborate (an
# enemy touching the ship calls the HUD's hit), and losing the last ship switches scenes —
# on the interpreter oracle and on real hardware.
class TestShmupExample < Minitest::Test
  include Differential

  CYAN = Color.resolve(:cyan)       # the ship (player.rb)
  RED = Color.resolve(:red)         # an enemy (enemies.rb) / the GAME OVER banner
  WHITE = Color.resolve(:white)     # the HUD text (hud.rb)
  MAGENTA = Color.resolve(:magenta) # the boss's hull (boss.rb)

  PLAYING = Shmup::PLAYING
  GAME_OVER = Shmup::GAME_OVER

  RENDER = 4        # enough frames to draw the opening screen
  MOVE = 70         # enough for the ship to walk to a screen edge, and for an enemy to reach it
  TO_GAME_OVER = 400 # enough, at rest, to lose all three ships

  # The boss is due a wave in and then takes a moment to come down, so it is sliding along
  # the top by here — left-facing at the first of these and right-facing at the second,
  # having bounced off the left edge in between.
  BOSS_FACING_LEFT = 150
  BOSS_FACING_RIGHT = 200
  BOSS_ROW = 50 # deep enough into the picture to be in the gun arm and nothing else
  BOSS_KILLED_BY = 300 # firing on a beat: hit off, broken up, and the bonus paid

  def red_somewhere?(screen)
    (0...160).any? { |y| (0...240).any? { |x| screen.pixel(x, y) == RED } }
  end

  def red_in?(screen, x, y, w, h)
    (y...y + h).any? { |py| (x...x + w).any? { |px| screen.pixel(px, py) == RED } }
  end

  # How far the boss's hull reaches across the screen, or nil while there is no boss. It is
  # read off the picture rather than out of a variable on purpose: what is under test is
  # that the WHOLE cruiser is on screen and moves together, and the sprite's own x says
  # nothing about the pieces the console was given.
  def magenta_span(screen)
    xs = (0...160).step(2).flat_map do |y|
      (0...240).step(2).select { |x| screen.pixel(x, y) == MAGENTA }
    end
    xs.empty? ? nil : [xs.min, xs.max]
  end

  # Which end of the picture the gun arm hangs off — the boss is drawn banking left with
  # the arm under its left shoulder, so the arm swapping ends is the mirrored pose.
  def arm_ends(screen, span)
    low, high = span
    [(low..low + 6).any? { |x| screen.pixel(x, BOSS_ROW) == MAGENTA },
     (high - 6..high).any? { |x| screen.pixel(x, BOSS_ROW) == MAGENTA }]
  end

  # The boss as the console really drew it, +frames+ into a run: how far its hull reaches
  # across the screen, and whether either end of that is the gun arm.
  def console_boss(frames)
    v = assert_emulator_loads_rom(Shmup.build_rom(out: StringIO.new, err: StringIO.new), frames: frames)
    lit = (BOSS_ROW - 20..BOSS_ROW).step(4).flat_map do |y|
      (0...240).step(2).select { |x| v.pixel_is?(x, y, :magenta) }
    end
    return nil if lit.empty?

    low = lit.min
    high = lit.max
    [low, high,
     (low..low + 6).any? { |x| v.pixel_is?(x, BOSS_ROW, :magenta) },
     (high - 6..high).any? { |x| v.pixel_is?(x, BOSS_ROW, :magenta) }]
  end

  # What the build made of the game's sprites, which is where the boss's object count is.
  def video_memory
    backend = RubyGBA::IR::Backends::GBA.new
    backend.lower(Shmup.program)
    backend.build_record(Shmup.program).video_memory
  end

  def test_the_example_builds_clean
    rom = Shmup.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0, "the split-across-files game still builds one ROM"
  end

  # Each file's part draws while playing: the ship, the HUD, and the enemies all appear.
  def test_every_part_renders_on_the_interpreter
    s = Reference.new.run(Shmup.program, frames: RENDER).screen
    assert_equal CYAN, s.pixel(119, 132), "the ship (player.rb) renders"
    assert_equal WHITE, s.pixel(9, 4), "the HUD SCORE text (hud.rb) renders"
    assert red_somewhere?(s), "an enemy (enemies.rb) renders"
  end

  # Player#update runs its input logic from its own file: holding right walks the ship
  # to the right edge, where at rest it never is.
  # (The ship may be glowing warm by then, having been hit on the way, so its hull is either.)
  def test_holding_right_drives_the_ship_from_its_own_file
    hull = [CYAN, *WARM]
    still = Reference.new.run(Shmup.program, frames: MOVE).screen
    right = Reference.new.hold(:right).run(Shmup.program, frames: MOVE).screen
    refute_includes hull, still.pixel(231, 133), "at rest the ship isn't at the right edge"
    assert_includes hull, right.pixel(231, 133), "holding right, the ship moved there"
  end

  # The parts collaborate across files: an enemy that drifts into the ship calls the
  # HUD's `hit`, so a life is lost. (Per-pixel collision, between two files' sprites.)
  def test_parts_collaborate_across_files
    i = Reference.new.run(Shmup.program, frames: MOVE)
    assert_operator i[:lives], :<, 3, "an enemy reached the ship — enemies.rb called hud.hit"
  end

  # --- a ship just lost cannot be hit, and glows warm while it cannot ---

  WARM = %i[yellow orange red].map { |name| Color.resolve(name) }.freeze

  # The colour of the ship's hull, frame by frame, alongside how many ships are left.
  def ship_hull_by_frame(frames)
    seen = []
    i = Reference.new
    i.each_vblank { |_f| seen << [i[:lives], i.screen.pixel(119, 146)] } # the hull, not the cockpit
    i.run(Shmup.program, frames: frames)
    seen
  end

  def test_the_ship_glows_warm_while_it_cannot_be_hit_and_then_is_cyan_again
    seen = ship_hull_by_frame(MOVE + Shmup::Player::SAFE + 10)
    lost = seen.index { |lives, _| lives < 3 }
    refute_nil lost, "an enemy reached the ship"

    # The frame after the hit is drawn before the ship's next pass has said to glow.
    glowing = seen[lost + 2, Shmup::Player::SAFE - 2].map(&:last)
    assert glowing.all? { |color| WARM.include?(color) },
           "warm the whole time it cannot be hit, got #{glowing.map { |c| Color.name_for(c) }.tally}"
    assert_operator glowing.uniq.length, :>=, 3, "and it pulses through the warm colours"
    assert_equal CYAN, seen[lost + Shmup::Player::SAFE + 2].last, "then its own colour again"
  end

  def test_an_enemy_flies_through_a_ship_that_cannot_be_hit
    seen = ship_hull_by_frame(MOVE + Shmup::Player::SAFE)
    lost = seen.index { |lives, _| lives < 3 }

    assert_equal [2], seen[lost, Shmup::Player::SAFE].map(&:first).uniq, "no second ship lost meanwhile"
  end

  # The boss glows warm for a moment after a shot lands, rather than blinking: every frame
  # it is hurt, none of its magenta hull is on screen and a hull's worth of warm is. (An
  # enemy is orange or red too, but three of them are a fraction of the cruiser.)
  def test_the_boss_glows_warm_when_a_shot_lands
    hurt = []
    i = Reference.new.input_each_frame { |f| (f % 20).zero? ? [:a] : [] }
    i.each_vblank do |_f|
      # Past the frame the shot landed on, which is drawn before the boss's pass has glowed.
      next unless i[:boss_flash].between?(1, Shmup::Boss::HURT - 2) && i[:boss_hits].positive?

      warm = (0...160).sum { |y| (0...240).count { |x| WARM.include?(i.screen.pixel(x, y)) } }
      hurt << [magenta_span(i.screen), warm]
    end
    i.run(Shmup.program, frames: BOSS_KILLED_BY)

    refute_empty hurt, "a shot landed on the boss"
    assert hurt.all? { |span, _| span.nil? }, "no magenta hull while it is hurt"
    assert hurt.all? { |_, warm| warm > 1000 }, "the hull glows warm instead, got #{hurt.map(&:last)}"
  end

  # And the console draws the same warm ship, frame for frame — which is the half the
  # interpreter cannot answer, since the colours come from which group of colours the
  # sprite's table entry names.
  def test_the_console_glows_the_ship_the_same
    lost = ship_hull_by_frame(MOVE).index { |lives, _| lives < 3 }
    assert_backends_agree(Shmup.program, frames: lost + 6)
  end

  # Losing the last ship switches to the game-over scene: the gameplay sprites and HUD
  # stop being presented (they belong to the playing scene) and the GAME OVER banner —
  # which belongs to the game-over scene — appears. No per-draw visibility flag anywhere.
  def test_losing_every_ship_shows_the_game_over_screen
    i = Reference.new.run(Shmup.program, frames: TO_GAME_OVER)
    assert_equal GAME_OVER, i[:state], "the last ship lost switched to the game-over scene"
    assert_equal 0, i[:lives]

    s = i.screen
    assert red_in?(s, 88, 64, 66, 18), "the GAME OVER banner shows on the game-over screen"
    refute_equal CYAN, s.pixel(119, 132), "the ship is gone on the game-over screen"
    refute_equal WHITE, s.pixel(9, 4), "the playing HUD is gone on the game-over screen"
    assert_nil magenta_span(s), "and so is the boss that was mid-sweep — every piece of it"
  end

  # The last ship is lost and the field dims away, but the score stays readable — the fade
  # is placed under :ui, so it reaches the field and everything moving in it and stops
  # there. Caught mid-dim, before the scene actually switches.
  def test_the_score_stays_readable_while_the_field_fades_out
    dimming = []
    i = Reference.new
    # The pixels, not the screen: the screen is one object the run keeps painting over.
    i.each_vblank do |_f|
      dimming << [i.screen.pixel(9, 4), i.screen.pixel(119, 132)] if i[:leaving] == 1
    end
    i.run(Shmup.program, frames: TO_GAME_OVER)

    refute_empty dimming, "the game reached the dip to black"
    assert dimming.all? { |score, _ship| score == WHITE }, "the score stays lit all the way down"
    assert_operator dimming.last[1], :<, dimming.first[1], "and the ship dims behind it"
  end

  # START on the game-over screen begins a fresh game — full ships again. (A brief START
  # tap every 40 frames: ignored while playing, and the first tap after game over restarts.)
  def test_start_restarts_a_fresh_game_after_game_over
    saw_game_over = false
    restored = false
    i = Reference.new.input_each_frame { |f| (f % 40).zero? && !f.zero? ? [:start] : [] }
    i.each_vblank do |_f|
      saw_game_over = true if i[:state] == GAME_OVER
      restored = true if saw_game_over && i[:lives] == 3 # ships back to full after game over
    end
    i.run(Shmup.program, frames: TO_GAME_OVER)
    assert saw_game_over, "the game reached the game-over screen"
    assert restored, "a START tap restarted a fresh game — the ships came back"
  end

  # --- the boss (boss.rb): one sprite bigger than anything the console draws ---

  # 96x48 is past the console's largest rectangle, so the build cuts it up. What the game
  # says is one `sprite`; what the hardware gets is several objects — and the rest of the
  # game (three enemies, a ship, a shot, the HUD's glyphs) still has to fit beside them.
  def test_the_boss_is_one_sprite_the_console_has_to_draw_as_several
    objects = video_memory.objects

    refute_nil objects, "a game with a picture too big for one object reports what it spent"
    assert_includes objects.big.to_h, :boss_left, "the boss is the picture that needed cutting"
    assert_operator objects.big.to_h[:boss_left], :>, 1, "and it took more than one object"
    assert_operator objects.used, :<=, objects.capacity,
                    "the whole game still fits the sprites the console draws at once"
  end

  # It is on screen as one picture, wider than any single sprite the console can draw, and
  # the whole of it moves together — same width in both frames, further left in the second.
  def test_the_boss_arrives_and_the_whole_picture_moves_together
    spans = {}
    i = Reference.new
    i.each_vblank { |f| spans[f] = magenta_span(i.screen) }
    i.run(Shmup.program, frames: BOSS_FACING_LEFT + 30)

    assert_nil spans[RENDER], "no boss at the start of a wave"
    early = spans[BOSS_FACING_LEFT]
    late = spans[BOSS_FACING_LEFT + 30]
    refute_nil early, "the boss turned up once the wave was over"
    assert_operator early[1] - early[0], :>, 64, "it is wider than any one sprite the console draws"
    assert_equal early[1] - early[0], late[1] - late[0], "the whole picture is still there"
    assert_operator late[0], :<, early[0], "and all of it slid left together"
  end

  # Facing the other way is the same picture mirrored about the WHOLE canvas, not about
  # each piece: the gun arm swaps ends instead of every piece turning inside out.
  def test_the_boss_turns_round_as_one_picture
    seen = {}
    i = Reference.new
    i.each_vblank do |f|
      next unless [BOSS_FACING_LEFT, BOSS_FACING_RIGHT].include?(f)

      span = magenta_span(i.screen)
      seen[f] = span && arm_ends(i.screen, span)
    end
    i.run(Shmup.program, frames: BOSS_FACING_RIGHT + 1)

    assert_equal [true, false], seen[BOSS_FACING_LEFT], "banking left, the arm is at the left end"
    assert_equal [false, true], seen[BOSS_FACING_RIGHT], "bounced off the edge, it is at the right"
  end

  # A shot that lands hits the boss anywhere in its picture, not just the piece the console
  # drew first — and the last one kills it, which pays the bonus. (Fired on a beat: `pressed`
  # is a press edge, so a held button is one shot however long it is held.)
  def test_shooting_the_boss_wears_it_down_and_killing_it_pays_the_bonus
    arrived = false
    worn_down = false
    bonus_paid = false
    score = 0
    i = Reference.new.input_each_frame { |f| (f % 20).zero? ? [:a] : [] }
    i.each_vblank do |_f|
      arrived = true if i[:boss_hits] == Shmup::Boss::HITS
      worn_down = true if arrived && i[:boss_hits].zero?
      bonus_paid = true if (i[:score] - score) >= Shmup::Boss::BONUS
      score = i[:score]
    end
    i.run(Shmup.program, frames: BOSS_KILLED_BY)

    assert arrived, "a boss turned up with a full complement of hits"
    assert worn_down, "the shots that landed took every one of them off"
    assert bonus_paid, "the frame it broke up paid the bonus in one go"
  end

  # The whole thing runs on the console: the ship and HUD while playing.
  def test_it_renders_on_the_console
    v = assert_emulator_loads_rom(Shmup.build_rom(out: StringIO.new, err: StringIO.new), frames: 3)
    assert v.pixel_is?(119, 132, :cyan), "the ship, got 0x#{format('%04X', v.pixel_gba(119, 132))}"
    assert v.white?(9, 4), "the HUD text, got 0x#{format('%04X', v.pixel_gba(9, 4))}"
  end

  # And the boss renders on the console, which is the half no interpreter can answer: the
  # interpreter draws the picture whole and knows nothing about pieces, so only hardware
  # can say whether the several objects the build cut land shoulder to shoulder. Read
  # straight off the framebuffer: how far the hull reaches, and which end the arm is on.
  def test_the_boss_renders_on_the_console
    low, high, arm_left, arm_right = console_boss(BOSS_FACING_LEFT)

    refute_nil low, "the boss is on screen"
    assert_operator high - low, :>, 64,
                    "the console drew the whole cruiser, wider than one sprite can be"
    assert arm_left, "banking left, the gun arm is at the left end"
    refute arm_right, "and nothing of it is at the right"
  end

  # Turned round on the console: the mirrored pose is the picture reflected about the whole
  # canvas, so the arm swaps ends. Get the reflection wrong — each piece flipped where it
  # stands — and the cruiser turns inside out while still looking plausible.
  def test_the_boss_turns_round_on_the_console
    _low, _high, arm_left, arm_right = console_boss(BOSS_FACING_RIGHT)

    refute arm_left, "bounced off the left edge, nothing of the arm is at the left end"
    assert arm_right, "it is at the right"
  end

  # And the game-over screen renders on the console: run long enough (at rest) to lose all
  # three ships, and the GAME OVER banner is on screen — scene-switched presentation, live
  # on hardware.
  def test_the_game_over_screen_renders_on_the_console
    v = assert_emulator_loads_rom(Shmup.build_rom(out: StringIO.new, err: StringIO.new), frames: 380)
    assert v.pixel_is?(94, 68, :red), "the GAME OVER banner, got 0x#{format('%04X', v.pixel_gba(94, 68))}"
    refute v.pixel_is?(119, 132, :cyan), "the ship is gone on the game-over screen"
  end
end
