# THE SOUND, as far as a silent game goes through it. Every frame moves the mix, the tune and
# every sounding note's shape on (rg_frame_begins), and in a game that has started no sound there
# is nothing to move. Making a sound arrives with the rest of the sound; until then a game that
# makes one is refused before it is played (Ruby::Lowering#runtime_gaps).

def rg_mix_frame; end
def rg_music_frame; end
def rg_mix_step_shapes; end
