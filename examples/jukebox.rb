#!/usr/bin/env ruby
# frozen_string_literal: true

# Jukebox — a tiny music player with three classical tunes.
#
# The screen lists three pieces; press UP or DOWN to move the cursor, and the
# highlighted tune plays and loops on the music channel — the selection you can
# hear. A row of little blocks bobs along underneath so you can see that
# something is playing. All three melodies are written with the note/tempo DSL
# (see `song` below) — no hardware, no registers, just notes and durations.
#
# This is the sound showcase: proof that a real, recognizable tune is easy to
# write and plays correctly (every one opens on its downbeat).
#
# Run it to build examples/jukebox.gba:
#   ruby examples/jukebox.rb

require_relative "../lib/ruby_gba"

module Jukebox
  # --- Layout (pixels; the screen is 240x160, origin top-left) ---
  SCREEN_W   = 240
  FIRST_ROW  = 58
  ROW_GAP    = 20

  # The bobbing "it's playing" blocks along the bottom: five 8x8 blocks that
  # bounce between BAR_TOP and BAR_BOTTOM at their own speeds, so they dance a
  # little out of step. Each is [x, start_y, speed].
  BARS       = [[84, 124, 2], [100, 148, 3], [116, 132, 2], [132, 146, 3], [148, 128, 2]].freeze
  BAR_TOP    = 124
  BAR_BOTTOM = 148

  # Each song gets an accent color, so moving the cursor recolors the screen as
  # well as changing the tune.
  SONGS = [
    { name: :ode_to_joy, label: "ODE TO JOY",  color: :yellow },
    { name: :fur_elise,  label: "FUR ELISE",   color: :cyan },
    { name: :minuet,     label: "MINUET IN G", color: :magenta },
  ].freeze

  GAME = RubyGBA.game("JUKEBOX", code: "BJKB", maker: "01") do
    # Double-buffered so the full repaint each frame can't tear: we draw the whole
    # menu to a hidden screen and show it all at once.
    screen :bitmap, tear_free: true
    enable_sound

    # --- The three tunes, each a plain note/tempo score ---

    # Beethoven, "Ode to Joy" (Symphony No. 9) — stepwise and instantly familiar.
    # Played two-handed: the tune up top over a simple tonic/dominant (C/G) bass,
    # one whole note a measure. The two parts share the tempo and stay in step.
    song :ode_to_joy do
      tempo 100
      voice :melody do
        duty :half
        volume 12
        note :E4, :quarter; note :E4, :quarter; note :F4, :quarter; note :G4, :quarter
        note :G4, :quarter; note :F4, :quarter; note :E4, :quarter; note :D4, :quarter
        note :C4, :quarter; note :C4, :quarter; note :D4, :quarter; note :E4, :quarter
        note :E4, :dotted_quarter; note :D4, :eighth; note :D4, :half
        note :E4, :quarter; note :E4, :quarter; note :F4, :quarter; note :G4, :quarter
        note :G4, :quarter; note :F4, :quarter; note :E4, :quarter; note :D4, :quarter
        note :C4, :quarter; note :C4, :quarter; note :D4, :quarter; note :E4, :quarter
        note :D4, :dotted_quarter; note :C4, :eighth; note :C4, :half
      end
      voice :bass do
        duty :half
        volume 7
        note :C3, :whole; note :G2, :whole; note :C3, :whole; note :G2, :whole
        note :C3, :whole; note :G2, :whole; note :C3, :whole; note :C3, :whole
      end
    end

    # Beethoven, "Für Elise" — the famous rocking opening in A minor.
    song :fur_elise do
      tempo 120
      duty :quarter
      note :E5, :eighth; note :Ds5, :eighth; note :E5, :eighth; note :Ds5, :eighth
      note :E5, :eighth; note :B4, :eighth;  note :D5, :eighth; note :C5, :eighth
      note :A4, :quarter; rest :eighth
      note :C4, :eighth; note :E4, :eighth; note :A4, :eighth
      note :B4, :quarter; rest :eighth
      note :E4, :eighth; note :Gs4, :eighth; note :B4, :eighth
      note :C5, :quarter; rest :eighth
      note :E4, :eighth
      note :E5, :eighth; note :Ds5, :eighth; note :E5, :eighth; note :Ds5, :eighth
      note :E5, :eighth; note :B4, :eighth;  note :D5, :eighth; note :C5, :eighth
      note :A4, :quarter; rest :quarter
    end

    # Petzold's "Minuet in G" (long attributed to J.S. Bach) — a courtly dance.
    song :minuet do
      tempo 120
      duty :half
      note :D5, :quarter
      note :G4, :eighth; note :A4, :eighth; note :B4, :eighth; note :C5, :eighth
      note :D5, :quarter; note :G4, :quarter; note :G4, :quarter
      note :E5, :quarter
      note :C5, :eighth; note :D5, :eighth; note :E5, :eighth; note :Fs5, :eighth
      note :G5, :quarter; note :G4, :quarter; note :G4, :quarter
    end

    # --- Layout the font works out ---
    #
    # The rows are a left-aligned column so the cursor lines up under itself, and the
    # column is centred on the widest song name. Ask the font how wide the names come
    # out and nothing here is a number counted by eye: reword a song and the menu
    # moves with it.
    widest  = SONGS.map { |s| text_width(s[:label]) }.max
    label_x = (SCREEN_W - widest) / 2

    # --- State ---
    # A bobbing block's position (bar_y#) and signed speed (bar_v#), one pair each.
    bar_y = BARS.each_index.map { |i| var :"bar_y#{i}", BARS[i][1] }
    BARS.each_index { |i| var :"bar_v#{i}", BARS[i][2] }

    game_loop do
      # --- Advance the bobbing blocks: move each by its speed, and reverse (snap
      # to the edge, flip the sign) whenever it reaches the top or bottom. ---
      BARS.each_with_index do |(_x, _y0, spd), i|
        y = bar_y[i]
        add :"bar_y#{i}", :"bar_v#{i}"
        (y >= BAR_BOTTOM).then { y.set BAR_BOTTOM; set :"bar_v#{i}", -spd }
        (y <= BAR_TOP).then    { y.set BAR_TOP;    set :"bar_v#{i}",  spd }
      end

      # --- Draw the screen fresh each frame ---
      clear_screen :black
      draw_text "JUKEBOX", :center, 14, :white
      draw_rect_at label_x, 26, widest, 2, :gray
      draw_text "PRESS UP OR DOWN", :center, 34, :gray
      draw_text "NOW PLAYING", :center, 108, :gray

      # The list of tunes. Each row lights up in its own accent color when the cursor
      # reaches it; the cursor, the wrapping and the held-button walk come with the
      # verb. There is no block per row because on this screen MOVING is the choice —
      # whichever row the cursor is on is the tune that plays.
      songs = menu :songs, at: [label_x, FIRST_ROW], spacing: ROW_GAP, color: :gray do |m|
        SONGS.each { |s| m.item s[:label], picked: s[:color] }
      end

      # The picked row also tints the bobbing blocks and is the tune that plays. Naming it
      # every frame is fine — it is the tune playing now — and naming a different one
      # silences the old tune and starts the new one from its first note.
      SONGS.each_with_index do |s, i|
        (songs.picked == i).then do
          BARS.each_with_index { |(bx, _y0, _spd), j| draw_rect_at bx, :"bar_y#{j}", 8, 8, s[:color] }
          play_song s[:name]
        end
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Jukebox::GAME.write_if_main
