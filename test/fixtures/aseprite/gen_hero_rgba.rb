# frozen_string_literal: true

require "test_helper"

# Generate test/fixtures/aseprite/hero_rgba.aseprite: a tiny, hand-built .aseprite binary
# for the parser tests. It covers exactly what the real bird fixture does NOT — 32-bit
# RGBA color and named tags — so the binary loader's RGBA and tags branches are exercised.
#
# It is a 4-frame 8x8 RGBA sprite, one layer, raw (uncompressed) cels: frame 0 red,
# 1 green, 2 blue, 3 white, with two tags — walk = frames 0..1, idle = frames 2..3.
# Built by hand from the published Aseprite file spec. Re-run to regenerate:
#   ruby test/fixtures/aseprite/gen_hero_rgba.rb

W = 8
H = 8

def chunk(type, data) = [6 + data.bytesize].pack("V") + [type].pack("v") + data

# A raw (type 0) cel filling the frame with one RGBA color.
def cel(rgba)
  data = +""
  data << [0].pack("v")               # layer index
  data << [0, 0].pack("s<s<")         # x, y
  data << [255].pack("C")             # opacity
  data << [0].pack("v")               # cel type 0 = raw
  data << [0].pack("s<")              # z-index
  data << ("\x00" * 5)                # reserved
  data << [W, H].pack("vv")           # width, height
  data << (rgba.pack("C4") * (W * H)) # pixels, row-major
  chunk(0x2005, data)
end

def layer(name)
  data = +""
  data << [1, 0, 0].pack("vvv")       # flags (visible), type (normal), child level
  data << [0, 0].pack("vv")           # deprecated default w, h
  data << [0].pack("v")               # blend mode (normal)
  data << [255].pack("C")             # opacity
  data << ("\x00" * 3)                # reserved
  data << [name.bytesize].pack("v") << name
  chunk(0x2004, data)
end

def tags(list) # list of [name, from, to]
  data = +""
  data << [list.length].pack("v") << ("\x00" * 8)
  list.each do |name, from, to|
    data << [from, to].pack("vv")
    data << [0].pack("C")             # loop direction: forward
    data << [0].pack("v")             # repeat: infinite
    data << ("\x00" * 6)              # reserved
    data << ("\x00" * 3)              # deprecated tag color
    data << [0].pack("C")             # extra byte
    data << [name.bytesize].pack("v") << name
  end
  chunk(0x2018, data)
end

def frame(chunks, duration)
  body = chunks.join
  header = +""
  header << [16 + body.bytesize].pack("V") # bytes in this frame
  header << [0xF1FA].pack("v")             # frame magic
  header << [0].pack("v")                  # old chunk count (0 -> use new)
  header << [duration].pack("v")           # duration ms
  header << ("\x00" * 2)                   # reserved
  header << [chunks.length].pack("V")      # new chunk count
  header + body
end

header = ("\x00" * 128).b
header[4, 2]  = [0xA5E0].pack("v") # magic
header[6, 2]  = [4].pack("v")      # frames
header[8, 2]  = [W].pack("v")
header[10, 2] = [H].pack("v")
header[12, 2] = [32].pack("v")     # color depth: RGBA
header[14, 4] = [1].pack("V")      # flags: layer opacity valid

frames = [
  frame([layer("Body"), tags([["walk", 0, 1], ["idle", 2, 3]]), cel([255, 0, 0, 255])], 100),
  frame([cel([0, 255, 0, 255])], 100),
  frame([cel([0, 0, 255, 255])], 100),
  frame([cel([255, 255, 255, 255])], 100),
]

file = (header + frames.join).b
file[0, 4] = [file.bytesize].pack("V") # patch total file size

out = File.join(__dir__, "hero_rgba.aseprite")
File.binwrite(out, file)
puts "Wrote #{out} (#{file.bytesize} bytes)"
