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
#   - piano_hand_rest.png  — the hand hovering, no finger down
#   - piano_hand_f0..f3.png — the same hand with one finger pressed (f0 = the
#     leftmost/pinky over the lowest key … f3 = the rightmost over the highest)
#   - piano.wav            — a single ~0.6s piano-ish note at C4, which the
#     `instrument` verb pitches across the keys.
module MakePianoAssets
  Color = RubyGBA::Color

  ASSETS = File.expand_path("../examples/assets", __dir__)

  # --- The hand's size and where its four fingers sit ---
  # A 64x32 sprite (a valid hardware-sprite size). The four fingers hang down from
  # the palm, evenly spaced so each one lines up with a 16px-wide key below it.
  HAND_W = 64
  HAND_H = 32
  FINGERS = 4
  FINGER_CX = Array.new(FINGERS) { |k| 8 + (k * 16) } # 8, 24, 40, 56 — a finger per key
  PALM_BOTTOM = 13     # the palm fills the top rows down to here
  FINGER_TOP = 12      # fingers start just inside the palm
  REST_TIP = 23        # a resting fingertip reaches this row
  PRESS_TIP = 30       # a pressed finger extends this far down (onto the key)

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
    File.binwrite(File.join(ASSETS, "piano_hand_rest.png"), hand_png(nil))
    FINGERS.times { |k| File.binwrite(File.join(ASSETS, "piano_hand_f#{k}.png"), hand_png(k)) }
    File.binwrite(File.join(ASSETS, "piano.wav"), piano_wav)
    puts "wrote #{ASSETS}/piano_hand_rest.png, piano_hand_f0..f#{FINGERS - 1}.png and piano.wav"
  end

  # --- the hand poses ---

  # Draw the left hand. +pressed+ is nil for the resting pose, or a finger index
  # 0..3 for the pose where that one finger is pushed down onto its key. Everything
  # is drawn onto a transparent background so the imported sprite is a clean cut-out.
  def hand_png(pressed)
    rgb = Array.new(HAND_W * HAND_H, SKIN)
    alpha = Array.new(HAND_W * HAND_H, 0) # see-through until a pixel is drawn
    put = lambda do |x, y, color|
      next unless x.between?(0, HAND_W - 1) && y.between?(0, HAND_H - 1)

      rgb[(y * HAND_W) + x] = color
      alpha[(y * HAND_W) + x] = 255
    end

    draw_palm(put)
    FINGERS.times do |k|
      tip = pressed == k ? PRESS_TIP : REST_TIP
      draw_finger(put, FINGER_CX[k], tip)
    end
    draw_thumb(put) # a small thumb nub on the right, so it reads as a left hand

    rgba_png(HAND_W, HAND_H, rgb, alpha)
  end

  # The back of the hand: a filled, outlined block across the top of the sprite.
  def draw_palm(put)
    (2..PALM_BOTTOM).each do |y|
      (3..60).each { |x| put.call(x, y, SKIN) }
    end
    outline_box(put, 2, 1, 61, PALM_BOTTOM) # a dark border around the palm
  end

  # One finger: a rounded column of skin from the palm down to +tip+, outlined on
  # both sides with a pale nail at the very end. +cx+ is its center column.
  def draw_finger(put, cx, tip)
    (FINGER_TOP..tip).each do |y|
      (cx - 4..cx + 3).each { |x| put.call(x, y, SKIN) }
      put.call(cx - 4, y, SKIN_D) # a little shading down the seams
      put.call(cx + 3, y, SKIN_D)
    end
    outline_box(put, cx - 5, FINGER_TOP, cx + 4, tip)
    (tip - 2..tip - 1).each { |y| (cx - 3..cx + 2).each { |x| put.call(x, y, NAIL) } }
  end

  # A short thumb sticking off the right side of the palm.
  def draw_thumb(put)
    (7..15).each do |y|
      (58..62).each { |x| put.call(x, y, SKIN) }
    end
    outline_box(put, 57, 6, 63, 16)
  end

  # Draw a rectangle's border (used as the cartoon outline around a part).
  def outline_box(put, x0, y0, x1, y1)
    (x0..x1).each { |x| put.call(x, y0, OUTLINE); put.call(x, y1, OUTLINE) }
    (y0..y1).each { |y| put.call(x0, y, OUTLINE); put.call(x1, y, OUTLINE) }
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
