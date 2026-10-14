/*
 * The game's save memory (rg_save.h): IR::SaveImage, a method at a time.
 */
#include <string.h>
#include "rg_int32.h"
#include "rg_runtime.h"
#include "rg_save.h"

/* The biggest chip a cartridge has, which is the most a game can ask for. */
#define MOST_BYTES (128 * 1024)

/* A frame with nothing saved means the save is over; a game still saving this many frames after
 * its file was last written has the file written anyway. */
#define QUIET_FRAMES 2
#define MOST_FRAMES_UNWRITTEN 60

static uint8_t bytes[MOST_BYTES];
static int awake;            /* the bytes have been made a fresh chip's */
static long power_left = -1; /* steps before the power goes off; -1 while no cut is waiting */
static int32_t wiping = -1;  /* where the block still being wiped starts; -1 while none is */
static int unwritten;        /* something was saved that no file holds yet */
static int frames_quiet;     /* frame ends since the game last saved anything */
static int frames_unwritten; /* frame ends since the first thing no file holds was saved */

static int32_t size(void) { return rg_game_save_memory[0]; }
static int32_t wiped_together(void) { return rg_game_save_memory[1]; }
static uint8_t fresh_byte(void) { return (uint8_t)rg_game_save_memory[2]; }
static uint8_t busy_byte(void) { return (uint8_t)rg_game_save_memory[3]; }

/* A chip nothing has written reads the fresh byte everywhere, where an array starts as noughts. */
static void wake(void) {
  if (awake) return;
  awake = 1;
  if (size() > MOST_BYTES) rg_fault("this game has %d bytes of save memory, and the most is %d", (int)size(), MOST_BYTES);
  memset(bytes, fresh_byte(), (size_t)size());
}

static void changed(void) {
  unwritten = 1;
  frames_quiet = 0;
}

/* SaveImage#refuse_outside_memory!. */
static void refuse_outside_memory(const char *did, int32_t at, int32_t count) {
  if (at >= 0 && (int64_t)at + count <= size()) return;
  rg_fault("The program %s save memory at 0x%X, and save memory is %dK, which ends at 0x%X. A program must keep to "
           "the save memory it has.",
           did, (unsigned)at, (int)(size() / 1024), (unsigned)size());
}

/* SaveImage#refuse_while_wiping!. */
static void refuse_while_wiping(const char *did, int32_t at) {
  if (wiping < 0) return;
  rg_fault("The program %s flash save memory at 0x%X while the chip was still wiping the block at 0x%X. After the "
           "program starts a wipe, it must read the block until the block reads 0xFF.",
           did, (unsigned)at, (unsigned)wiping);
}

/* SaveImage#refuse_write_needing_wipe!: flash can only turn bits off. */
static void refuse_write_needing_wipe(int32_t at, uint8_t byte) {
  uint8_t held = bytes[at];
  if ((byte & (uint8_t)~held) == 0) return;
  rg_fault("The program wrote 0x%02X to flash save memory at 0x%X, which holds 0x%02X. Flash cannot take that byte "
           "there. Before the program writes over a block of flash, it must wipe the block.",
           (unsigned)byte, (unsigned)at, (unsigned)held);
}

/* The power going off stops the game where it stands, the way Reference#on_save_memory does. */
static void refuse_without_power(void) {
  if (power_left == 0) rg_halt();
}

static void spend_power(void) {
  refuse_without_power();
  if (power_left > 0) power_left--;
}

/* One byte as SaveImage#read_bytes reads it: a byte of a block still being wiped reads busy, and
 * +busy+ is set so the caller can end the wipe once its whole read is done. */
static uint8_t read_byte(int32_t at, int *busy) {
  if (wiping < 0 || at < wiping || at >= wiping + wiped_together()) return bytes[at];
  *busy = 1;
  return busy_byte();
}

int32_t rg_save_read(int32_t at, int32_t width) {
  wake();
  refuse_outside_memory("read", at, width);
  uint32_t value = 0;
  int busy = 0;
  for (int32_t i = 0; i < width; i++) value |= (uint32_t)read_byte(at + i, &busy) << (8 * i);
  if (busy) wiping = -1;
  return rg_i32(value);
}

int32_t rg_save_sum(int32_t at, int32_t length) {
  wake();
  refuse_outside_memory("read", at, length);
  uint32_t low = 0, high = 0;
  int busy = 0;
  for (int32_t i = 0; i < length; i++) {
    low = (low + (uint32_t)read_byte(at + i, &busy)) & 0xFFFFu;
    high = (high + low) & 0xFFFFu;
  }
  if (busy) wiping = -1;
  return rg_i32((high << 16) | low);
}

/* A byte at a time, so the power going off part way keeps the bytes before it (SaveImage#write). */
void rg_save_write(int32_t at, int32_t value, int32_t width) {
  wake();
  refuse_outside_memory("wrote to", at, width);
  for (int32_t i = 0; i < width; i++) {
    spend_power();
    uint8_t byte = (uint8_t)(((uint32_t)value >> (8 * i)) & 0xFFu);
    if (wiped_together() > 0) {
      refuse_while_wiping("wrote to", at + i);
      refuse_write_needing_wipe(at + i, byte);
    }
    bytes[at + i] = byte;
    changed();
  }
}

/* SaveImage#wipe_block. A wipe is two steps of a cut: cut half way, the first half of the block
 * reads as never written and the rest is as it was. */
void rg_save_erase(int32_t at, int32_t wait) {
  wake();
  int32_t block = wiped_together();
  if (block == 0) return;
  refuse_without_power();
  refuse_outside_memory("wiped", at, 1);
  refuse_while_wiping("wiped", at);
  int32_t start = (at / block) * block;
  if (power_left == 1) {
    memset(bytes + start, fresh_byte(), (size_t)(block / 2));
    changed();
    power_left = 0;
    rg_halt();
  }
  if (power_left > 0) power_left -= 2;
  memset(bytes + start, fresh_byte(), (size_t)block);
  changed();
  if (!wait) wiping = start;
}

int32_t rg_save_size(void) { return size(); }

uint8_t *rg_save_bytes(void) {
  wake();
  return bytes;
}

int rg_save_unwritten(void) { return unwritten; }

int rg_save_file_is_due(void) {
  if (!unwritten) return 0;
  frames_quiet++;
  frames_unwritten++;
  return frames_quiet >= QUIET_FRAMES || frames_unwritten >= MOST_FRAMES_UNWRITTEN;
}

void rg_save_file_written(void) {
  unwritten = 0;
  frames_unwritten = 0;
}

void rg_save_cut_power_after(long steps) { power_left = steps; }
