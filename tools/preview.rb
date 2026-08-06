# frozen_string_literal: true

require "zlib"

require_relative "../lib/ruby_gba"

# Preview — turn a run of a program into a picture you can watch.
#
# The point of this framework is the visible result, but a passing test only proves
# a feature is correct, it doesn't let you SEE it — and motion (scrolling, parallax,
# animation) can't be shown in a single screenshot at all. This runs a program on the
# reference interpreter, captures the screen at each frame, and writes a self-contained
# HTML page that plays those frames back like a little animation. No emulator, no
# hardware, no external files — open the page and watch the effect.
#
#   frames = Preview.capture(MyGame.program, frames: 48) { |f| [:right] } # hold right
#   Preview.write("out.html", frames, title: "My Game", scale: 3)
#
# It leans on the interpreter's frame-by-frame hook (Backends::Reference#each_vblank) to
# grab each settled frame, then encodes each as a PNG (via Ruby's built-in zlib) so the
# page stays small and needs nothing but a browser.
module Preview
  Reference = RubyGBA::IR::Backends::Reference

  # Run +program+ and collect the first +frames+ frames as it plays. An optional block
  # supplies the buttons held on each frame (the same shape as
  # Backends::Reference#input_each_frame), so you can drive the run — hold right to scroll,
  # tap a button, whatever the effect needs. Returns an array of frame hashes
  # ({ width:, height:, pixels: } — pixels are 15-bit colors, row-major).
  def self.capture(program, frames:, max_steps: 200_000, &input)
    interp = Reference.new
    interp.input_each_frame(&input) if input
    shots = []
    interp.each_vblank do |frame|
      shots << { width: interp.screen.width, height: interp.screen.height, pixels: interp.screen.to_a }
      # Stop the run the moment we've collected enough frames — no point running the
      # game's endless loop out to the step budget once the preview is captured.
      throw :halt if shots.size >= frames
    end
    interp.run(program, max_steps: max_steps)
    shots
  end

  # Write a self-contained HTML page that plays the captured frames in a loop. +scale+
  # blows the tiny console screen up to a comfortable size (crisp, not blurred); +fps+
  # sets the playback speed.
  def self.write(path, frames, title:, scale: 3, fps: 30)
    File.write(path, html(frames, title: title, scale: scale, fps: fps))
    path
  end

  # The captured frames as HTML: the PNGs inlined as data URIs and a few lines of script
  # that flip through them on a canvas. Returns a full standalone document by default,
  # or (fragment: true) just the body content — for embedding, e.g. a hosted artifact
  # that supplies its own <head>/<body>.
  def self.html(frames, title:, scale: 3, fps: 30, fragment: false)
    raise ArgumentError, "no frames captured — did the program reach a vblank?" if frames.empty?

    w = frames.first[:width]
    h = frames.first[:height]
    uris = frames.map { |frame| png_data_uri(frame) }
    body = <<~BODY
      <style>
        :root { color-scheme: light dark; }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; gap: 1rem;
               font: 15px system-ui, sans-serif; background: #0b0b0e; color: #e9e9ee; }
        h1 { font-size: 1rem; font-weight: 600; opacity: .85; margin: 1rem 0 0; text-align: center; }
        canvas { width: #{w * scale}px; height: #{h * scale}px; image-rendering: pixelated;
                 border-radius: 6px; box-shadow: 0 8px 30px rgba(0,0,0,.5); background: #000; max-width: 96vw; }
        .bar { display: flex; gap: .75rem; align-items: center; opacity: .8; }
        button { font: inherit; color: inherit; background: #23232b; border: 1px solid #3a3a44;
                 border-radius: 5px; padding: .3rem .7rem; cursor: pointer; }
        input[type=range] { width: 220px; max-width: 50vw; }
      </style>
      <h1>#{escape(title)} — #{frames.size} frames</h1>
      <canvas id="s" width="#{w}" height="#{h}"></canvas>
      <div class="bar">
        <button id="play">Pause</button>
        <input id="scrub" type="range" min="0" max="#{frames.size - 1}" value="0">
        <span id="lbl">1 / #{frames.size}</span>
      </div>
      <script>
        const uris = #{uris_json(uris)};
        const imgs = [], cv = document.getElementById('s'), cx = cv.getContext('2d');
        let loaded = 0, cur = 0, playing = true;
        uris.forEach((u, i) => { const im = new Image(); im.onload = () => { if (++loaded === uris.length) draw(0); }; im.src = u; imgs[i] = im; });
        const scrub = document.getElementById('scrub'), lbl = document.getElementById('lbl'), playBtn = document.getElementById('play');
        function draw(i) { cur = i; cx.drawImage(imgs[i], 0, 0); scrub.value = i; lbl.textContent = (i + 1) + ' / ' + imgs.length; }
        let last = 0;
        function tick(t) { if (playing && loaded === uris.length && t - last > #{(1000.0 / fps).round}) { last = t; draw((cur + 1) % imgs.length); } requestAnimationFrame(tick); }
        requestAnimationFrame(tick);
        scrub.oninput = () => { playing = false; playBtn.textContent = 'Play'; draw(+scrub.value); };
        playBtn.onclick = () => { playing = !playing; playBtn.textContent = playing ? 'Pause' : 'Play'; };
      </script>
    BODY
    return body if fragment

    "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>#{escape(title)}</title></head>\n<body>\n#{body}</body></html>\n"
  end

  # --- encoding a frame to a PNG data URI (truecolor, via zlib) ---

  # A frame ({ width:, height:, pixels: [15-bit colors] }) as a "data:image/png..." URI.
  # pack("m0") is base64 with no line breaks — the same bytes the base64 library would
  # give, without depending on it (Ruby 4 dropped it from the default gems).
  def self.png_data_uri(frame)
    "data:image/png;base64,#{[png(frame)].pack('m0')}"
  end

  PNG_SIGNATURE = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*")

  # Encode a frame as a PNG image (8-bit truecolor RGB). Each 15-bit BGR555 color is
  # expanded to 8-bit-per-channel RGB; the scanlines (each prefixed with a "no filter"
  # byte) are deflated into the single image-data chunk.
  def self.png(frame)
    w = frame[:width]
    h = frame[:height]
    pixels = frame[:pixels]
    raw = (+"").b
    h.times do |y|
      raw << 0.chr # filter type 0 (none) for this scanline
      w.times do |x|
        r, g, b = rgb(pixels[(y * w) + x] || 0)
        raw << r.chr << g.chr << b.chr
      end
    end

    ihdr = [w, h].pack("N2") << [8, 2, 0, 0, 0].pack("C5") # 8-bit depth, truecolor, no interlace
    PNG_SIGNATURE + chunk("IHDR", ihdr) + chunk("IDAT", Zlib::Deflate.deflate(raw)) + chunk("IEND", "".b)
  end

  # One PNG chunk: length, type, data, and a CRC over the type and data.
  def self.chunk(type, data)
    body = type.b + data
    [data.bytesize].pack("N") + body + [Zlib.crc32(body)].pack("N")
  end

  # Expand a 15-bit BGR555 color into 8-bit-per-channel RGB (each 5-bit channel scaled
  # up so full-scale stays full-scale).
  def self.rgb(color)
    r5 =  color        & 0x1F
    g5 = (color >>  5) & 0x1F
    b5 = (color >> 10) & 0x1F
    [(r5 << 3) | (r5 >> 2), (g5 << 3) | (g5 >> 2), (b5 << 3) | (b5 >> 2)]
  end

  def self.uris_json(uris)
    "[#{uris.map { |u| "\"#{u}\"" }.join(',')}]"
  end

  def self.escape(text)
    text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  # --- command line: `ruby tools/preview.rb EXAMPLE [options]` ---

  EXAMPLES_DIR = File.expand_path("../examples", __dir__)

  # Load examples/NAME.rb and return its module (Parallax, SnakeBuffered, ...). The
  # module name is the file name camel-cased; it must expose `.program`.
  def self.load_example(name)
    base = File.basename(name, ".rb")
    path = File.join(EXAMPLES_DIR, "#{base}.rb")
    raise ArgumentError, "no example at #{path}" unless File.exist?(path)

    require path
    mod_name = base.split(/[_-]/).map(&:capitalize).join
    mod = Object.const_get(mod_name)
    unless mod.respond_to?(:program)
      raise ArgumentError, "#{mod_name} has no .program — a preview needs the example's IR program"
    end
    mod
  end

  # Capture an example and write its preview, from parsed command-line options. Returns
  # the output path.
  def self.run_cli(name, frames:, keys:, max_steps:, scale:, fps:, out:)
    mod = load_example(name)
    out ||= "#{File.basename(name, '.rb')}.html"
    held = keys.empty? ? nil : proc { keys }
    shots = capture(mod.program, frames: frames, max_steps: max_steps, &held)
    write(out, shots, title: "#{mod} — ruby-gba preview", scale: scale, fps: fps)
    out
  end
