# frozen_string_literal: true

require "zlib"

require_relative "../lib/ruby_gba"
require_relative "preview"

# Generate the art and sound examples/piano.rb imports: a left hand drawn in a few
# poses, and one recorded piano note.
#
# Like tools/make_example_assets.rb, the point is that game assets are FILES you
# drop in — but the repo still needs a couple of real ones checked in to import.
# Rather than commit opaque binaries, this draws/synthesizes them from plain data
# so you can see (and change) exactly what they contain, then re-run to regenerate:
#
#   ruby tools/make_piano_assets.rb
#
# It writes, under examples/assets/:
#   - piano_right_rest.png + piano_right_f0..f3.png — the right hand hovering, and
#     with each finger pressed (f0 leftmost … f3 rightmost) — it plays the melody
#   - piano_left_rest.png + piano_left_chord.png    — the left hand hovering, and
#     its two-finger block chord (the outer two fingers down together)
#   - piano.wav — a single ~0.6s piano-ish note at C4, which the `instrument` verb
#     pitches across the keys.
module MakePianoAssets
  Color = RubyGBA::Color

  ASSETS = File.expand_path("../examples/assets", __dir__)

  # --- The hand's size and where its four fingers sit ---
  # A 64x32 sprite (a valid hardware-sprite size). The four fingers hang down from
  # a shallow palm, evenly spaced so each lines up with a 16px-wide key below it.
  # Seen as the back of a LEFT hand: left to right they are pinky, ring, middle,
  # index. Their RESTING lengths differ — middle longest, pinky shortest — which is
  # what makes the silhouette read as a hand and not a comb; a finger PRESSING a key
  # extends down to a common lower row (a clear, uniform stab onto the keys).
  HAND_W = 64
  HAND_H = 32
  FINGERS = 4
  FINGER_CX = Array.new(FINGERS) { |k| 8 + (k * 16) } # 8, 24, 40, 56 — a finger per key
  FINGER_HALF = 4            # half a finger's width (9px across)
  PALM_TOP = 1
  PALM_BOTTOM = 9            # a shallow palm, leaving most of the sprite for fingers
  FINGER_TOP = 8             # fingers grow out of the palm's lower edge
  PRESS_TIP = 31             # a pressed finger stabs down to here, onto the key

  # Natural resting finger lengths, so the silhouette reads as a hand. The left hand
  # runs pinky, ring, middle, index left to right; the right hand is its mirror, so
  # its lengths are the same list reversed. (Longest in the middle either way.)
  LEFT_REST_TIPS  = [19, 22, 24, 21].freeze
  RIGHT_REST_TIPS = LEFT_REST_TIPS.reverse.freeze
  CHORD_FINGERS = [0, 3].freeze # the outer two fingers, for the left hand's block chord

  # --- palette (5-bit-per-channel console colors) ---
  SKIN    = Color.rgb(31, 23, 17)  # the back of the hand / fingers
  SKIN_D  = Color.rgb(25, 17, 12)  # a darker skin tone for the seams between fingers
  OUTLINE = Color.rgb(3, 1, 1)     # the near-black cartoon outline, like the reference art
  NAIL    = Color.rgb(31, 29, 26)  # a pale fingernail at each tip

  # --- the note ---
  WAV_RATE = 8192      # samples per second
  NOTE_HZ  = 262.0     # middle C (C4); `instrument` shifts it up for higher keys
  NOTE_LEN = 0.6       # seconds — long enough to ring under the next note

  module_function

  def run
    Dir.mkdir(ASSETS) unless Dir.exist?(ASSETS)
    # Right hand plays the melody — a resting pose plus one pose per finger pressed.
    File.binwrite(File.join(ASSETS, "piano_right_rest.png"), hand_png([], RIGHT_REST_TIPS))
    FINGERS.times { |k| File.binwrite(File.join(ASSETS, "piano_right_f#{k}.png"), hand_png([k], RIGHT_REST_TIPS)) }
    # Left hand plays a block chord — just resting and its two-finger chord pose.
    File.binwrite(File.join(ASSETS, "piano_left_rest.png"), hand_png([], LEFT_REST_TIPS))
    File.binwrite(File.join(ASSETS, "piano_left_chord.png"), hand_png(CHORD_FINGERS, LEFT_REST_TIPS))
    File.binwrite(File.join(ASSETS, "piano.wav"), piano_wav)
    puts "wrote #{ASSETS}/piano_right_rest.png, piano_right_f0..f#{FINGERS - 1}.png, " \
         "piano_left_rest.png, piano_left_chord.png and piano.wav"
  end

  # --- the hand poses ---

  # Draw a hand. +pressed+ is the list of finger indices pushed down onto their keys
  # (empty for the resting pose, one for a melody note, two for the left hand's block
  # chord); +rest_tips+ gives each finger's resting length, which is what makes a left
  # or right hand. Drawn on a transparent background so the sprite is a clean cut-out.
  def hand_png(pressed, rest_tips)
    rgb = Array.new(HAND_W * HAND_H, SKIN)
    alpha = Array.new(HAND_W * HAND_H, 0) # see-through until a pixel is drawn
    put = lambda do |x, y, color|
      next unless x.between?(0, HAND_W - 1) && y.between?(0, HAND_H - 1)

      rgb[(y * HAND_W) + x] = color
      alpha[(y * HAND_W) + x] = 255
    end

    draw_palm(put)
    FINGERS.times do |k|
      tip = pressed.include?(k) ? PRESS_TIP : rest_tips[k]
      draw_finger(put, FINGER_CX[k], tip)
    end

    rgba_png(HAND_W, HAND_H, rgb, alpha)
  end

  # The back of the hand: a filled block outlined on top and sides. The bottom is
  # left open — that's where the fingers grow out of it, so they merge seamlessly.
  def draw_palm(put)
    (PALM_TOP..PALM_BOTTOM).each do |y|
      (3..60).each { |x| put.call(x, y, SKIN) }
    end
    (3..60).each { |x| put.call(x, PALM_TOP, OUTLINE) }                             # top edge
    (PALM_TOP..PALM_BOTTOM).each { |y| put.call(2, y, OUTLINE); put.call(61, y, OUTLINE) } # sides
  end

  # One finger: a column of skin from the palm down to +tip+ — outlined on both
  # sides, tapered to a rounded fingertip, with a knuckle crease near the top and a
  # pale nail at the end. +cx+ is its center column; a longer +tip+ is a press.
  def draw_finger(put, cx, tip)
    left = cx - FINGER_HALF
    right = cx + FINGER_HALF
    (FINGER_TOP..tip - 1).each do |y|
      inset = y >= tip - 1 ? 2 : 1                 # pull the last skin row in for a round tip
      (left + inset..right - inset).each { |x| put.call(x, y, SKIN) }
    end
    (FINGER_TOP + 1..tip - 2).each { |y| put.call(right - 1, y, SKIN_D) } # shading down one side
    (FINGER_TOP..tip - 2).each { |y| put.call(left, y, OUTLINE); put.call(right, y, OUTLINE) }
    put.call(left + 1, tip - 1, OUTLINE)           # rounded-tip outline
    put.call(right - 1, tip - 1, OUTLINE)
    (left + 2..right - 2).each { |x| put.call(x, tip, OUTLINE) }
    (left + 1..right - 1).each { |x| put.call(x, FINGER_TOP + 2, SKIN_D) } # knuckle crease
    (tip - 5..tip - 3).each { |y| (cx - 1..cx + 1).each { |x| put.call(x, y, NAIL) } } # nail
  end

  # --- the note ---

  # Synthesize a plucked, decaying tone that reads as a piano: a fundamental plus a
  # couple of quieter harmonics, faded out by an exponential envelope.
  def piano_wav(freq: NOTE_HZ, seconds: NOTE_LEN, rate: WAV_RATE)
    count = (seconds * rate).round
    samples = Array.new(count) do |i|
      t = i.to_f / rate
      env = Math.exp(-t * 6.0)
      wave = Math.sin(2 * Math::PI * freq * t) +
             (0.5 * Math.sin(2 * Math::PI * 2 * freq * t)) +
             (0.25 * Math.sin(2 * Math::PI * 3 * freq * t))
      ((wave * env * 60).round).clamp(-127, 127)
    end
    wav_bytes(samples, rate)
  end

  # Wrap 8-bit signed samples in a minimal mono PCM WAV (the RIFF container the
  # loader reads). WAV stores 8-bit samples unsigned, so recenter to 0..255.
  def wav_bytes(samples, rate)
    data = samples.map { |s| s + 128 }.pack("C*")
    fmt = [1, 1, rate, rate, 1, 8].pack("vvVVvv")       # PCM, mono, 8-bit
    fmt_chunk = "fmt ".b + [fmt.bytesize].pack("V") + fmt
    data_chunk = "data".b + [data.bytesize].pack("V") + data
    body = "WAVE".b + fmt_chunk + data_chunk
    "RIFF".b + [body.bytesize].pack("V") + body
  end

  # Encode an RGBA (truecolor + alpha) PNG — same shape as the preview tool's RGB
  # encoder, plus an alpha byte per pixel (color type 6), so ImageMagick reads it
  # back to the exact console colors, cut out where it's transparent.
  def rgba_png(width, height, rgb, alpha)
    raw = (+"").b
    height.times do |y|
      raw << 0.chr # filter type 0 (none)
      width.times do |x|
        r, g, b = Preview.rgb(rgb[(y * width) + x])
        raw << r.chr << g.chr << b.chr << alpha[(y * width) + x].chr
      end
    end
    ihdr = [width, height].pack("N2") << [8, 6, 0, 0, 0].pack("C5") # 8-bit, RGBA, no interlace
    Preview::PNG_SIGNATURE + Preview.chunk("IHDR", ihdr) +
      Preview.chunk("IDAT", Zlib::Deflate.deflate(raw)) + Preview.chunk("IEND", "".b)
  end
end

MakePianoAssets.run if __FILE__ == $PROGRAM_NAME
