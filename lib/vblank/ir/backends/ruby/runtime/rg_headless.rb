# The driver with no window: what the tests run a game against.
#
#   ruby game.rb FRAMES [options] < buttons
#
# plays FRAMES frames and stops at the start of the next one, the way the interpreter's
# run(program, frames: FRAMES) does. Each line of standard input is the buttons held during one
# frame, as a number with a bit per button (bit 0 is a, in the order rg_runtime.rb lists them); a
# missing line holds nothing.
#
# At every frame boundary it prints "frame N", every variable as "var name value", every list as
# "list name" and its items (see rg_driver_dump_list), every sprite the game last drew as "sprite"
# and four numbers, what the mixer made and is playing (see rg_headless_print_mix), and where the
# window sits over the picture as "camera X Y", then "buttons?",
# and only then reads that frame's line. So whoever is feeding it can answer from what the game
# has done so far — a test that presses a button only once the game has reached somewhere — or
# write every line up front and ignore the question. That is the order the interpreter asks its
# own input script in, after the frame before has finished.
#
# At the end it prints "end", every variable and every sprite the same way, and the picture as
# shown: "picture" and every pixel, row by row, as four hex digits — and then the same page as it
# is stored ("stored"), with no window moved over it and no fade mixed in, and how many pages the
# screen has ("pages", 2 for a tear-free one). A frame's moment carries only a check number of its
# picture ("picture-crc"), or with --every-picture the whole picture. Each line of the sound log is
# printed as "sound" and the line, as it happens, among the frames.
#
# The options:
#
#   --every-picture             the whole picture at every frame, not only a check number
#   --picture-out FILE          the picture of every moment written to FILE, over the one before:
#                               every pixel as shown and then as stored, row by row, each two
#                               bytes with the low byte first, there before "buttons?" is asked
#   --held-from-power-on MASK   the buttons in MASK are down before the game's first statement
#   --clock-at SECONDS TICKS SET  the cartridge has a clock, reading SECONDS from the start of
#                               1970 and TICKS cycles of the console's clock more at power-on,
#                               set when SET is 1; without it the cartridge has no clock
#   --save FILE                 the game starts with the save memory FILE holds (the bytes of a
#                               .sav file, as many as the game has), and when the run ends its
#                               save memory is written back to FILE, whole; no file there yet is a
#                               new cartridge, and a game with no save memory leaves FILE alone
#   --save-cut-after N          the power goes off N steps into the game's saving, which ends the
#                               run there, as it does in the interpreter
#   --sound-out FILE            the sound of every frame played written to FILE as it is made: one
#                               speaker's worth, RG_SOUND_RATE numbers a second, each two bytes
#                               with the low byte first
#   --sound-voice N             only voice N is in it (1 and 2 the square voices, 3 the wave voice,
#                               4 the noise voice), which is how a test hears one voice at a time

require "zlib"

RG_GAME_WENT_WRONG = 3 # how a run ends when the game did something the interpreter refuses

def rg_headless_main(argv)
  if argv.empty?
    $stderr.puts "give the number of frames to play, and the buttons for each frame on standard input"
    exit 2
  end
  @rg_frames_to_play = argv[0].to_i
  @rg_frame = 0 # frames started so far
  @rg_every_picture = false
  @rg_picture_out = nil
  @rg_save_path = nil # the file save memory is read from and written back to, if any
  @rg_sound_out = nil # where each frame's sound is written, if anywhere
  @rg_slices_printed = 0
  i = 1
  while i < argv.length
    case argv[i]
    when "--every-picture" then @rg_every_picture = true
    when "--picture-out"
      i += 1
      @rg_picture_out = File.open(argv[i], "wb")
    when "--held-from-power-on"
      i += 1
      rg_buttons_held_from_power_on(argv[i].to_i)
    when "--clock-at"
      rg_clock_starts_at(argv[i + 1].to_i, argv[i + 2].to_i, argv[i + 3].to_i)
      i += 3
    when "--save"
      i += 1
      if rg_save_size > 0 # a game with no save memory keeps nothing there
        @rg_save_path = argv[i]
        rg_headless_read_save_file
      end
    when "--save-cut-after"
      i += 1
      rg_save_cut_power_after(argv[i].to_i)
    when "--sound-out"
      i += 1
      @rg_sound_out = File.open(argv[i], "wb")
    when "--sound-voice"
      i += 1
      rg_sound_hear_only(argv[i].to_i)
    end
    i += 1
  end
  rg_game_main
  rg_headless_finish
end

def rg_driver_wait_vblank
  rg_headless_write_frame_sound
  rg_headless_finish if @rg_frame >= @rg_frames_to_play
  rg_frame_begins
  @rg_frame += 1
  rg_headless_print_moment("frame #{@rg_frame}", @rg_every_picture)
  $stdout.write("buttons?\n")
  $stdout.flush
  line = $stdin.gets
  rg_buttons_read(line ? line.to_i : 0)
end

def rg_driver_halt = rg_headless_finish

# Said on the error stream, and the run ends badly, which is how a test sees it.
def rg_driver_fault(message)
  $stdout.flush
  $stderr.puts message
  exit RG_GAME_WENT_WRONG
end

