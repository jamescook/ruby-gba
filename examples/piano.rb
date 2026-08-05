#!/usr/bin/env ruby
# frozen_string_literal: true

# Piano — two hands playing a tune, animated.
#
# A right hand plays the melody of "Mary Had a Little Lamb" while a left hand vamps
# a block chord underneath. On each note the melody hand's right finger stabs the
# right key; on each downbeat the left hand presses TWO keys at once and, together
# with the melody note, three notes sound at the same time — a real two-hand chord
# with no voice cutting out. There's no synthesizer: one recorded piano note
# (examples/assets/piano.wav) is re-pitched across the keys by `instrument`, and a
# software mixer sums the sounding voices, so a whole two-handed arrangement comes
# from a single sample.
#
# Tiled mode: the two hands, their fingers, and the key-lights are hardware sprites
# the console composites over the keyboard background.
#
# The art and sound are files imported next to this script, drawn and synthesized
# by tools/make_piano_assets.rb (re-run it to change them):
#   - assets/piano_right_rest.png + piano_right_f0..f3.png — the melody hand
#   - assets/piano_left_rest.png  + piano_left_chord.png   — the chord hand
#   - assets/piano.wav                                     — the recorded note
#
# Run it to build examples/piano.gba:
#   ruby examples/piano.rb

require_relative "../lib/ruby_gba"

module Piano
  # --- Layout (pixels; the screen is 240x160, origin top-left) ---
  KEY_W        = 16            # each white key is 16px wide (two 8px tiles)
  HAND_Y       = 90            # both hands hover here, fingers reaching to the keys
  HILITE_Y     = 138           # the "this key is lit" patch, on the key face
  RIGHT_HAND_X = 8 * KEY_W     # the melody hand sits over keys 8..11
  LEFT_HAND_X  = 1 * KEY_W     # the chord hand sits over keys 1..4

  # Right-hand melody: each note names the key it lights, the finger that presses it
  # (f0 leftmost … f3 rightmost), and the pitch it sounds. The keyboard is
  # unlabeled, so we just declare the pitch each finger plays.
  MEL_KEY   = { C: 8, D: 9, E: 10, G: 11 }.freeze
  MEL_FACE  = { C: :f0, D: :f1, E: :f2, G: :f3 }.freeze
  MEL_PITCH = { C: :C4, D: :D4, E: :E4, G: :G4 }.freeze

  # "Mary Had a Little Lamb" as [note, frames-to-hold]. 24 frames ~= a quarter note
  # at 60fps; 48 a half, 96 the final long note.
  MELODY = [
    [:E, 24], [:D, 24], [:C, 24], [:D, 24], [:E, 24], [:E, 24], [:E, 48],
    [:D, 24], [:D, 24], [:D, 48], [:E, 24], [:G, 24], [:G, 48],
    [:E, 24], [:D, 24], [:C, 24], [:D, 24], [:E, 24], [:E, 24], [:E, 24], [:E, 24],
    [:D, 24], [:D, 24], [:E, 24], [:D, 24], [:C, 96]
  ].freeze

  # Left hand: a two-note block chord (root + fifth), its outer two fingers pressing
  # keys 1 and 4 together, struck on each measure's downbeat.
  CHORD_KEYS  = [1, 4].freeze
  CHORD_PITCH = %i[C3 G3].freeze
  MEASURE     = 96             # frames per measure — a chord on each downbeat
  CHORD_HOLD  = 60             # frames the chord stays down before lifting
  RELEASE     = 4             # lift a melody finger this many frames before its note ends

  GAME = RubyGBA.game("PIANO", code: "BPNO", maker: "01") do
    # Tiled mode: the console composites the hands and the key-lights as hardware
    # sprites over the keyboard background — no framebuffer, no redraw by hand.
    screen :tiled

    # --- The keyboard, drawn once as a static background ---
    # Two 8x8 tiles: a key's left edge (a black separator line, then white) and a
    # key's body (all white). "LR" is one 16px white key; a row of them is a keyboard.
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

    # 20 rows tall; the bottom five are the keyboard, the rest empty (dark backdrop).
    rows = Array.new(15, " " * 30) + Array.new(5, "LR" * 15)
    background :keyboard, tiles: :keys, map: rows

    # --- The hands' poses and the key-light, imported from files ---
    image :rh_rest, from: "assets/piano_right_rest.png", width: 64, height: 32, transparent: true
    4.times { |k| image :"rh_f#{k}", from: "assets/piano_right_f#{k}.png", width: 64, height: 32, transparent: true }
    image :lh_rest, from: "assets/piano_left_rest.png", width: 64, height: 32, transparent: true
    image :lh_chord, from: "assets/piano_left_chord.png", width: 64, height: 32, transparent: true
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

    # One recorded note, pitched across the keys by `instrument`; the mixer lets the
    # two hands' notes sound at once.
    piano = instrument :piano, from: "assets/piano.wav", note: :C4

    draw_text "PIANO", 100, 8, :white # a title (tiled-mode text: declared above the loop)

    # Each hand starts resting; the melody hand swaps to a finger pose per note, the
    # chord hand to its two-finger pose. Declared before the lights so the lights
    # draw in front of the keys.
    rhand = sprite :rhand, at: [RIGHT_HAND_X, HAND_Y],
                   facing: { rest: :rh_rest, f0: :rh_f0, f1: :rh_f1, f2: :rh_f2, f3: :rh_f3 }
    lhand = sprite :lhand, at: [LEFT_HAND_X, HAND_Y], facing: { rest: :lh_rest, chord: :lh_chord }

    # Key-lights: one for the melody (it hops from key to key), two fixed on the
    # chord's keys. They share one picture; each `sprite` call is its own object.
    melody_light = sprite :key_light, at: [0, HILITE_Y], shown: false
    chord_lights = CHORD_KEYS.map { |k| sprite :key_light, at: [k * KEY_W, HILITE_Y], shown: false }

    seq = var :seq, 0

    game_loop do
      # --- Right hand: the melody. At each note's start, sound it, press the right
      # finger, light the right key; lift shortly before the note ends so the next
      # (or a repeated) note re-strikes. ---
      cursor = 0
      MELODY.each do |letter, dur|
        (seq == cursor).then do
          piano.play(MEL_PITCH[letter])
          rhand.face(MEL_FACE[letter])
          melody_light.move_to(MEL_KEY[letter] * KEY_W, HILITE_Y)
          melody_light.show
        end
        (seq == cursor + dur - RELEASE).then do
          rhand.face(:rest)
          melody_light.hide
        end
        cursor += dur
      end
      total = cursor

      # --- Left hand: a block chord on each downbeat. Its two notes sound in the
      # same frame as the melody note, so a downbeat is three voices at once — the
      # two-hand chord — which the mixer holds without any of them cutting out. ---
      (0...total).step(MEASURE).each do |m|
        (seq == m).then do
          piano.play(*CHORD_PITCH)
          lhand.face(:chord)
          chord_lights.each(&:show)
        end
        (seq == m + CHORD_HOLD).then do
          lhand.face(:rest)
          chord_lights.each(&:hide)
        end
      end

      seq.add 1
      (seq >= total).then { seq.set 0 } # loop the piece
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Piano::GAME.write_if_main
