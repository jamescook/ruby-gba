#!/usr/bin/env ruby
# frozen_string_literal: true

# Piano — one hand playing a tune, animated.
#
# A left hand hovers over a keyboard and plays "Mary Had a Little Lamb" by itself.
# On every note the RIGHT finger presses down onto the RIGHT key, the key lights,
# and you hear the note. There's no synthesizer here: one real piano note is
# recorded once (examples/assets/piano.wav) and the `instrument` verb re-pitches
# that single recording across the keys — so a whole melody comes from one sample.
#
# This is the first rung of the two-hands-piano capstone: prove one hand animates
# correctly to a scored melody, then add the second hand and chords.
#
# The art and sound are FILES imported next to this script, drawn/synthesized by
# tools/make_piano_assets.rb (re-run it to change them):
#   - assets/piano_hand_rest.png + piano_hand_f0..f3.png — the hand's poses
#   - assets/piano.wav                                   — the recorded note
#
# Run it to build examples/piano.gba:
#   ruby examples/piano.rb

require_relative "../lib/ruby_gba"

module Piano
  # --- Layout (pixels; the screen is 240x160, origin top-left) ---
  KEY_W       = 16              # each white key is 16px wide (two 8px tiles)
  KEYBOARD_Y  = 120             # the keys fill the bottom 40px of the screen
  HAND_X      = 96             # the hand sits over keys 6..9 …
  HAND_Y      = 90             # … its four fingers reaching down to the key tops
  HILITE_Y    = 138            # the "this key is lit" patch, on the key face below the finger

  # The hand covers four adjacent keys. Each note of the tune maps to one of them:
  # which key it lights (an index across the keyboard), and which finger presses it
  # (f0 = the leftmost/pinky … f3 = the rightmost). Left-to-right fingers over
  # left-to-right keys is how a left hand actually falls on the keys.
  KEY_INDEX = { C: 6, D: 7, E: 8, G: 9 }.freeze
  FINGER    = { C: :f0, D: :f1, E: :f2, G: :f3 }.freeze
  PITCH     = { C: :C4, D: :D4, E: :E4, G: :G4 }.freeze

  # "Mary Had a Little Lamb" as [note, frames-to-hold]. 24 frames ~= a quarter note
  # at 60fps; 48 a half, 96 the final long note. Only C D E G are used — four keys,
  # four fingers.
  SCORE = [
    [:E, 24], [:D, 24], [:C, 24], [:D, 24], [:E, 24], [:E, 24], [:E, 48],
    [:D, 24], [:D, 24], [:D, 48], [:E, 24], [:G, 24], [:G, 48],
    [:E, 24], [:D, 24], [:C, 24], [:D, 24], [:E, 24], [:E, 24], [:E, 24], [:E, 24],
    [:D, 24], [:D, 24], [:E, 24], [:D, 24], [:C, 96]
  ].freeze

  RELEASE = 4 # lift the finger this many frames before a note ends, so repeats re-strike

  GAME = proc do
    # Tiled mode: the console composites the hand and the key-light as hardware
    # sprites over the keyboard background — no framebuffer, no redraw by hand.
    screen :tiled

    # --- The keyboard, drawn once as a static background ---
    # Two 8x8 tiles: a key's left edge (a black separator line, then white) and a
    # key's body (all white). Laid side by side, "LR" is one 16px white key, and a
    # row of them is a keyboard. The dark left edge of the next key is the gap.
    image :key_left, "|" => :black, "." => :white do
      <<~ART
        |.......
        |.......
        |.......
        |.......
        |.......
        |.......
        |.......
        |.......
      ART
    end
    image :key_body, "." => :white do
      <<~ART
        ........
        ........
        ........
        ........
        ........
        ........
        ........
        ........
      ART
    end
    tiles :keys, "L" => :key_left, "R" => :key_body

    # 20 rows tall; the bottom five are the keyboard, the rest is empty (the dark
    # backdrop shows through). "LR" x 15 = 15 keys across the 240px screen.
    rows = Array.new(15, " " * 30) + Array.new(5, "LR" * 15)
    background :keyboard, tiles: :keys, map: rows

    # --- The hand's poses and the key-light, imported from files ---
    image :hand_rest, from: "assets/piano_hand_rest.png", width: 64, height: 32, transparent: true
    4.times { |k| image :"hand_f#{k}", from: "assets/piano_hand_f#{k}.png", width: 64, height: 32, transparent: true }
    image :key_light, "#" => :yellow do
      <<~ART
        ################
        ################
        ################
        ################
        ################
        ################
        ################
        ################
      ART
    end

    # One recorded note, pitched across the keys by `instrument`.
    piano = instrument :piano, from: "assets/piano.wav", note: :C4

    draw_text "PIANO", 100, 8, :white # a title (tiled-mode text: declared above the loop)

    # The hand starts in the rest pose (first entry); each note swaps to a finger
    # pose. Declared before the key-light so the light draws in front of the key.
    hand = sprite :hand, at: [HAND_X, HAND_Y],
                  facing: { rest: :hand_rest, f0: :hand_f0, f1: :hand_f1, f2: :hand_f2, f3: :hand_f3 }
    light = sprite :key_light, at: [0, HILITE_Y], shown: false

    # A frame counter that walks the score and loops it.
    seq = var :seq, 0

    game_loop do
      wait_vblank

      # Walk the score: at each note's start frame, sound it, press the right
      # finger, and light the right key; a few frames before it ends, lift the
      # finger and drop the light so the next (or a repeated) note re-strikes.
      cursor = 0
      SCORE.each do |letter, dur|
        (seq == cursor).then do
          piano.play(PITCH[letter])
          hand.face(FINGER[letter])
          light.move_to(KEY_INDEX[letter] * KEY_W, HILITE_Y)
          light.show
        end
        (seq == cursor + dur - RELEASE).then do
          hand.face(:rest)
          light.hide
        end
        cursor += dur
      end

      seq.add 1
      (seq >= cursor).then { seq.set 0 } # cursor is the whole tune's length — loop it
    end
  end

  def self.build_rom(out: $stdout, err: $stderr)
    RubyGBA.build("PIANO", code: "BPNO", maker: "01", out: out, err: err, &GAME)
  end

  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Piano.build_rom
  output = File.join(__dir__, "piano.gba")
  rom.write(output)
  puts "Built piano.gba (#{rom.size} bytes)"

  # Set EXPLAIN=1 to print the per-frame draw/sound-cost breakdown — where the
  # frame's work goes (the hand and key-light sprites, the software mixer refilling
  # the sound buffer), and whether it fits the console's screen-update budget.
  rom.explain if ENV["EXPLAIN"]
end
