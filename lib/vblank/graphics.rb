# frozen_string_literal: true

# WHAT A PICTURE IS MADE OF: colours, letters, and the images themselves — including the
# readers that take art in the shape somebody else's tool left it, and the writer that puts a
# picture out as a file a person can open.

require_relative "graphics/color"
require_relative "graphics/font" # the model of a bitmap font: glyphs and metrics
require_relative "graphics/fonts" # ...and the built-in ones, registered by name
require_relative "graphics/menu_font" # the letters a window's menu is written in, drawn smooth at a screen's own pixels
require_relative "graphics/image"
require_relative "graphics/aseprite" # art read straight out of the file an artist authored it in
require_relative "graphics/png" # a picture written out as a PNG file