end

if __FILE__ == $PROGRAM_NAME
  require "optparse"

  opts = { frames: 60, keys: [], max_steps: 200_000, scale: 3, fps: 24, out: nil }
  parser = OptionParser.new do |o|
    o.banner = "Usage: ruby tools/preview.rb EXAMPLE [options]\n" \
               "  Play a run of examples/EXAMPLE.rb as a self-contained HTML page you can watch.\n\n" \
               "  e.g.  ruby tools/preview.rb parallax --keys right --frames 64\n"
    o.on("--frames N", Integer, "frames to capture (default 60)") { |v| opts[:frames] = v }
    o.on("--keys x,y", Array, "buttons held for the whole run, e.g. right  or  right,a") { |v| opts[:keys] = v.map(&:to_sym) }
    o.on("--max-steps N", Integer, "interpreter step budget (default 200000)") { |v| opts[:max_steps] = v }
    o.on("--scale N", Integer, "pixel zoom (default 3)") { |v| opts[:scale] = v }
    o.on("--fps N", Integer, "playback speed (default 24)") { |v| opts[:fps] = v }
    o.on("-o", "--out PATH", "output path (default EXAMPLE.html here)") { |v| opts[:out] = v }
    o.on("-h", "--help") { puts o; exit }
  end
  parser.parse!
  example = ARGV.shift or abort(parser.to_s)

  path = Preview.run_cli(example, **opts)
  puts "wrote #{path} — open it in a browser to watch (#{opts[:frames]} frames)"
end
