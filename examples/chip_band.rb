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
# each note of the melody and the chords starts at its volume and stays there until the next,
# like an organ. Its drums ring out, as drums always did.
#
# FADING NOTES is the same tune, note for note, with the voices counting each note's loudness
# down or up by themselves while it holds:
#   1. The lead is plucked: each note fades out (`decay :medium`), so a long note rings away and
#      a run of short ones sparkles. Its last note says its own, slower fade.
#   2. The second voice is a pad that breathes in: it starts each chord at nothing and swells up
#      over the bar (`volume 0` and `swell 7`, the slowest).
#   3. The drums say how each hit fades, and the last hit of the bar swells in instead — a
#      cymbal played backwards (DRUMS, below).
# Switch between the two and listen to the same notes come out as two instruments.
#
# SLIDING NOTES is the same tune again, with the lead's pitch moving by itself while each note
# holds — only the first square voice can, so only the lead slides:
#   1. Every eighth note zaps up (`slide_up: :fast`): it climbs faster and faster until it runs off
#      the top of what the voice can play, and goes silent — the sound of a laser.
#   2. Every longer note swoops slowly down (`slide_down :slow`), falling away under the chords.
#
# The chords and the drums play as they do in FADING NOTES.
#
# WOBBLING NOTES is the tune sung: the music player moves each note's pitch a little above and
# below where it began, a few frames each way, the way a singer's voice wobbles on a held note.
#   1. The lead waits an eighth into each note before it wobbles (`vibrato after: :eighth`), so a
#      short note stays straight and a long one blooms.
#   2. The chords wobble slightly and slowly from the start, a string section.
#
# LEFT AND RIGHT is the tune spread across the two speakers, the way a band stands on a stage
# (best heard on headphones):
#   1. The lead plays from the left (`pan :left`) and the chords from the right.
#   2. The drums play from both, and the hats between the kicks step from one side to the other
#      (`pan: :left`, `pan: :right` on a note of their own).
#
# SHIMMERING NOTES is the tune with the square waves' shapes moving: how much of each wave is high,
# which is what makes a square wave thin or hollow.
#   1. The lead steps through four shapes, one a frame, round and round while each note holds
#      (`duty %i[eighth quarter half quarter]`): a shimmer the ear hears as one bright tone.
#   2. The chords play each bar in a shape of its own, thin, then hollow, then thin and thick
#      (`duty:` on a note of their own).
#
# DETUNED NOTES is the tune played twice at once, the way a chorus thickens one voice:
#   1. The lead, as written.
#   2. The same notes on the second square voice, two of the voice's own pitch steps sharp
#      (`pitch_offset 2`), so the two beat against each other — a slow wobble neither has alone.
#   3. The same notes again an octave down on the wave voice (`transpose(-12)`), a soft bass.
#
# Run it to build examples/chip_band.gba and examples/chip_band.gbc:
#   ruby examples/chip_band.rb

require_relative "../lib/vblank"

