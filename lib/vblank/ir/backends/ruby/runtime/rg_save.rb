# THE GAME'S SAVE MEMORY: the bytes a cartridge's chip keeps while the console is off, laid out
# byte for byte the way the chip is (lib/vblank/ir/save_layout.rb says how), with IR::SaveImage's
# rules. Memory with a battery takes any byte anywhere. Flash can only turn bits off in a write,
# and gets them back by wiping a whole block, which then reads as never written. What the
# interpreter refuses — a place past the end of the chip, a write flash cannot take — stops the
# game in the same words, through rg_fault.
#
# A game saves a piece at a time over several frames (the routines for that are the game's own),
# so nothing here knows what a save is: it reads, writes, totals and wipes bytes. The game's four
# numbers in @rg_game_save_memory say how many bytes it has (nought for a game that never reaches
# save memory), how many are wiped together (nought for memory that takes any byte at any time),
# what a byte nothing has written reads, and what a byte of a block still being wiped reads.

# The biggest chip any console's cartridge has (the Advance's largest flash), which is the most a
# game can ask for. A ceiling and not a console's size: the game's size is its table's.
RG_SAVE_MOST_BYTES = 128 * 1024

def rg_save_setup
  @rg_save_bytes = nil   # made a fresh chip's the first time anything asks
  @rg_save_power_left = -1 # steps before the power goes off; -1 while no cut is waiting
  @rg_save_wiping = -1   # where the block still being wiped starts; -1 while none is
end

def rg_save_size = @rg_game_save_memory[0]
def rg_save_wiped_together = @rg_game_save_memory[1]

# A chip nothing has written reads the fresh byte everywhere.
def rg_save_bytes
  return @rg_save_bytes if @rg_save_bytes

  if rg_save_size > RG_SAVE_MOST_BYTES
    rg_fault("this game has #{rg_save_size} bytes of save memory, and the most is #{RG_SAVE_MOST_BYTES}")
  end
  @rg_save_bytes = Array.new(rg_save_size, @rg_game_save_memory[2] & 0xFF)
end

# SaveImage#refuse_outside_memory!
def rg_save_refuse_outside_memory(did, at, count)
  return if at >= 0 && at + count <= rg_save_size

  rg_fault(format("The program %s save memory at 0x%X, and save memory is %dK, which ends at 0x%X. A program must " \
                  "keep to the save memory it has.", did, at & 0xFFFFFFFF, rg_save_size / 1024, rg_save_size))
end

# SaveImage#refuse_while_wiping!
def rg_save_refuse_while_wiping(did, at)
  return if @rg_save_wiping < 0

  rg_fault(format("The program %s flash save memory at 0x%X while the chip was still wiping the block at 0x%X. " \
                  "After the program starts a wipe, it must read the block until the block reads 0xFF.",
                  did, at, @rg_save_wiping))
end

# SaveImage#refuse_write_needing_wipe!: flash can only turn bits off.
def rg_save_refuse_write_needing_wipe(at, byte)
  held = rg_save_bytes[at]
  return if (byte & ~held & 0xFF) == 0

  rg_fault(format("The program wrote 0x%02X to flash save memory at 0x%X, which holds 0x%02X. Flash cannot take " \
                  "that byte there. Before the program writes over a block of flash, it must wipe the block.",
                  byte, at, held))
end

# The power going off stops the game where it stands, the way Reference#on_save_memory does.
def rg_save_refuse_without_power
  rg_halt if @rg_save_power_left == 0
end

def rg_save_spend_power
  rg_save_refuse_without_power
  @rg_save_power_left -= 1 if @rg_save_power_left > 0
end

# One byte as SaveImage#read_bytes reads it: a byte of a block still being wiped reads busy, and
# the caller ends the wipe once its whole read is done. [byte, whether it read busy]
def rg_save_read_byte(at)
  wiping = @rg_save_wiping
  return [rg_save_bytes[at], false] if wiping < 0 || at < wiping || at >= wiping + rg_save_wiped_together

  [@rg_game_save_memory[3] & 0xFF, true]
end

# The +width+ bytes (1, 2 or 4) at +at+, lowest first: a byte and a half as a number from nought
# up, four bytes as the signed number a variable holds (Reference#value_of_save_read).
def rg_save_read(at, width)
  rg_save_refuse_outside_memory("read", at, width)
  value = 0
  busy = false
  width.times do |i|
    byte, busy_here = rg_save_read_byte(at + i)
    busy ||= busy_here
    value |= byte << (8 * i)
  end
  @rg_save_wiping = -1 if busy
  rg_i32(value)
end

# The checksum of the +length+ bytes from +at+ (IR::SaveLayout.checksum).
def rg_save_sum(at, length)
  rg_save_refuse_outside_memory("read", at, length)
  low = 0
  high = 0
  busy = false
  length.times do |i|
    byte, busy_here = rg_save_read_byte(at + i)
    busy ||= busy_here
    low = (low + byte) & 0xFFFF
    high = (high + low) & 0xFFFF
  end
  @rg_save_wiping = -1 if busy
  rg_i32((high << 16) | low)
end

# The low +width+ bytes of +value+ written at +at+, lowest first, a byte at a time, so the power
# going off part way keeps the bytes before it (SaveImage#write).
def rg_save_write(at, value, width)
  rg_save_refuse_outside_memory("wrote to", at, width)
  bytes = rg_save_bytes
  width.times do |i|
    rg_save_spend_power
    byte = (value >> (8 * i)) & 0xFF
    if rg_save_wiped_together > 0
      rg_save_refuse_while_wiping("wrote to", at + i)
      rg_save_refuse_write_needing_wipe(at + i, byte)
    end
    bytes[at + i] = byte
  end
end

# SaveImage#wipe_block, on memory that has blocks to wipe: the block holding +at+ reads as never
# written. With +wait+ nought the wipe is only started, and the block reads busy until the game
# has read it once. A wipe is two steps of a cut: cut half way, the first half of the block reads
# as never written and the rest is as it was.
def rg_save_erase(at, wait)
  block = rg_save_wiped_together
  return if block == 0

  rg_save_refuse_without_power
  rg_save_refuse_outside_memory("wiped", at, 1)
  rg_save_refuse_while_wiping("wiped", at)
  start = (at / block) * block
  fresh = @rg_game_save_memory[2] & 0xFF
  bytes = rg_save_bytes
  if @rg_save_power_left == 1
    bytes.fill(fresh, start, block / 2)
    @rg_save_power_left = 0
    rg_halt
  end
  @rg_save_power_left -= 2 if @rg_save_power_left > 0
  bytes.fill(fresh, start, block)
  @rg_save_wiping = start if wait == 0
end

# TURN THE POWER OFF part way through a save, for a test: once +steps+ more steps are taken the
# next one stops the game as a `halt` does (IR::SaveImage#cut_power_after).
def rg_save_cut_power_after(steps)
  @rg_save_power_left = steps
end
