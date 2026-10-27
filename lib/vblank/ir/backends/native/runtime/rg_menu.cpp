// The windows over the picture (rg_menu.h): Dear ImGui, drawn through SDL3's renderer.
//
// THIS FILE ONLY DRAWS. Anything a player does with it is a call to a plain function of
// rg_window.h, the very one a hotkey calls, and nothing is kept here but what is needed to draw:
// what is typed in a filter box. Take it away and the window still does everything.
//
// The menu itself is not here: it is the library's own (rg_window_menu.h), drawn by rg_sdl.c. What
// is left is the window of keys and gamepad buttons, the window of the game's variables, and what
// was wrong with the settings file, until the menu has its own way to show each.
#include "rg_menu.h"

#include <stdio.h>
#include <string.h>

#include "imgui.h"
#include "imgui_impl_sdl3.h"
#include "imgui_impl_sdlrenderer3.h"
#include "rg_window.h"

namespace {

SDL_Window *menu_window;
SDL_Renderer *menu_renderer;
char variable_filter[64];

// What a button that chooses a key does when it is clicked.
enum class KeyClick { NONE, CHOOSE, CLEAR };

// A button showing a key, which is clicked to choose another, and beside it an x that clears it.
KeyClick key_cell(int key) {
  if (ImGui::Button(key == RG_NO_KEY ? "(none)" : rg_window_key_name(key), ImVec2(110.0f, 0.0f))) return KeyClick::CHOOSE;
  if (key == RG_NO_KEY) return KeyClick::NONE;
  ImGui::SameLine();
  return ImGui::SmallButton("x") ? KeyClick::CLEAR : KeyClick::NONE;
}

void console_buttons_tab() {
  ImGui::TextWrapped("Click a key, then press the key you want. A button can have two keys. The x clears one.");
  if (ImGui::BeginTable("buttons", 4, ImGuiTableFlags_RowBg | ImGuiTableFlags_BordersInnerH)) {
    ImGui::TableSetupColumn("Console button");
    ImGui::TableSetupColumn("Key");
    ImGui::TableSetupColumn("Second key");
    ImGui::TableSetupColumn("Gamepad button");
    ImGui::TableHeadersRow();
    for (int button = 0; button < RG_WINDOW_BUTTONS; button++) {
      ImGui::PushID(button);
      ImGui::TableNextRow();
      ImGui::TableNextColumn();
      ImGui::TextUnformatted(rg_window_button_name(button));
      for (int slot = 0; slot < RG_WINDOW_KEYS_A_BUTTON; slot++) {
        ImGui::TableNextColumn();
        ImGui::PushID(slot);
        KeyClick click = key_cell(rg_window_button_key(button, slot));
        if (click == KeyClick::CHOOSE) rg_window_capture_key_for_button(button, slot);
        if (click == KeyClick::CLEAR) rg_window_bind_key(button, slot, RG_NO_KEY);
        ImGui::PopID();
      }
      ImGui::TableNextColumn();
      if (ImGui::Button(rg_window_pad_button_name(rg_window_pad_button(button)), ImVec2(130.0f, 0.0f))) rg_window_capture_pad_for_button(button);
      ImGui::PopID();
    }
    ImGui::EndTable();
  }
  ImGui::PushStyleColor(ImGuiCol_Text, ImGui::GetStyleColorVec4(ImGuiCol_TextDisabled));
  ImGui::TextWrapped("Any gamepad SDL knows works: click a gamepad button here, then press the one you want on the gamepad. "
                     "One that is already another button's swaps with it.");
  ImGui::PopStyleColor();
  if (ImGui::Button("Put the keys back")) rg_window_reset_keys();
  ImGui::SameLine();
  if (ImGui::Button("Put the gamepad back")) rg_window_reset_pad();
}

void hotkeys_tab() {
  ImGui::TextWrapped("Hotkeys are the window's own: the game never sees them, so a console button cannot use one of these keys.");
  if (ImGui::BeginTable("hotkeys", 2, ImGuiTableFlags_RowBg | ImGuiTableFlags_BordersInnerH)) {
    ImGui::TableSetupColumn("Does");
    ImGui::TableSetupColumn("Key");
    ImGui::TableHeadersRow();
    for (int hotkey = 0; hotkey < RG_HOTKEY_COUNT; hotkey++) {
      ImGui::PushID(hotkey);
      ImGui::TableNextRow();
      ImGui::TableNextColumn();
      ImGui::TextUnformatted(rg_window_hotkey_name(hotkey));
      ImGui::TableNextColumn();
      KeyClick click = key_cell(rg_window_hotkey_key(hotkey));
      if (click == KeyClick::CHOOSE) rg_window_capture_key_for_hotkey(hotkey);
      if (click == KeyClick::CLEAR) rg_window_bind_hotkey(hotkey, RG_NO_KEY);
      ImGui::PopID();
    }
    ImGui::EndTable();
  }
  if (ImGui::Button("Put the hotkeys back")) rg_window_reset_hotkeys();
}

void controls_window() {
  bool open = rg_window_panel_shown(RG_PANEL_CONTROLS) != 0;
  if (!open) return;
  ImGui::SetNextWindowPos(ImVec2(30.0f, 40.0f), ImGuiCond_FirstUseEver);
  ImGui::SetNextWindowSize(ImVec2(560.0f, 470.0f), ImGuiCond_FirstUseEver);
  if (ImGui::Begin("Keys, gamepad buttons and hotkeys", &open, ImGuiWindowFlags_NoSavedSettings)) {
    if (rg_window_problems()[0]) {
      ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.75f, 0.3f, 1.0f));
      ImGui::TextWrapped("The window cannot use some of the settings file:\n%s", rg_window_problems());
      ImGui::PopStyleColor();
      ImGui::Separator();
    }
    if (rg_window_capturing()) {
      ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.5f, 0.9f, 1.0f, 1.0f));
      ImGui::TextWrapped("%s", rg_window_capture_prompt());
      ImGui::PopStyleColor();
      if (ImGui::Button("Give up")) rg_window_capture_cancel();
    }
    if (rg_window_notice()[0]) {
      ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.45f, 0.4f, 1.0f));
      ImGui::TextWrapped("%s", rg_window_notice());
      ImGui::PopStyleColor();
    }
    if (ImGui::BeginTabBar("controls")) {
      if (ImGui::BeginTabItem("Console buttons")) {
        console_buttons_tab();
        ImGui::EndTabItem();
      }
      if (ImGui::BeginTabItem("Hotkeys")) {
        hotkeys_tab();
        ImGui::EndTabItem();
      }
      ImGui::EndTabBar();
    }
  }
  ImGui::End();
  rg_window_show_panel(RG_PANEL_CONTROLS, open);
  // Closing the window ends a choice it was waiting on.
  if (!open) rg_window_capture_cancel();
}