module ChipBand
  TUNES = Ractor.make_shareable([
    { name: :held, label: "HELD NOTES" },
    { name: :fading, label: "FADING NOTES" },
    { name: :sliding, label: "SLIDING NOTES" },
    { name: :wobbling, label: "WOBBLING NOTES" },
    { name: :spread, label: "LEFT AND RIGHT" },
    { name: :shimmering, label: "SHIMMERING NOTES" },
    { name: :detuned, label: "DETUNED NOTES" },
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
  # A noise note's pitch is how high the hiss sits, so a lower one is a kick and a high one a hat —
  # though a hiss held low and long is a rumble under everything, so the kick is kept short. Each
  # hit says how it fades when the tune lets it: a quick kick, a quicker hat, and the last hit
  # rising from almost nothing and cut off by the next bar, a cymbal played backwards.
  # (The note names stop at C6, so the hat's hiss is given in Hz.)
  DRUMS = Ractor.make_shareable([
    [:C4, :quarter, { decay: :fast }],
    [4000, :eighth, { decay: :fast }],
    [4000, :eighth, { decay: :fast }],
    [:C4, :quarter, { decay: :fast }],
    [:C6, :quarter, { swell: 4, volume: 1 }],
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
      # The drums ring out the way a drum part always did, every hit alike.
      voice :drums, plays: :noise do |v|
        v.volume 8
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
      # The slowest swell there is: a bar to climb from nothing to full.
      voice :chords do |v|
        v.duty :quarter
        v.volume 0
        v.swell 7
        CHORDS.each { |pitch| v.note pitch, :whole }
      end
      voice :drums, plays: :noise do |v|
        v.volume 9
        4.times { DRUMS.each { |pitch, length, fade| v.note pitch, length, **fade } }
      end
    end

    song :sliding do
      tempo 132
      # The lead is the song's first square part, so it plays on the voice that can slide.
      voice :lead do |v|
        v.duty :half
        v.slide_down :slow
        LEAD.each do |pitch, length|
          length == :eighth ? v.note(pitch, length, slide_up: :fast) : v.note(pitch, length)
        end
      end
      voice :chords do |v|
        v.duty :quarter
        v.volume 0
        v.swell 7
        CHORDS.each { |pitch| v.note pitch, :whole }
      end
      voice :drums, plays: :noise do |v|
        v.volume 9
        4.times { DRUMS.each { |pitch, length, fade| v.note pitch, length, **fade } }
      end
    end

    song :wobbling do
      tempo 132
      voice :lead do |v|
        v.duty :half
        v.vibrato depth: :medium, speed: :medium, after: :eighth
        LEAD.each { |pitch, length| v.note pitch, length }
      end
      voice :chords do |v|
        v.duty :quarter
        v.volume 6
        v.vibrato depth: :slight, speed: :slow
        CHORDS.each { |pitch| v.note pitch, :whole }
      end
      voice :drums, plays: :noise do |v|
        v.volume 9
        4.times { DRUMS.each { |pitch, length, fade| v.note pitch, length, **fade } }
      end
    end

    song :spread do
      tempo 132
      voice :lead do |v|
        v.duty :half
        v.pan :left
        LEAD.each { |pitch, length| v.note pitch, length }
      end
      voice :chords do |v|
        v.duty :quarter
        v.volume 6
        v.pan :right
        CHORDS.each { |pitch| v.note pitch, :whole }
      end
      # The two hats of each bar, the first on the left and the second on the right.
      voice :drums, plays: :noise do |v|
        v.volume 9
        hats = %i[left right]
        4.times do
          DRUMS.each do |pitch, length, fade|
            side = pitch == 4000 ? { pan: hats.first.tap { hats.rotate! } } : {}
            v.note pitch, length, **fade, **side
          end
        end
      end
    end

    song :shimmering do
      tempo 132
      voice :lead do |v|
        v.duty %i[eighth quarter half quarter]
        LEAD.each { |pitch, length| v.note pitch, length }
      end
      # A shape of its own for each bar's chord.
      voice :chords do |v|
        v.volume 6
        CHORDS.zip([:eighth, :half, :quarter, %i[eighth three_quarter]]).each do |pitch, shape|
          v.note pitch, :whole, duty: shape
        end
      end
      voice :drums, plays: :noise do |v|
        v.volume 9
        4.times { DRUMS.each { |pitch, length, fade| v.note pitch, length, **fade } }
      end
    end

    song :detuned do
      tempo 132
      voice :lead do |v|
        v.duty :half
        LEAD.each { |pitch, length| v.note pitch, length }
      end
      voice :chorus do |v|
        v.duty :half
        v.volume 9
        v.pitch_offset 2
        LEAD.each { |pitch, length| v.note pitch, length }
      end
      voice :bass, plays: :wave do |v|
        v.volume 9
        v.transpose(-12)
        LEAD.each { |pitch, length| v.note pitch, length }
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
