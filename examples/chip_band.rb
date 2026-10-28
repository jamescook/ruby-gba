#!/usr/bin/env ruby
# frozen_string_literal: true

# Chip Band — what the console's own sound voices can do with a note, one tune at a time.
#
# The screen lists the tunes; press UP or DOWN and the highlighted one plays. Every tune here
# plays on the voices the console makes itself — two square waves and the hiss — with no
# recording anywhere, which is all a Game Boy Color has for music. So it builds for the Advance
# and the Color, and sounds the same on both.
#
# HELD NOTES is a little tune of four bars the way a song's notes were before they could fade:
# each note starts at its volume and stays there until the next, like an organ.
#
# FADING NOTES is the same tune, note for note, with the voices counting each note's loudness
# down or up by themselves while it holds:
#   1. The lead is plucked: each note fades out (`decay :medium`), so a long note rings away and
#      a run of short ones sparkles. Its last note says its own, slower fade.
#   2. The second voice is a pad that breathes in: it starts each chord at nothing and swells up
#      (`volume 0` and `swell :slow`).
#   3. The drums fade at their own speeds, a long kick and a short hat, and the last hit of the
#      bar swells in instead — a cymbal played backwards (DRUMS, below).
# Switch between the two and listen to the same notes come out as two instruments.
#
# Run it to build examples/chip_band.gba and examples/chip_band.gbc:
#   ruby examples/chip_band.rb

require_relative "../lib/vblank"

module ChipBand
  TUNES = Ractor.make_shareable([
    { name: :held, label: "HELD NOTES" },
    { name: :fading, label: "FADING NOTES" },
  ])

  # The tune, as four bars of notes every version plays: the lead's [note, length] and the
  # chords under it, one a bar.
  LEAD = Ractor.make_shareable([
    [:E5, :eighth], [:G5, :eighth], [:A5, :quarter], [:G5, :eighth], [:E5, :eighth], [:D5, :quarter],
    [:C5, :eighth], [:D5, :eighth], [:E5, :eighth], [:G5, :eighth], [:A5, :half],
    [:A5, :eighth], [:G5, :eighth], [:E5, :quarter], [:D5, :eighth], [:C5, :eighth], [:D5, :quarter],
    [:E5, :quarter], [:D5, :quarter], [:C5, :half],
  ])
  CHORDS = Ractor.make_shareable(%i[C4 A3 F3 G3])

  # One bar of drums, played four times: a kick on the beat, hats between, and a last hit high up.
  # A noise note's pitch is how high the hiss sits, so a low one is a kick and a high one a hat.
  # Each hit says how it fades when the tune lets it — a long kick, a short hat, and the last hit
  # swelling in from almost nothing, a cymbal played backwards.
  DRUMS = Ractor.make_shareable([
    [:C2, :quarter, { decay: :slow }],
    [:C6, :eighth, { decay: :fast }],
    [:C6, :eighth, { decay: :fast }],
    [:C2, :quarter, { decay: :slow }],
    [:C5, :quarter, { swell: :medium, volume: 2 }],
  ])

  GAME = Ractor.make_shareable(VBlank.game("CHIP BAND", consoles: %i[gba gbc]) do
    screen :bitmap
    enable_sound

    song :held do
      tempo 132
      voice :lead do |v|
        v.duty :half
        LEAD.each { |pitch, length| v.note pitch, length }
      end
      voice :chords do |v|
        v.duty :quarter
        v.volume 6
        CHORDS.each { |pitch| v.note pitch, :whole }
      end
      # Every hit holds until the next, the way the rest of this tune does.
      voice :drums, plays: :noise do |v|
        v.decay :none
        v.volume 6
        4.times { DRUMS.each { |pitch, length, _fade| v.note pitch, length } }
      end
    end

    song :fading do
      tempo 132
      voice :lead do |v|
        v.duty :half
        v.decay :medium
        LEAD[0...-1].each { |pitch, length| v.note pitch, length }
        pitch, length = LEAD.last
        v.note pitch, length, decay: :slow
      end
      voice :chords do |v|
        v.duty :quarter
        v.volume 0
        v.swell :slow
        CHORDS.each { |pitch| v.note pitch, :whole }
      end
      voice :drums, plays: :noise do |v|
        v.volume 9
        4.times { DRUMS.each { |pitch, length, fade| v.note pitch, length, **fade } }
      end
    end

    # --- The screen: a title, and the list of tunes ---
    title_y = screen_height / 6
    clear_screen :black
    draw_text "CHIP BAND", :center, title_y, :white
    draw_text "PRESS UP OR DOWN", :center, title_y + 12, :gray

    game_loop do
      # Whichever row the cursor is on is the tune that plays: naming the tune playing changes
      # nothing, and naming another starts it from its first note.
      tunes = menu :tunes, at: [screen_width / 6, screen_height / 2], color: :gray, picked: :yellow do |m|
        TUNES.each { |tune| m.item tune[:label] }
      end
      TUNES.each_with_index do |tune, i|
        (tunes.picked == i).then { play_song tune[:name] }
      end
    end
  end)

  def self.program(...) = GAME.program(...)
end

ChipBand::GAME.write_if_main
