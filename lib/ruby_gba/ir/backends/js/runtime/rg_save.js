/*
 * THE GAME'S SAVE MEMORY: the bytes a cartridge's chip keeps while the console is off, laid out
 * byte for byte the way the chip is, so what a driver keeps of them is a .sav file. A port of the
 * native runtime's rg_save.c (IR::SaveImage, a method at a time); rg_save.h says the rules.
 */

const SAVE_MOST_BYTES = 128 * 1024;
const SAVE_QUIET_FRAMES = 2;
const SAVE_MOST_FRAMES_UNWRITTEN = 60;

const save_bytes = new Uint8Array(SAVE_MOST_BYTES);
let save_awake = 0;
let power_left = -1;
let wiping = -1;
let save_unwritten = 0;
let save_frames_quiet = 0;
let save_frames_unwritten = 0;

function save_size() { return rg_game_save_memory[0]; }
function wiped_together() { return rg_game_save_memory[1]; }
function fresh_byte() { return rg_game_save_memory[2] & 0xFF; }
function busy_byte() { return rg_game_save_memory[3] & 0xFF; }

function save_wake() {
  if (save_awake) return;
  save_awake = 1;
  if (save_size() > SAVE_MOST_BYTES) rg_fault(`this game has ${save_size()} bytes of save memory, and the most is ${SAVE_MOST_BYTES}`);
  save_bytes.fill(fresh_byte(), 0, save_size());
}

function save_changed() {
  save_unwritten = 1;
  save_frames_quiet = 0;
}

function hex(number) { return number.toString(16).toUpperCase(); }
function hex_byte(number) { return hex(number).padStart(2, "0"); }

function refuse_outside_memory(did, at, count) {
  if (at >= 0 && at + count <= save_size()) return;
  rg_fault(`The program ${did} save memory at 0x${hex(at >>> 0)}, and save memory is ${Math.trunc(save_size() / 1024)}K, ` +
    `which ends at 0x${hex(save_size())}. A program must keep to the save memory it has.`);
}

function refuse_while_wiping(did, at) {
  if (wiping < 0) return;
  rg_fault(`The program ${did} flash save memory at 0x${hex(at >>> 0)} while the chip was still wiping the block at ` +
    `0x${hex(wiping)}. After the program starts a wipe, it must read the block until the block reads 0xFF.`);
}

function refuse_write_needing_wipe(at, byte) {
  const held_byte = save_bytes[at];
  if ((byte & ~held_byte & 0xFF) === 0) return;
  rg_fault(`The program wrote 0x${hex_byte(byte)} to flash save memory at 0x${hex(at)}, which holds 0x${hex_byte(held_byte)}. ` +
    "Flash cannot take that byte there. Before the program writes over a block of flash, it must wipe the block.");
}

function refuse_without_power() {
  if (power_left === 0) rg_halt();
}

function spend_power() {
  refuse_without_power();
  if (power_left > 0) power_left--;
}

/* One byte as SaveImage#read_bytes reads it; +busy+ says whether a block being wiped was read. */
function read_save_byte(at, busy) {
  if (wiping < 0 || at < wiping || at >= wiping + wiped_together()) return save_bytes[at];
  busy.read = true;
  return busy_byte();
}

function rg_save_read(at, width) {
  save_wake();
  refuse_outside_memory("read", at, width);
  let value = 0;
  const busy = { read: false };
  for (let i = 0; i < width; i++) value += read_save_byte(at + i, busy) * 2 ** (8 * i);
  if (busy.read) wiping = -1;
  return value | 0;
}

function rg_save_sum(at, length) {
  save_wake();
  refuse_outside_memory("read", at, length);
  let low = 0, high = 0;
  const busy = { read: false };
  for (let i = 0; i < length; i++) {
    low = (low + read_save_byte(at + i, busy)) & 0xFFFF;
    high = (high + low) & 0xFFFF;
  }
  if (busy.read) wiping = -1;
  return ((high << 16) | low) | 0;
}

function rg_save_write(at, value, width) {
  save_wake();
  refuse_outside_memory("wrote to", at, width);
  for (let i = 0; i < width; i++) {
    spend_power();
    const byte = (value >>> (8 * i)) & 0xFF;
    if (wiped_together() > 0) {
      refuse_while_wiping("wrote to", at + i);
      refuse_write_needing_wipe(at + i, byte);
    }
    save_bytes[at + i] = byte;
    save_changed();
  }
}

function rg_save_erase(at, wait) {
  save_wake();
  const save_block = wiped_together();
  if (save_block === 0) return;
  refuse_without_power();
  refuse_outside_memory("wiped", at, 1);
  refuse_while_wiping("wiped", at);
  const start = Math.trunc(at / save_block) * save_block;
  if (power_left === 1) {
    save_bytes.fill(fresh_byte(), start, start + Math.trunc(save_block / 2));
    save_changed();
    power_left = 0;
    rg_halt();
  }
  if (power_left > 0) power_left -= 2;
  save_bytes.fill(fresh_byte(), start, start + save_block);
  save_changed();
  if (!wait) wiping = start;
}

function rg_save_size() { return save_size(); }

/* Every byte of save memory, as a .sav file holds them. */
function rg_save_bytes() {
  save_wake();
  return save_bytes.subarray(0, save_size());
}

function rg_save_unwritten() { return save_unwritten; }

function rg_save_file_is_due() {
  if (!save_unwritten) return 0;
  save_frames_quiet++;
  save_frames_unwritten++;
  if (save_frames_quiet !== SAVE_QUIET_FRAMES && save_frames_unwritten < SAVE_MOST_FRAMES_UNWRITTEN) return 0;
  save_frames_unwritten = 0;
  return 1;
}

function rg_save_file_written() {
  save_unwritten = 0;
  save_frames_unwritten = 0;
}

function rg_save_cut_power_after(steps) { power_left = steps; }
