# frozen_string_literal: true

# THE THINGS A GAME HOLDS A HANDLE TO. A verb on Builder hands one of these back — a Value, a
# Sprite, a List, a Pool — and the game then talks to it. So this is the half of the surface a
# game names directly, along with the kinds of thing those handles are made of.

require_relative "dsl/whole" # a plain whole number, and what one can do
require_relative "dsl/fraction" # ...and a number with a fractional part, kept in the low bits
require_relative "dsl/name_set" # the names a variable or a pool field can hold
require_relative "dsl/scale"
require_relative "dsl/changing_word"
require_relative "dsl/value"
require_relative "dsl/condition"
require_relative "dsl/branch"
require_relative "dsl/bounds"
require_relative "dsl/pixel_bounds"
require_relative "dsl/box"
require_relative "dsl/list"
require_relative "dsl/table"
require_relative "dsl/field_ref"
require_relative "dsl/pool"
require_relative "dsl/direction"
require_relative "dsl/grid"
require_relative "dsl/sprite"
require_relative "dsl/recolors" # the other colours a sprite or a pool can be drawn with
require_relative "dsl/hardware_sprite"
require_relative "dsl/timer"
require_relative "dsl/sample"
require_relative "dsl/instrument"
require_relative "dsl/score_list"
require_relative "dsl/song_list"
require_relative "dsl/sound_effect_list"
require_relative "dsl/background"
