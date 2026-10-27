/*
 * The windows drawn over the picture: Dear ImGui through SDL3's renderer (rg_menu.cpp). The menu
 * itself is the library's own (rg_window_menu.h); these are the window of keys and gamepad
 * buttons, the window of the game's variables, and what was wrong with the settings file.
 *
 * They only draw, and call the plain functions of rg_window.h for anything a player does with
 * them — they keep no setting of their own — so everything they can do, a hotkey or a settings
 * file can do too, and all of that is tested with no window. A desktop build a person plays always
 * has them; the builds a test makes of the game (no SDL, no window) leave them out.
 */
#ifndef RG_MENU_H
#define RG_MENU_H

#include <SDL3/SDL.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Starts them on a window and the renderer that draws it. False when it could not. */
bool rg_menu_start(SDL_Window *window, SDL_Renderer *renderer);
void rg_menu_stop(void);

/* Every event the window gets, before anything else looks at it. */
void rg_menu_event(const SDL_Event *event);

/* A text box has the keyboard (the variables' filter): keys typed are not the game's, and not
 * the window's hotkeys either. */
bool rg_menu_wants_keyboard(void);

/* Draws the windows that are open over the picture just drawn, through the renderer they were
 * started on, and leaves that as it found it. */
void rg_menu_draw(void);

#ifdef __cplusplus
}
#endif

#endif