bool contains_ignoring_case(const char *text, const char *wanted) {
  if (!wanted[0]) return true;
  size_t length = strlen(wanted);
  for (; *text; text++)
    if (SDL_strncasecmp(text, wanted, length) == 0) return true;
  return false;
}

void variables_window() {
  bool open = rg_window_panel_shown(RG_PANEL_VARIABLES) != 0;
  if (!open) return;
  ImGui::SetNextWindowPos(ImVec2(30.0f, 40.0f), ImGuiCond_FirstUseEver);
  ImGui::SetNextWindowSize(ImVec2(340.0f, 380.0f), ImGuiCond_FirstUseEver);
  if (ImGui::Begin("Game variables", &open, ImGuiWindowFlags_NoSavedSettings)) {
    ImGui::SetNextItemWidth(-1.0f);
    ImGui::InputTextWithHint("##filter", "type part of a name to find it", variable_filter, sizeof variable_filter);
    if (ImGui::BeginTable("variables", 2, ImGuiTableFlags_RowBg | ImGuiTableFlags_ScrollY | ImGuiTableFlags_BordersInnerH)) {
      ImGui::TableSetupScrollFreeze(0, 1);
      ImGui::TableSetupColumn("Name");
      ImGui::TableSetupColumn("Value", ImGuiTableColumnFlags_WidthFixed, 110.0f);
      ImGui::TableHeadersRow();
      for (int i = 0; i < rg_window_watch_count(); i++) {
        if (!contains_ignoring_case(rg_window_watch_name(i), variable_filter)) continue;
        ImGui::TableNextRow();
        ImGui::TableNextColumn();
        ImGui::TextUnformatted(rg_window_watch_name(i));
        ImGui::TableNextColumn();
        ImGui::Text("%d", (int)rg_window_watch_value(i));
      }
      ImGui::EndTable();
    }
    if (rg_window_watch_dropped()) ImGui::TextDisabled("%d more not shown", rg_window_watch_dropped());
  }
  ImGui::End();
  rg_window_show_panel(RG_PANEL_VARIABLES, open);
}

