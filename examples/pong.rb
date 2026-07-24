#!/usr/bin/env ruby
# frozen_string_literal: true

# Pong — single-player game built entirely with ruby-gba DSL.
#
# Rules:
#   - Player (left paddle) vs CPU (right paddle)
#   - First to 5 wins
#   - D-pad up/down moves player paddle
#   - Press START on title screen to begin
#   - Background music during gameplay
#   - Sound effects on paddle hits, wall bounces, and scoring

require_relative "../lib/ruby_gba"

# --- Build-time constants (plain Ruby, resolved before any ARM is emitted) ---
SCREEN_W     = 240
SCREEN_H     = 160
PADDLE_W     = 4
PADDLE_H     = 24
BALL_SIZE    = 4
PADDLE_SPEED = 2
BALL_SPEED   = 2
CPU_SPEED    = 1
WIN_SCORE    = 5
LEFT_X       = 8        # player paddle x
RIGHT_X      = 228      # cpu paddle x

rom = RubyGBA.build("PONG", code: "BPNG", maker: "01") do
  screen :bitmap
  enable_sound

  # --- Sound presets ---
  define_sound :paddle_hit, frequency: 880, duty: :quarter, decay: :fast
  define_sound :wall_bounce, frequency: 440, duty: :quarter, decay: :fast
  define_sound :point, frequency: 220, duty: :half, decay: :medium

  # --- Music ---
  song :gameplay do
    tempo 140
    duty :quarter

    # Ascending arpeggio
    note :C4, :eighth
    note :E4, :eighth
    note :G4, :eighth
    note :C5, :quarter
    rest :eighth

    # Descending
    note :G4, :eighth
    note :E4, :eighth
    note :C4, :quarter
    rest :eighth

    # Variation
    note :D4, :eighth
    note :F4, :eighth
    note :A4, :quarter
    rest :eighth

    # Resolve
    note :F4, :eighth
    note :D4, :eighth
    note :C4, :quarter
    rest :quarter
  end

  # --- RAM variables ---
  # Each `var` returns a handle we compare and mutate with the expression DSL.
  ball_x       = var :ball_x, 118
  ball_y       = var :ball_y, 78
  ball_dx      = var :ball_dx, BALL_SPEED
  ball_dy      = var :ball_dy, BALL_SPEED
  player_y     = var :player_y, 68
  cpu_y        = var :cpu_y, 68
  player_score = var :player_score, 0
  cpu_score    = var :cpu_score, 0
  state        = var :state, 0    # 0=title, 1=playing, 2=player_wins, 3=cpu_wins
  blink        = var :blink, 1    # 1=show the title prompt this frame, 0=hide it (flashes)

  # --- Subroutines ---

  func :reset_ball do
    ball_x.set 118
    ball_y.set 78
    ball_dx.flip  # reverse horizontal direction
  end

  func :reset_game do
    player_score.set 0
    cpu_score.set 0
    player_y.set 68
    cpu_y.set 68
    ball_dx.set BALL_SPEED
    ball_dy.set BALL_SPEED
    ball_x.set 118
    ball_y.set 78
    state.set 1
  end

  func :update_cpu do
    # Simple AI: slide the paddle's center toward the ball at up to CPU_SPEED per
    # frame, then keep it on-screen. approach moves cpu_y toward the target
    # without overshooting, so the paddle settles when it lines up instead of
    # jittering. The target is the ball's y minus half a paddle, so the paddle's
    # center — not its top — is what tracks the ball.
    cpu_y.approach ball_y - PADDLE_H / 2, CPU_SPEED
    cpu_y.clamp 0, SCREEN_H - PADDLE_H
  end

  func :update_ball do
    # Move ball
    ball_x.add ball_dx
    ball_y.add ball_dy

    # Bounce off top wall
    (ball_y <= 0).then do
      ball_dy.abs
      beep :wall_bounce
    end

    # Bounce off bottom wall
    (ball_y >= SCREEN_H - BALL_SIZE).then do
      ball_dy.negate_abs
      beep :wall_bounce
    end

    # Player paddle collision (left side). The ball bounces only when it truly
    # overlaps the paddle — its x-band AND its vertical span. The vertical test is
    # what makes the game winnable: without it the paddle acted like a full-height
    # wall, so the ball could never slip past to score. A paddle occupies
    # [player_y, player_y + PADDLE_H]; the ball (height BALL_SIZE) overlaps it when
    # its top sits anywhere in that span, give or take the ball's own height. `&`
    # ANDs the four comparisons — parenthesize each, since & binds tighter.
    hits_player = (ball_x >= LEFT_X) & (ball_x <= LEFT_X + PADDLE_W) &
                  (ball_y >= player_y - BALL_SIZE) & (ball_y <= player_y + PADDLE_H)
    hits_player.then do
      ball_dx.abs # bounce right
      beep :paddle_hit
    end

    # CPU paddle collision (right side) — the same overlap test against the CPU
    # paddle. The CPU tops out at CPU_SPEED, slower than the ball, so a fast
    # diagonal can leave it behind and let the player score.
    hits_cpu = (ball_x >= RIGHT_X - BALL_SIZE) & (ball_x <= RIGHT_X + PADDLE_W) &
               (ball_y >= cpu_y - BALL_SIZE) & (ball_y <= cpu_y + PADDLE_H)
    hits_cpu.then do
      ball_dx.negate_abs # bounce left
      beep :paddle_hit
    end

    # Score: ball went off left edge
    (ball_x <= 0).then do
      cpu_score.add 1
      (cpu_score >= WIN_SCORE).then { state.set 3 }
      beep :point
      call :reset_ball
    end

    # Score: ball went off right edge
    (ball_x >= SCREEN_W).then do
      player_score.add 1
      (player_score >= WIN_SCORE).then { state.set 2 }
      beep :point
      call :reset_ball
    end
  end

  func :draw_field do
    # Dashed center line
    8.times do |i|
      dma_fill_rect 119, i * 20 + 2, 2, 12, :gray
    end
  end

  # --- Scenes ---

  scene :title do
    clear_screen :black
    draw_text "PONG", 104, 40, :white
    call :draw_field

    # Flash the prompt: flip it on/off every half second.
    every(0.5, :seconds) do
      (blink == 1).then { blink.set 0 }.else { blink.set 1 }
    end
    (blink == 1).then { draw_text "PRESS START", 76, 100, :gray }

    pressed(:start).then { call :reset_game }
  end

  scene :playing do
    clear_screen :black

    # Input
    held(:up).then   { player_y.sub PADDLE_SPEED }
    held(:down).then { player_y.add PADDLE_SPEED }
    player_y.clamp 0, SCREEN_H - PADDLE_H

    # Update
    call :update_cpu
    call :update_ball

    # Draw
    call :draw_field
    draw_rect_at LEFT_X, :player_y, PADDLE_W, PADDLE_H, :white
    draw_rect_at RIGHT_X, :cpu_y, PADDLE_W, PADDLE_H, :white
    draw_rect_at :ball_x, :ball_y, BALL_SIZE, BALL_SIZE, :white

    # Live score, one digit each side of the center line (first to WIN_SCORE).
    draw_number player_score, 100, 8, :white, digits: 1
    draw_number cpu_score, 134, 8, :white, digits: 1

    # Background music
    play_song :gameplay
  end

  scene :player_wins do
    clear_screen :black
    draw_text "YOU WIN!", 88, 60, :white
    draw_text "PRESS START", 76, 100, :gray

    pressed(:start).then { state.set 0 }
  end

  scene :cpu_wins do
    clear_screen :black
    draw_text "GAME OVER", 84, 60, :white
    draw_text "PRESS START", 76, 100, :gray

    pressed(:start).then { state.set 0 }
  end

  # --- Main loop ---
  game_loop do
    wait_vblank

    case_var :state do
      when_val 0, :title
      when_val 1, :playing
      when_val 2, :player_wins
      when_val 3, :cpu_wins
    end
  end
end

output = File.join(__dir__, "pong.gba")
rom.write(output)
puts "Built pong.gba (#{rom.size} bytes)"

# Set EXPLAIN=1 to print the per-frame draw/sound-cost breakdown for the ROM —
# where the frame's work goes, and whether it fits the budget the console has to
# change the screen without tearing.
rom.explain if ENV["EXPLAIN"]
