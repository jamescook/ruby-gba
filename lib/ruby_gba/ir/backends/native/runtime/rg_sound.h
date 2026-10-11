/*
 * THE GAME'S SOUND: the music player, and the log of what was played.
 *
 * Nothing comes out of a speaker yet. What this keeps is what the player DID — a song started,
 * a note sounded on a voice, the music turned down, a beep — as the lines a test reads back
 * (the interpreter's `audio`), handed to the driver as they happen. The player follows the
 * interpreter's own (Backends::Reference::Player) step for step, for a song's parts on the
 * square-wave voices; a part on any other voice is not played yet, and logs nothing.
 */
#ifndef RG_SOUND_H
#define RG_SOUND_H

#include <stdint.h>

/* Every song the game has, as numbers (the lowering writes it; see rg_sound.c for the layout). */
extern const int32_t rg_game_music[];

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

#endif
