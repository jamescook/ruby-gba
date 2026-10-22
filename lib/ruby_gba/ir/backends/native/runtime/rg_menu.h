/*
 * The menu drawn over the picture: Dear ImGui through SDL3's renderer (rg_menu.cpp).
 *
 * It only draws, and calls the plain functions of rg_window.h for anything a player does with
 * it — it keeps no setting of its own — so everything it can do, a hotkey or a settings file
 * can do too, and all of that is tested with no window. A desktop build a person plays always
 * has it; the builds a test makes of the game (no SDL, no window) leave it out.
 */
#ifndef RG_MENU_H
#define RG_MENU_H

#include <SDL3/SDL.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Starts the menu on a window and the renderer that draws it. False when it could not. */
bool rg_menu_start(SDL_Window *window, SDL_Renderer *renderer);
void rg_menu_stop(void);

/* Every event the window gets, before anything else looks at it. */
void rg_menu_event(const SDL_Event *event);

/* A text box has the keyboard (the variables' filter): keys typed are not the game's, and not
 * the window's hotkeys either. */
bool rg_menu_wants_keyboard(void);

/* Draws the menu bar, the windows that are open and the frame rate over the picture just drawn,
 * and leaves it as it found it. +now_ns+ is the time, SDL_GetTicksNS(). */
void rg_menu_draw(SDL_Renderer *renderer, uint64_t now_ns);

#ifdef __cplusplus
}
#endif

#endif
