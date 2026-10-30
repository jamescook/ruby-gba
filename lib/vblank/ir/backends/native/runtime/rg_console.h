/*
 * The console a game is built as: how big its screen is, and how its clock counts a frame.
 *
 * A game names the consoles it is for, and the C is built as one of them (Native::ConsoleNumbers
 * writes its numbers into rg_console_numbers.h, beside game.c). The runtime's screen buffers are
 * that size, its window shows that many pixels, and its frames last as long as that console's.
 * Where no such file is beside it — the small C programs the native tests build around one
 * header — it is the Game Boy Advance.
 */
#ifndef RG_CONSOLE_H
#define RG_CONSOLE_H

#if __has_include("rg_console_numbers.h")
#include "rg_console_numbers.h"
#endif

#ifndef RG_SCREEN_WIDTH
#define RG_SCREEN_WIDTH 240
#endif
#ifndef RG_SCREEN_HEIGHT
#define RG_SCREEN_HEIGHT 160
#endif

/* The console's own clock, and how many of its ticks one frame — a picture drawn and the gap
 * after it — takes. Together they are how long a frame is; no console shows exactly sixty a
 * second. */
#ifndef RG_CONSOLE_TICKS_A_SECOND
#define RG_CONSOLE_TICKS_A_SECOND 16777216
#endif
#ifndef RG_CONSOLE_TICKS_A_FRAME
#define RG_CONSOLE_TICKS_A_FRAME 280896
#endif

/* Whether the console's display can mix the finished picture toward a colour as it draws it. One
 * that cannot has every fade and tint mixed into its colour tables instead
 * (Console::Description#blends). */
#ifndef RG_CONSOLE_BLENDS
#define RG_CONSOLE_BLENDS 1
#endif

/* Whether the console's cartridge carries a motor that a game's `rumble` runs
 * (Console::Description#rumbles). */
#ifndef RG_CONSOLE_RUMBLES
#define RG_CONSOLE_RUMBLES 0
#endif

/* Whether the clock chip its cartridges carry holds the date, or only counts the days and the
 * time of day since it started (Console::Description#clock_keeps_date). */
#ifndef RG_CLOCK_KEEPS_DATE
#define RG_CLOCK_KEEPS_DATE 1
#endif

#endif
