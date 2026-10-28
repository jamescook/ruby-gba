# frozen_string_literal: true

# THE SOUND AND MUSIC MODEL BEHIND THE VERBS: what a beep or a note IS, what a tune is made of,
# how a note starts and ends, and how a recording is read. Every backend reads this, which is
# what keeps the console and the headless interpreter agreeing about what a game sounds like.

require_relative "audio/sound" # what a beep, a note and a voice's limits are
require_relative "audio/note_fade" # how a console voice's note fades or swells by itself
require_relative "audio/pitch_slide" # how the first square voice's note slides its pitch by itself
require_relative "audio/vibrato" # how the music player wobbles a note's pitch
require_relative "audio/pan" # which speaker a note plays from
require_relative "audio/duty" # a square note's tone shape, or shapes it steps through
require_relative "audio/music" # before the IR: the backends size their music player by it
require_relative "audio/score" # music handed over as data, rather than written as a block
require_relative "audio/envelope" # how a note starts and how it ends, so an edge is not a click
require_relative "audio/wav" # a recording read out of a file