// What was wrong with the settings file, over the picture as the window opens, until the player
// has seen it: a player who opened the game by double-clicking it has no terminal to read. The
// controls window keeps saying it after this is closed.
void settings_problems_window() {
  if (!rg_window_problems_unseen()) return;
  ImGuiViewport *viewport = ImGui::GetMainViewport();
  ImGui::SetNextWindowPos(viewport->GetCenter(), ImGuiCond_Appearing, ImVec2(0.5f, 0.5f));
  ImGui::SetNextWindowSize(ImVec2(520.0f, 0.0f), ImGuiCond_Appearing);
  bool open = true;
  if (ImGui::Begin("The settings file", &open, ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoCollapse)) {
    ImGui::TextWrapped("The window cannot use some of the settings file. It uses the rest, and the game plays as usual.");
    ImGui::Separator();
    ImGui::TextWrapped("%s", rg_window_problems());
    if (ImGui::Button("OK")) open = false;
  }
  ImGui::End();
  if (!open) rg_window_mark_problems_seen();
}

}  // namespace

bool rg_menu_start(SDL_Window *window, SDL_Renderer *renderer) {
  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGuiIO &io = ImGui::GetIO();
  // The window keeps its own settings (rg_window.h); ImGui is not to write a file of its own.
  io.IniFilename = nullptr;
  io.LogFilename = nullptr;
  ImGui::StyleColorsDark();
  ImGui::GetStyle().FontSizeBase = 15.0f;
  ImGui::GetStyle().WindowRounding = 4.0f;
  ImGui::GetStyle().FrameRounding = 3.0f;
  // A menu that cannot start leaves nothing of itself behind: the window plays on without it.
  if (!ImGui_ImplSDL3_InitForSDLRenderer(window, renderer)) {
    ImGui::DestroyContext();
    return false;
  }
  if (!ImGui_ImplSDLRenderer3_Init(renderer)) {
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();
    return false;
  }
  menu_window = window;
  menu_renderer = renderer;
  return true;
}

void rg_menu_stop(void) {
  if (!menu_window) return;
  ImGui_ImplSDLRenderer3_Shutdown();
  ImGui_ImplSDL3_Shutdown();
  ImGui::DestroyContext();
  menu_window = nullptr;
  menu_renderer = nullptr;
}

void rg_menu_event(const SDL_Event *event) {
  if (!menu_window) return;
  ImGui_ImplSDL3_ProcessEvent(event);
}

bool rg_menu_wants_keyboard(void) { return menu_window && ImGui::GetIO().WantTextInput; }

void rg_menu_draw(void) {
  if (!menu_window) return;
  ImGui_ImplSDLRenderer3_NewFrame();
  ImGui_ImplSDL3_NewFrame();
  ImGui::NewFrame();

  settings_problems_window();
  controls_window();
  variables_window();

  ImGui::Render();
  // The picture was drawn through a logical size (so it scales by a whole number); the windows are
  // laid out in the window's own units, so that is put aside while they are drawn.
  int logical_width = 0, logical_height = 0;
  SDL_RendererLogicalPresentation mode = SDL_LOGICAL_PRESENTATION_DISABLED;
  SDL_GetRenderLogicalPresentation(menu_renderer, &logical_width, &logical_height, &mode);
  SDL_SetRenderLogicalPresentation(menu_renderer, 0, 0, SDL_LOGICAL_PRESENTATION_DISABLED);
  // The window's own units are points, which the mouse is read in too; a screen with more pixels
  // than points (a Mac's Retina screen has two each way) draws in pixels. Dear ImGui leaves that
  // ratio to the program, so the renderer is told it while the windows draw. Without it they are
  // drawn at half their size in the top left of the window, away from where the mouse finds them,
  // and the text, cut to where it ought to be, is not drawn at all.
  float scale_x = 1.0f, scale_y = 1.0f;
  SDL_GetRenderScale(menu_renderer, &scale_x, &scale_y);
  ImGuiIO &io = ImGui::GetIO();
  SDL_SetRenderScale(menu_renderer, io.DisplayFramebufferScale.x, io.DisplayFramebufferScale.y);
  ImGui_ImplSDLRenderer3_RenderDrawData(ImGui::GetDrawData(), menu_renderer);
  SDL_SetRenderScale(menu_renderer, scale_x, scale_y);
  SDL_SetRenderLogicalPresentation(menu_renderer, logical_width, logical_height, mode);
}