# "var" first, so no name a game gives a variable can be read as one of the other lines.
def rg_driver_dump_variable(name, value)
  $stdout.write("var #{name} #{value}\n")
end

# "list", the game's name for it, a tab, and its items oldest first — the order the game reads
# them in, which in a list the game shifts is not the order they sit in memory. The tab ends the
# name, since a pool's field may be called anything, spaces and all.
def rg_driver_dump_list(list)
  items = Array.new(list.length) { |i| list.items[rg_list_slot(list, i)] }
  $stdout.write("list #{list.name}\t#{items.join(' ')}\n")
end

# "sound" first, for the same reason a variable's line starts with "var"; printed as it happens,
# among the frames, so a test reading the log mid-run sees it up to the frame it is on.
def rg_driver_sound_logged(line)
  $stdout.write("sound #{line}\n")
end

# The sound of the frame that has just been played, written down, two bytes a sample with the low
# byte first: a sample of the left speaker, then the right's at the same moment, and so on. Worked
# out whether or not anyone is listening, so the voices are where they would be.
def rg_headless_write_frame_sound
  left, right = rg_sound_render_frame
  @rg_sound_out&.write(left.zip(right).flatten.pack("s<*"))
end

# For a game that mixes recordings: the slice made since the last moment ("mix" and its samples),
# each sounding voice's recording, loudness out of 512, how far its shape has climbed or fallen,
# and whose it is — 0 the game's, 1 the song's, 2 a sound effect's, then the effect's number and
# the part's lane ("mixing", six numbers a voice), the most voices that ever sounded at once
# ("mix_peak"), and how many plays found every voice busy with the most the music held at one of
# those moments ("mix_drops").
def rg_headless_print_mix
  return if rg_mixes == 0

  if rg_mix_slices_made > @rg_slices_printed
    $stdout.write("mix#{rg_mix_newest_slice.map { |sample| " #{sample}" }.join}\n")
    @rg_slices_printed = rg_mix_slices_made
  end
  sounding = Array.new(rg_mix_voice_count) { |voice| rg_mix_voice_sounding(voice) }.compact
  dropped, music_held = rg_mix_drops
  $stdout.write("mixing#{sounding.flatten.map { |number| " #{number}" }.join}\n" \
                "mix_peak #{rg_mix_peak}\nmix_drops #{dropped} #{music_held}\n")
end

def rg_headless_print_moment(heading, with_picture)
  $stdout.write("#{heading}\n")
  rg_game_dump_state
  # Every sprite the game last said is on screen, back to front, a line each: whose it is and
  # which picture it shows, both as the number of a name the game was built with, and where it is.
  rg_screen_drawn_count.times do |place|
    name, picture, x, y = rg_screen_drawn_sprite(place)
    $stdout.write("sprite #{name} #{picture} #{x} #{y}\n")
  end
  rg_headless_print_mix
  $stdout.write("camera #{rg_screen_camera_x} #{rg_screen_camera_y}\n")
  $stdout.write("motor #{rg_motor_on}\n")
  shown = rg_screen_shown
  if with_picture
    rg_headless_print_pixels("picture", shown)
  else
    # The CRC-32 of the pixels, each as two bytes with the low byte first: the number the C
    # driver prints for the same picture, and the one Ruby's Zlib.crc32 gives.
    $stdout.write(format("picture-crc %08x\n", Zlib.crc32(shown.pack("v*"))))
  end
  rg_headless_write_picture(shown) if @rg_picture_out
end

# A whole picture as one line: +word+ and then every pixel, row by row, as four hex digits.
def rg_headless_print_pixels(word, pixels)
  $stdout.write("#{word} #{pixels.map { |pixel| format('%04x', pixel) }.join}\n")
end

def rg_headless_write_picture(shown)
  @rg_picture_out.rewind
  @rg_picture_out.write(shown.pack("v*"), rg_screen_stored.pack("v*"))
  @rg_picture_out.flush
end

def rg_headless_finish
  rg_headless_print_moment("end", !@rg_picture_out)
  rg_headless_print_pixels("stored", rg_screen_stored) unless @rg_picture_out
  $stdout.write("pages #{rg_screen_two_pages != 0 ? 2 : 1}\n")
  $stdout.flush
  @rg_picture_out&.close
  @rg_sound_out&.close
  rg_headless_write_save_file if @rg_save_path
  exit 0
end

# Save memory as its file holds it. No file, or one that cannot be read, is a new cartridge; a file
# of any other size than the game's save memory is somebody else's save, and the run stops before
# the game starts.
def rg_headless_read_save_file
  kept = begin
    File.binread(@rg_save_path)
  rescue SystemCallError
    return
  end
  if kept.bytesize != rg_save_size
    $stderr.puts "the file at #{@rg_save_path} is not this game's save memory, which is #{rg_save_size} bytes"
    exit 2
  end
  rg_save_bytes.replace(kept.bytes)
end

# Save memory written to its file: to a new file beside it, which then takes its place, so a run
# stopped part way through leaves the old file whole.
def rg_headless_write_save_file
  writing = "#{@rg_save_path}.writing"
  File.binwrite(writing, rg_save_bytes.pack("C*"))
  File.rename(writing, @rg_save_path)
rescue SystemCallError
  $stderr.puts "the save memory could not be written to #{@rg_save_path}"
  exit 1
end
