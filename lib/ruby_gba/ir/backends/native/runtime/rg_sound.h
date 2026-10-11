/*
 * THE GAME'S SOUND: the music player, the two square-wave voices it and the beeps play on, and
 * the log of what was played.
 *
 * The player follows the interpreter's own (Backends::Reference::Player) step for step, for a
 * song's parts on the square-wave voices, and says what it did — a song started, a note sounded
 * on a voice, the music turned down, a beep — as the lines a test reads back (the interpreter's
 * `audio`), handed to the driver as they happen.
 *
 * The voices are the console's, made here because a desktop has no sound chip to ask: each
 * plays a wave that is high for part of its length and low for the rest, at the pitch and
 * loudness the player or a beep last gave it. A driver asks for a frame's worth of that sound at
 * every frame and does what it likes with it — a window plays it, a test writes it down.
 */
#ifndef RG_SOUND_H
#define RG_SOUND_H

#include <stdint.h>

/* The sound comes out as whole numbers from -32768 to 32767, one speaker's worth, this many a
 * second. A frame of the console is a little over eight hundred of them. */
#define RG_SOUND_RATE 48000
#define RG_SOUND_FRAME_MOST 1024

/* Every song the game has, and every beep, as numbers (the lowering writes them; see rg_sound.c
 * for the layouts). */
extern const int32_t rg_game_music[];
extern const int32_t rg_game_beeps[];

/* `enable_sound`, and beep number +which+ of the game's beeps (numbered by the lowering and by
 * the test reading the log the same way, so the number is all that needs saying). */
void rg_sound_enabled(void);
void rg_sound_beep(int32_t which);

/* Song number +song+ is the tune playing now, taken up at the next frame; naming the tune already
 * playing changes nothing. */
void rg_music_request(int32_t song);
/* No tune, and counted: a stop and a play in one frame still start the tune again. */
void rg_music_stop(void);
/* The variable the game keeps its music volume in (0 to 16), for a game that says one at all. */
void rg_music_follow_level(const int32_t *level);

/* One frame of the player, at the start of each frame (rg_frame_begins). */
void rg_music_frame(void);

/* The sound of the frame that has just been played, written to +samples+ (room for
 * RG_SOUND_FRAME_MOST); gives back how many. Asked once a frame, at the frame's end and before
 * rg_frame_begins starts the next: a beep the game made during the frame is then in that frame's
 * sound, where the console plays it, and not a frame behind. */
int32_t rg_sound_render_frame(int16_t *samples);

/* Only square voice +voice+ (1 or 2) is heard from now on, or every voice for 0: how a test
 * listens to one voice at a time. */
void rg_sound_hear_only(int32_t voice);

#endif
