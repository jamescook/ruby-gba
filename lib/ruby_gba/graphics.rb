# frozen_string_literal: true

# WHAT A PICTURE IS MADE OF: colours, letters, and the images themselves — including the
# readers that take art in the shape somebody else's tool left it.

require_relative "graphics/color"
require_relative "graphics/font" # the model of a bitmap font: glyphs and metrics
require_relative "graphics/fonts" # ...and the built-in ones, registered by name
require_relative "graphics/image"
require_relative "graphics/aseprite" # art read straight out of the file an artist authored it in
