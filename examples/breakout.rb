#!/usr/bin/env ruby
# frozen_string_literal: true

# Breakout — knock out a wall of bricks with a ball, don't let it fall past your
# paddle. Built entirely with the ruby-gba DSL.
#
# Rules:
#   - D-pad LEFT / RIGHT slides your paddle along the bottom.
#   - The ball bounces off the walls, the bricks, and your paddle.
#   - Where the ball lands on the paddle steers it: hit it near an edge and it
#     flies off at a sharper angle — that's how you aim at the last few bricks.
#   - Each brick you break scores points (the top rows are worth more).
#   - Miss the ball and it falls off the bottom: you lose one of three lives.
#   - Clear every brick to win; lose all three lives and it's game over.
#   - Press START on the title screen to play.
#
# Why this one is drawn double-buffered (tear-free). Every frame we clear the
# screen and repaint the whole wall of bricks, the paddle, the ball, and the HUD —
# the plain, obvious way. On a normal single-buffered screen, doing that much
# drawing spills past the brief safe window the console gives you to change the
# picture, and you'd see the wall tear. `screen :bitmap, tear_free: true` draws to
# a hidden page and flips it into view all at once, so a half-finished frame is
# never shown. The cost is a lower frame rate, never a torn image — the right trade
# when a frame redraws a lot at fixed positions, as a brick wall does. (Compare
# examples/snake.rb, which instead redraws only the few cells that changed each
# step so it can stay single-buffered.)
#
# Run it to build examples/breakout.gba:
#   ruby examples/breakout.rb

require_relative "../lib/ruby_gba"

