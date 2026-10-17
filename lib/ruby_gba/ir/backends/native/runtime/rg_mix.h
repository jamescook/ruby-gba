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
extern const int8_t rg_game_recording_samples[];

/* The game's own `play` of recording number +recording+: read +step+ 65536ths of a sample for
 * each sample of the mix (its pitch), at +loudness+ out of 512, going +back+ that many samples at
 * its end (0 to stop there), and +loops+ if it was asked to, which decides who gives way when a
 * song's note wants its voice. Every number was worked out when the game was built. With every
 * voice busy it takes the quietest of the song's notes falling away, or is dropped. */
void rg_mix_play(int32_t recording, int32_t step, int32_t loudness, int32_t back, int32_t loops);

/* A NOTE OF THE SONG'S on part +lane+ (counted among its parts that play recordings), from a song
 * of +rank+ (IR::Tunes.song_rank) — or of SOUND EFFECT number +effect+, of the effect's rank, for an
 * +effect+ other than -1. +sound+ is the recording, the step, how far back it reads, and
 * its shape (whether it has one, then four numbers), and +loudness+ is out of 512. Which voice it
 * gets is the interpreter's rule (Reference::Mixer#start_music_note): the part's own, unless its
 * note there has a shape and is left to fall away; then a free one; then the quietest note
 * falling away; then the lowest-ranked sound below this one, the game's own first and of those
 * the one playing longest, a one-shot before a loop. Nought when it got none and is not played. */
int32_t rg_mix_start_music_note(int32_t effect, int32_t lane, int32_t rank, const int32_t *sound, int32_t loudness);

/* A part rests: its note ends, falling away if it has a shape. Nought when it had none sounding.
 * The part is the song's for an +effect+ of -1, else that sound effect's (as above). */
int32_t rg_mix_release_music(int32_t effect, int32_t lane);
/* The song stops or changes: every note it holds ends the same way. */
void rg_mix_release_all_music(void);
/* The music volume moved: part +lane+'s sounding note plays at +loudness+ from now on. Nought
 * when it has none sounding. */
int32_t rg_mix_rescale_music(int32_t lane, int32_t loudness);

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

/* What a sounding voice is playing: the recording, its loudness out of 512, how far its shape has
 * climbed or fallen, and whose it is — +owner+ 0 for the game's own sound, 1 for the song's, 2 for
 * a sound effect's, with the effect's number (-1 for none) and the part's lane. */
typedef struct {
  int32_t recording;
  int32_t loudness;
  int32_t level;
  int32_t owner;
  int32_t effect;
  int32_t lane;
} rg_mix_voice_reading;

/* What a test reads back: how many voices there are, and whether voice +voice+ is sounding, with
 * what it is playing; the most that sounded at once; and how many plays found every voice busy,
 * with the most voices the music held at one of those moments. */
int32_t rg_mix_voice_count(void);
int32_t rg_mix_voice_sounding(int32_t voice, rg_mix_voice_reading *reading);
int32_t rg_mix_peak(void);
int32_t rg_mix_drops(int32_t *music_held);

#endif
