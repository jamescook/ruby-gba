# frozen_string_literal: true

require "zlib"

# READING A PNG BY THE FORMAT'S OWN RULES, for a test that has to look inside one without
# trusting the code that wrote it and without starting an image tool (a child process, which a
# test running on its own core cannot reliably start).
#
# A PNG is an 8-byte signature and then a run of chunks, each its length, a four-letter type,
# its data and a check. The picture is in the IDAT chunk, squeezed: a row at a time from the
# top, each a byte saying how the row is stored and then its pixels.
#
#   include PNGReading
#   png_pixel(File.binread(path), 0, 0)   # => [255, 0, 0]
module PNGReading
  # The data of the first chunk of +type+ in +png+.
  def png_chunk(png, type)
    at = 8
    while at < png.bytesize
      length = png.byteslice(at, 4).unpack1("N")
      return png.byteslice(at + 8, length) if png.byteslice(at + 4, 4) == type

      at += 12 + length
    end
    flunk "no #{type} chunk in the PNG"
  end

  # The picture's rows as bytes, each still led by the byte that says how it is stored.
  def png_rows(png) = Zlib::Inflate.inflate(png_chunk(png, "IDAT")).bytes

  # How wide and tall the PNG says it is.
  def png_size(png) = png_chunk(png, "IHDR").unpack("N2")

  # The red, green and blue of the pixel at (+x+, +y+), for a picture stored three bytes a
  # pixel with its rows as they stand — which is how this framework writes one.
  def png_pixel(png, x, y)
    width, = png_size(png)
    png_rows(png)[(y * ((width * 3) + 1)) + 1 + (x * 3), 3]
  end
end