module Breakout
  # --- Build-time constants (plain Ruby, resolved before any code is emitted) ---
  #
  # A note on the numbers: the tear-free screen writes two pixels at a time, so
  # everything it *fills* — bricks, paddle, ball — has to sit on an even column and
  # be an even width. Every position and size below is even for that reason; text
  # (which is drawn differently) is free to sit anywhere.
  SCREEN_W = 240
  SCREEN_H = 160

  # The brick wall. Eight columns exactly span the screen; four rows of colour.
  COLS         = 8
  ROWS         = 4
  BRICK_CELL_W = SCREEN_W / COLS   # 30px — the slot each brick sits in
  BRICK_W      = 28                # drawn a touch narrower, leaving a 2px gap
  BRICK_H      = 10
  BRICK_ROW_H  = 14                # row pitch (10px brick + 4px gap)
  BRICK_TOP    = 18                # first row starts below the HUD
  # The ball only needs to look for bricks while it's up in the wall's band. Below
  # this line there's nothing to hit, so we skip the whole check — see update_ball.
  BRICK_BAND_BOTTOM = BRICK_TOP + ROWS * BRICK_ROW_H

  # Top rows are worth more, so reaching them is worth the risk (classic Breakout).
  ROW_COLORS = %i[red orange yellow green].freeze
  ROW_POINTS = [40, 30, 20, 10].freeze

  # The paddle lives near the bottom and only moves sideways.
  PADDLE_W     = 36
  PADDLE_H     = 6
  PADDLE_Y     = 150
  PADDLE_SPEED = 4
  START_PADDLE_X = (SCREEN_W - PADDLE_W) / 2

  BALL_SIZE  = 4
  BALL_SPEED = 2
  START_LIVES = 3

  # HUD: score on the left, lives on the right, above the wall.
  HUD_Y       = 2
  HUD_SCORE_X = 8
  HUD_LIVES_X = 224

  # The wall as plain build-time data: one entry per brick with its screen
  # position, colour, points, and the name of the on/off flag that tracks whether
  # it's still there. Generating it in Ruby up front keeps the game code below a
  # short loop instead of 32 copy-pasted bricks.
  BRICKS = ROWS.times.flat_map do |r|
    COLS.times.map do |c|
      { name:   :"brick_#{r}_#{c}",
        x:      c * BRICK_CELL_W,
        y:      BRICK_TOP + r * BRICK_ROW_H,
        color:  ROW_COLORS[r],
        points: ROW_POINTS[r] }
    end
  end.freeze

  GAME = proc do
    screen :bitmap, tear_free: true # draw to a hidden page, flip when done — no tearing
    enable_sound

    # --- Sound presets (channel 2 SFX) ---
    define_sound :brick,       frequency: 660, duty: :quarter, decay: :fast
    define_sound :paddle_hit,  frequency: 880, duty: :quarter, decay: :fast
    define_sound :wall,        frequency: 440, duty: :quarter, decay: :fast
    define_sound :lose,        frequency: 160, duty: :half,    decay: :medium

    # --- RAM variables (each `var` hands back a handle we compare and mutate) ---
    paddle_x    = var :paddle_x, START_PADDLE_X
    ball_x      = var :ball_x, 118
    ball_y      = var :ball_y, 144
    ball_dx     = var :ball_dx, BALL_SPEED
    ball_dy     = var :ball_dy, -BALL_SPEED  # negative = heading up toward the wall
    score       = var :score, 0
    lives       = var :lives, START_LIVES
    bricks_left = var :bricks_left, BRICKS.length
    state       = var :state, 0   # 0=title, 1=playing, 2=cleared, 3=game_over
    blink       = var :blink, 1   # flashes the title prompt
    _hit        = var :_hit, 0    # scratch: where on the paddle the ball landed

    # One on/off flag per brick (1 = still there). Kept in a hash keyed by the
    # brick's name so the game code can look each one up while it loops the wall.
    alive = BRICKS.each_with_object({}) { |b, h| h[b[:name]] = var(b[:name], 1) }

    # --- Subroutines ---

    # Drop the ball onto the middle of the paddle and send it up again. Used at the
    # start of a life and after losing one.
    func :serve do
      copy :ball_x, :paddle_x
      add :ball_x, (PADDLE_W - BALL_SIZE) / 2  # centre it over the paddle
      ball_y.set PADDLE_Y - BALL_SIZE - 2
      ball_dx.set BALL_SPEED
      ball_dy.set(-BALL_SPEED)                 # up
    end

    # Move the ball one step and resolve everything it can hit this frame: the
    # walls, the paddle, the bricks, and the pit below the paddle.
    func :update_ball do
      ball_x.add ball_dx
      ball_y.add ball_dy

      # Bounce off the two side walls and the ceiling. abs/negate_abs force the
      # direction rather than just flipping it, so a ball wedged against a wall for
      # a frame can't rattle back and forth.
      (ball_x <= 0).then                 { ball_dx.abs;        beep :wall }
      (ball_x >= SCREEN_W - BALL_SIZE).then { ball_dx.negate_abs; beep :wall }
      (ball_y <= 0).then                 { ball_dy.abs;        beep :wall }

      ball   = box(ball_x, ball_y, BALL_SIZE, BALL_SIZE)
      paddle = box(paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H)

      # Paddle bounce — only while the ball is heading down into it, so it can't
      # re-trigger on the way back up. Where the ball meets the paddle sets the new
      # sideways direction and steepness: near the left edge it goes hard-left, near
      # the right, hard-right. That's the whole skill of the game — you aim with the
      # paddle. `_hit` is the ball's centre measured from the paddle's left side.
      (ball_dy >= 0).then do
        ball.overlaps?(paddle).then do
          ball_dy.negate_abs                       # always send it back up
          copy :_hit, :ball_x
          add :_hit, BALL_SIZE / 2
          sub :_hit, :paddle_x
          quarter = PADDLE_W / 4
          (_hit < quarter).then { ball_dx.set(-4) }.else do
            (_hit < quarter * 2).then { ball_dx.set(-2) }.else do
              (_hit < quarter * 3).then { ball_dx.set(2) }.else { ball_dx.set(4) }
            end
          end
          beep :paddle_hit
        end
      end

      # Brick hits — only worth checking while the ball is up in the wall's band.
      # For each brick still standing, see if the ball overlaps it; if so, remove
      # it, score it, and bounce the ball vertically. (The ball is smaller than a
      # brick, so in practice it clears one per frame.)
      (ball_y <= BRICK_BAND_BOTTOM).then do
        BRICKS.each do |b|
          (alive[b[:name]] == 1).then do
            ball.overlaps?(box(b[:x], b[:y], BRICK_W, BRICK_H)).then do
              alive[b[:name]].set 0
              score.add b[:points]
              bricks_left.sub 1
              ball_dy.flip
              beep :brick
            end
          end
        end
        (bricks_left <= 0).then { state.set 2 } # wall cleared — you win
      end

      # Past the bottom edge: the paddle missed. Lose a life and re-serve, or end
      # the game if that was the last one.
      (ball_y >= SCREEN_H).then do
        lives.sub 1
        beep :lose
        (lives <= 0).then { state.set 3 }.else { call :serve }
      end
    end

    # Start a fresh game: stand every brick back up, reset the counters, centre the
    # paddle, and serve.
    func :new_game do
      BRICKS.each { |b| set b[:name], 1 }
      set :lives, START_LIVES
      set :score, 0
      set :bricks_left, BRICKS.length
      set :paddle_x, START_PADDLE_X
      call :serve
      set :state, 1
    end

    # --- Scenes ---

    scene :title do
      clear_screen :black
      draw_text "BREAKOUT", 92, 50, :cyan
      every(0.5, :seconds) do
        (blink == 1).then { blink.set 0 }.else { blink.set 1 }
      end
      (blink == 1).then { draw_text "PRESS START", 76, 90, :gray }
      pressed(:start).then { call :new_game }
    end

    scene :playing do
      clear_screen :black

      # Steer the paddle and keep it on screen.
      held(:left).then  { paddle_x.sub PADDLE_SPEED }
      held(:right).then { paddle_x.add PADDLE_SPEED }
      paddle_x.clamp 0, SCREEN_W - PADDLE_W

      call :update_ball

      # Repaint the whole picture. Each standing brick draws itself; broken ones
      # simply aren't drawn. Safe to do wholesale every frame because we're buffered.
      BRICKS.each do |b|
        (alive[b[:name]] == 1).then { dma_fill_rect b[:x], b[:y], BRICK_W, BRICK_H, b[:color] }
      end
      draw_rect_at :paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, :white
      draw_rect_at :ball_x, :ball_y, BALL_SIZE, BALL_SIZE, :white

      # HUD: score (up to three digits) and lives remaining.
      draw_number score, HUD_SCORE_X, HUD_Y, :white, digits: 3
      draw_number lives, HUD_LIVES_X, HUD_Y, :white, digits: 1
    end

    scene :cleared do
      clear_screen :black
      draw_text "YOU WIN!", 88, 50, :green
      draw_text "SCORE", 84, 78, :gray
      draw_number score, 132, 78, :white, digits: 3
      draw_text "PRESS START", 76, 108, :gray
      pressed(:start).then { state.set 0 }
    end

    scene :game_over do
      clear_screen :black
      draw_text "GAME OVER", 84, 50, :red
      draw_text "SCORE", 84, 78, :gray
      draw_number score, 132, 78, :white, digits: 3
      draw_text "PRESS START", 76, 108, :gray
      pressed(:start).then { state.set 0 }
    end

    # --- Main loop: one scene runs per frame, chosen by the game state ---
    game_loop do
      wait_vblank
      case_var :state do
        when_val 0, :title
        when_val 1, :playing
        when_val 2, :cleared
        when_val 3, :game_over
      end
    end
  end

  # RubyGBA.build returns a finished ROM (running the guardrails and Doctor along
  # the way). The out:/err: streams are injectable so tests can read any warnings.
  def self.build_rom(out: $stdout, err: $stderr)
    RubyGBA.build("BREAKOUT", code: "BBRK", maker: "01", out: out, err: err, &GAME)
  end

  # The IR program (no ROM, no emulator) — the headless form the reference
  # interpreter runs in tests.
  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Breakout.build_rom
  output = File.join(__dir__, "breakout.gba")
  rom.write(output)
  puts "Built breakout.gba (#{rom.size} bytes)"

  # Set EXPLAIN=1 to print the per-frame draw/sound-cost breakdown — where the
  # frame's work goes, and whether it fits the console's screen-update budget.
  rom.explain if ENV["EXPLAIN"]
end
