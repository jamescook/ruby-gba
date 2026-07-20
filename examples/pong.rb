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
  display :bitmap
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
  var :ball_x, 118
  ball_y = var :ball_y, 78
  var :ball_dx, BALL_SPEED
  var :ball_dy, BALL_SPEED
  var :player_y, 68
  cpu_y = var :cpu_y, 68
  var :player_score, 0
  var :cpu_score, 0
  var :state, 0              # 0=title, 1=playing, 2=player_wins, 3=cpu_wins
  var :frame_count, 0

  # --- Subroutines ---

  func :reset_ball do
    set :ball_x, 118
    set :ball_y, 78
    flip :ball_dx  # reverse horizontal direction
  end

  func :reset_game do
    set :player_score, 0
    set :cpu_score, 0
    set :player_y, 68
    set :cpu_y, 68
    set :ball_dx, BALL_SPEED
    set :ball_dy, BALL_SPEED
    set :ball_x, 118
    set :ball_y, 78
    set :state, 1
  end

  func :update_cpu do
    # Simple AI: chase the ball, capped by CPU_SPEED. `center` is a plain Ruby
    # local holding the expression cpu_y + half a paddle — no GBA temp variable.
    center = cpu_y + PADDLE_H / 2
    (ball_y > center).then { cpu_y.add CPU_SPEED }
    (ball_y < center).then { cpu_y.sub CPU_SPEED }
    cpu_y.clamp 0, SCREEN_H - PADDLE_H
  end

  func :update_ball do
    # Move ball
    add :ball_x, :ball_dx
    add :ball_y, :ball_dy

    # Bounce off top wall
    if_le :ball_y, 0 do
      abs :ball_dy
      beep :wall_bounce
    end

    # Bounce off bottom wall
    if_ge :ball_y, SCREEN_H - BALL_SIZE do
      negate_abs :ball_dy
      beep :wall_bounce
    end

    # Player paddle collision (left side)
    # Simple check: ball_x <= LEFT_X + PADDLE_W AND ball_x >= LEFT_X
    #               AND ball_y + BALL_SIZE >= player_y AND ball_y <= player_y + PADDLE_H
    if_le :ball_x, LEFT_X + PADDLE_W do
      if_ge :ball_x, LEFT_X do
        # Simplified vertical overlap: just abs the dx (bounce right)
        abs :ball_dx
        beep :paddle_hit
      end
    end

    # CPU paddle collision (right side)
    if_ge :ball_x, RIGHT_X - BALL_SIZE do
      if_le :ball_x, RIGHT_X + PADDLE_W do
        negate_abs :ball_dx
        beep :paddle_hit
      end
    end

    # Score: ball went off left edge
    if_le :ball_x, 0 do
      add :cpu_score, 1
      if_ge :cpu_score, WIN_SCORE do
        set :state, 3
      end
      beep :point
      call :reset_ball
    end

    # Score: ball went off right edge
    if_ge :ball_x, SCREEN_W do
      add :player_score, 1
      if_ge :player_score, WIN_SCORE do
        set :state, 2
      end
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

    add :frame_count, 1
    if_lt :frame_count, 30 do
      draw_text "PRESS START", 76, 100, :gray
    end
    if_ge :frame_count, 60 do
      set :frame_count, 0
    end

    if_pressed :start do
      call :reset_game
    end
  end

  scene :playing do
    clear_screen :black

    # Input
    if_held :up do
      sub :player_y, PADDLE_SPEED
    end
    if_held :down do
      add :player_y, PADDLE_SPEED
    end
    clamp :player_y, 0, SCREEN_H - PADDLE_H

    # Update
    call :update_cpu
    call :update_ball

    # Draw
    call :draw_field
    draw_rect_at LEFT_X, :player_y, PADDLE_W, PADDLE_H, :white
    draw_rect_at RIGHT_X, :cpu_y, PADDLE_W, PADDLE_H, :white
    draw_rect_at :ball_x, :ball_y, BALL_SIZE, BALL_SIZE, :white

    # Background music
    play_song :gameplay
  end

  scene :player_wins do
    clear_screen :black
    draw_text "YOU WIN!", 88, 60, :white
    draw_text "PRESS START", 76, 100, :gray

    if_pressed :start do
      set :state, 0
    end
  end

  scene :cpu_wins do
    clear_screen :black
    draw_text "GAME OVER", 84, 60, :white
    draw_text "PRESS START", 76, 100, :gray

    if_pressed :start do
      set :state, 0
    end
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
