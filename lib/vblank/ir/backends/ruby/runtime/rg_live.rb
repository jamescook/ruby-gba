# The driver a game played live runs on (Ruby::LiveGame): the game is a Ruby object in the same
# process as whoever plays it, and at the end of every frame it hands them the picture and the
# frame's sound and takes back the buttons for the next pass, or nothing, which stops the play
# there.
#
# The game is told one frame went by each pass, whatever a clock says: a pass that runs late makes
# the game run slow.

# What a game stops with when it does something its rules refuse (a push onto a full list); the
# words say what, and LiveGame raises them as IR::ProgramError.
class RgFault < StandardError; end

# Plays the game for +player+ until the game ends, halts, or the player stops it. A game that
# stopped itself gives back the picture it stopped on, as the screen shows it, for the player to
# keep up; one the player stopped gives back nil.
def rg_live_main(player)
  @rg_live = player
  stopped_by = catch(:rg_live_stop) do
    rg_game_main
    nil
  end
  stopped_by == :player ? nil : rg_screen_shown
end

# The sound of the frame the pass played is made first, before the next frame moves the music on.
# The picture is shown as it stands once the next frame has begun, the way the screen shows it
# once the frame boundary has passed, and the buttons the player answers are read for the pass
# that starts.
def rg_driver_wait_vblank
  left, right = rg_sound_render_frame
  rg_frame_begins
  buttons = @rg_live.buttons_after(rg_screen_shown, left, right)
  throw :rg_live_stop, :player if buttons.nil?

  rg_buttons_read(buttons)
end

def rg_driver_halt = throw(:rg_live_stop)
def rg_driver_fault(message) = raise(RgFault, message)

# A game played live has nowhere to print its variables, lists and sound log.
def rg_driver_dump_variable(_name, _value); end
def rg_driver_dump_list(_list); end
def rg_driver_sound_logged(_line); end
