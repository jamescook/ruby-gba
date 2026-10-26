/*
 * THE GAME'S SAVE MEMORY: the bytes a cartridge's chip keeps while the console is off.
 *
 * On a cartridge those bytes are a chip beside the game. Here they are an array, laid out byte
 * for byte the way the chip is (lib/vblank/ir/save_layout.rb says how), and a driver keeps the
 * array in a file between one run and the next. Because the bytes are the same, that file is a
 * .sav file: a save made on the cartridge or in the interpreter starts the game here, and one
 * made here starts it there.
 *
 * It is a port of the interpreter's IR::SaveImage, with the same rules. Memory with a battery
 * takes any byte anywhere. Flash can only turn bits off in a write, and gets them back by wiping
 * a whole block, which then reads as never written. What the interpreter refuses — a place past
 * the end of the chip, a write flash cannot take — stops the program here in the same words,
 * through rg_fault.
 *
 * A game saves a piece at a time over several frames (the routines for that are the game's own,
 * written out as C with the rest of it), so nothing here knows what a save is: it reads, writes,
 * totals and wipes bytes.
 */
#ifndef RG_SAVE_H
#define RG_SAVE_H

#include <stdint.h>

/* --- what the game provides --- */

/* The save memory the game has, as four numbers the backend writes from IR::SaveLayout and
 * IR::SaveImage, so the rules are said once: how many bytes it is (nought for a game that never
 * reaches save memory), how many bytes are wiped together (nought for memory that takes any byte
 * at any time), what a byte nothing has written reads, and what a byte of a block still being
 * wiped reads. */
extern const int32_t rg_game_save_memory[];

/* --- what the game calls --- */

/* The +width+ bytes (1, 2 or 4) at +at+, lowest first: a byte and a half as a number from
 * nought up, four bytes as the signed number a variable holds (Reference#value_of_save_read). */
int32_t rg_save_read(int32_t at, int32_t width);

/* The low +width+ bytes of +value+ written at +at+, lowest first (Reference#write_save). */
void rg_save_write(int32_t at, int32_t value, int32_t width);

/* The checksum of the +length+ bytes from +at+ (IR::SaveLayout.checksum). */
int32_t rg_save_sum(int32_t at, int32_t length);

/* Wipes the block holding +at+, on memory that has blocks to wipe. With +wait+ nought the wipe is
 * only started: the block reads as busy until the game has read it once, and a write or another
 * wipe before then is refused (Reference#exec_save_erase). */
void rg_save_erase(int32_t at, int32_t wait);

/* --- what a driver calls --- */

/* How many bytes of save memory the game has; nought for a game that keeps none, which has no
 * file to read or write. */
int32_t rg_save_size(void);

/* Every byte of it, rg_save_size() of them, as a .sav file holds them. A driver reads a file
 * into here before the game starts, and writes a file from here. */
uint8_t *rg_save_bytes(void);

/* Whether save memory holds something no file does yet. */
int rg_save_unwritten(void);

/* For a driver that keeps its file up to date while the game plays: asked once at the end of
 * every frame, and says whether the file wants writing now. A game saves over several frames, so
 * the file is written once a frame has gone by with nothing saved — and, for a game that saves
 * on every frame without end, about once a second all the same. */
int rg_save_file_is_due(void);

/* The driver wrote the file: save memory holds nothing a file does not. */
void rg_save_file_written(void);

/* TURN THE POWER OFF part way through a save, for a test: once +steps+ more steps are taken the
 * next one stops the game as a `halt` does, with what was done kept and nothing after. A byte
 * written is one step and a wipe is two (IR::SaveImage#cut_power_after). */
void rg_save_cut_power_after(long steps);

#endif
