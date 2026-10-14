/*
 * THE MIXER: several recordings sounding at once, added together a frame at a time into one
 * stream of sound, the way the console's own software mixer does it (Backends::Reference::Mixer
 * does the same arithmetic in Ruby, and is held to the console byte for byte; this is held to
 * it).
 *
 * The console has no voice that plays a recording by itself, only one that plays a stream it is
 * handed. So the game's CPU adds every sounding recording together into that stream, a frame's
 * slice of it at a time, and that is what this does. Each recording plays on a VOICE of the
 * mixer — there are a fixed number — which it gives back when it ends.
 */
#ifndef RG_MIX_H
#define RG_MIX_H

#include <stdint.h>

/* What the lowering writes (see rg_mix.c for the layouts): how the mix runs, and every recording
 * the game declares, with its bytes. */
extern const int32_t rg_game_mix[];
extern const int32_t rg_game_recordings[];

/* The game's own `play` of recording number +recording+: read +step+ 65536ths of a sample for
 * each sample of the mix (its pitch), at +loudness+ out of 64, going +back+ that many samples at
 * its end (0 to stop there). Every number was worked out when the
 * game was built. */
void rg_mix_play(int32_t recording, int32_t step, int32_t loudness, int32_t back);

/* The game's `stop`: every voice of the game's sounding recording number +recording+ goes, or
 * every voice of the game's for -1. */
void rg_mix_stop(int32_t recording);

/* Once a frame, in the interpreter's order: the frame's slice made (before the music player's
 * frame), and then every sounding note's shape moved on (after it). */
void rg_mix_frame(void);
void rg_mix_step_shapes(void);

/* How many slices the mixer has made, and the newest of them: its samples, -128 to 127, at the
 * mix's own rate. No slice at all for a game that mixes nothing. */
int32_t rg_mix_slices_made(void);
int32_t rg_mix_newest_slice(const int32_t **samples);

/* What a test reads back: how many voices there are, whether voice +voice+ is sounding, and if
 * so the recording and its loudness out of 64; the most that sounded at once; and how many plays
 * found every voice busy, with the most voices the music held at one of those moments. */
int32_t rg_mix_voice_count(void);
int32_t rg_mix_voice_sounding(int32_t voice, int32_t *recording, int32_t *loudness);
int32_t rg_mix_peak(void);
int32_t rg_mix_drops(int32_t *music_held);

#endif
