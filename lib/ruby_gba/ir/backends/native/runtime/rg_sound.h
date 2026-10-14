/*
 * THE GAME'S SOUND: the music player, the console's four voices it and the game's own sounds
 * play on, and the log of what was played.
 *
 * The player follows the interpreter's own (Backends::Reference::Player) step for step, for a
 * song's parts on the console's own voices, and says what it did — a song started, a note
 * sounded on a voice, the music turned down, a beep — as the lines a test reads back (the
 * interpreter's `audio`), handed to the driver as they happen.
 *
 * The voices are the console's, made here because a desktop has no sound chip to ask. Two play
 * a square wave, high for part of its length and low for the rest. One loops a waveform of 32
 * steps, which is rounder than a square wave and reaches an octave lower. One makes a hiss, for
 * drums and explosions. Each plays at the pitch and loudness the player or the game last gave
 * it. A driver asks for a frame's worth of that sound at every frame and does what it likes with
 * it — a window plays it, a test writes it down.
 */
#ifndef RG_SOUND_H
#define RG_SOUND_H

#include <stdint.h>

/* The sound comes out as whole numbers from -32768 to 32767, one speaker's worth, this many a
 * second. A frame of the console is a little over eight hundred of them. */
#define RG_SOUND_RATE 48000
#define RG_SOUND_FRAME_MOST 1024

/* The voices by the console's own count of them, which is what the log names a voice by and what
 * a test asks to hear one by. */
#define RG_SQUARE_VOICES 2
#define RG_WAVE_VOICE 3
#define RG_NOISE_VOICE 4

/* The rules the voices keep, every song the game has, and every sound it makes itself, as
 * numbers (the lowering writes them; see rg_sound.c for the layouts). */
extern const int32_t rg_game_sound_rules[];
extern const int32_t rg_game_waveforms[];
extern const int32_t rg_game_music[];
extern const int32_t rg_game_beeps[];
extern const int32_t rg_game_waves[];
extern const int32_t rg_game_hits[];

/* `enable_sound`, and beep number +which+ of the game's beeps (numbered by the lowering and by
 * the test reading the log the same way, so the number is all that needs saying). */
void rg_sound_enabled(void);
void rg_sound_beep(int32_t which);

/* `wave`: the wave voice plays number +which+ of the things the game tells it to, until it is
 * told something else. And `stop_wave`, which switches the voice off. */
void rg_sound_wave(int32_t which);
void rg_sound_stop_wave(void);

/* `noise`: hit number +which+ of the game's hits, on the noise voice. */
void rg_sound_noise(int32_t which);

/* Song number +song+ is the tune playing now, taken up at the next frame; naming the tune already
 * playing changes nothing. */
void rg_music_request(int32_t song);
/* ...or the song number +which+ of a list (`songs`) names, from the +count+ song numbers the list
 * holds. A number naming no song in the list leaves the music as it is. */
void rg_music_request_one_of(const int32_t *songs, int32_t count, int32_t which);
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

/* One line of the sound log, said the way printf says it, handed to the driver as it happens. */
void rg_sound_log(const char *format, ...);

/* Only voice +voice+ is heard from now on — 1 or 2 for a square voice, RG_WAVE_VOICE,
 * RG_NOISE_VOICE — or every voice for 0: how a test listens to one voice at a time. */
void rg_sound_hear_only(int32_t voice);

#endif
