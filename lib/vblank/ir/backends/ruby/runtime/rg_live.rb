# The driver a game played live runs on (Ruby::LiveGame): the game is a Ruby object in the same
# process as whoever plays it, and at the end of every frame it hands them the picture and takes
# back the buttons for the next pass, or nothing, which stops the play there.
#
# The game is told one frame went by each pass, whatever a clock says: a pass that runs late makes
# the game run slow.

# What a game stops with when it does something its rules refuse (a push onto a full list); the
# words say what, and LiveGame raises them as IR::ProgramError.
class RgFault < StandardError; end

# Plays the game for +player+ until the game ends, halts, or the player stops it.
def rg_live_main(player)
  @rg_live = player
  catch(:rg_live_stop) { rg_game_main }
end

# The picture is shown as it stands once the next frame has begun, the way the screen shows it
# once the frame boundary has passed, and the buttons the player answers are read for the pass
# that starts.
def rg_driver_wait_vblank
  rg_frame_begins
  buttons = @rg_live.buttons_after(rg_screen_shown)
  throw :rg_live_stop if buttons.nil?

  rg_buttons_read(buttons)
end

def rg_driver_halt = throw(:rg_live_stop)
def rg_driver_fault(message) = raise(RgFault, message)

# A game played live has nowhere to print its variables and lists.
def rg_driver_dump_variable(_name, _value); end
def rg_driver_dump_list(_list); end
