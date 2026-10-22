// The menu over the picture (rg_menu.h): Dear ImGui, drawn through SDL3's renderer.
//
// THIS FILE ONLY DRAWS. Anything a player does with it is a call to a plain function of
// rg_window.h, the very one a hotkey calls, and nothing is kept here but what is needed to draw:
// whether the mouse moved lately, what is typed in a filter box. Take it away and the window
// still does everything; it just has no menu to ask with.
//
// Learned from Dusklight's overlay (TwilitRealm/dusklight, src/dusk/imgui): a main menu bar that is
// only there when it is wanted, windows opened from it for the larger things, settings saved as
// they are changed, and a hotkey to hide the lot. What it does differently: it never pauses the
// game on its own, because here pausing is a thing a player chooses (and has a hotkey for).
#include "rg_menu.h"

#include <stdio.h>
#include <string.h>

#include "imgui.h"
#include "imgui_impl_sdl3.h"
#include "imgui_impl_sdlrenderer3.h"
#include "rg_window.h"

namespace {

SDL_Window *the_window;
Uint64 mouse_moved_ns;
Uint64 started_ns;
char variable_filter[64];

// How long the menu bar stays up after the mouse last moved, and after the window opens (so a
// player can see there is a menu).
constexpr Uint64 BAR_STAYS_NS = 3000000000ull;

// A key's name for the menu, where a shortcut is shown: none for a hotkey with no key.
const char *shortcut_of(int hotkey) {
  static char names[8][64];
  static int next;
  char *name = names[next++ % 8];
  int key = rg_window_hotkey_key(hotkey);
  snprintf(name, sizeof names[0], "%s", key == RG_NO_KEY ? "" : rg_window_key_name(key));
  return name;
}

// The most the picture can be scaled and still fit on the screen the window is on, so the menu
// does not offer a size the window cannot be.
int largest_scale_that_fits() {
  int most = RG_WINDOW_SCALE_MOST;
  SDL_Rect room;
  if (the_window && SDL_GetDisplayUsableBounds(SDL_GetDisplayForWindow(the_window), &room)) {
    int fits = SDL_min(room.w / 240, room.h / 160);
    if (fits < most) most = fits;
  }
  if (most < rg_window_scale()) most = rg_window_scale();
  return most < RG_WINDOW_SCALE_LEAST ? RG_WINDOW_SCALE_LEAST : most;
}

void quit_the_program() {
  SDL_Event quit;
  SDL_zero(quit);
  quit.type = SDL_EVENT_QUIT;
  SDL_PushEvent(&quit);
}

void game_menu() {
  if (!ImGui::BeginMenu("Game")) return;
  if (ImGui::MenuItem(rg_window_paused() ? "Resume" : "Pause", shortcut_of(RG_HOTKEY_PAUSE))) rg_window_toggle_pause();
  if (ImGui::MenuItem("Step one frame", shortcut_of(RG_HOTKEY_STEP), false, rg_window_paused())) rg_window_step();
  ImGui::Separator();
  int speed = rg_window_fast_speed();
  ImGui::SetNextItemWidth(140.0f);
  if (ImGui::SliderInt("Fast forward", &speed, RG_FAST_SPEED_LEAST, RG_FAST_SPEED_MOST, "%dx")) rg_window_set_fast_speed(speed);
  ImGui::TextDisabled("Hold %s to fast forward", shortcut_of(RG_HOTKEY_FAST_FORWARD));
  ImGui::Separator();
  if (ImGui::MenuItem("Quit")) quit_the_program();
  ImGui::EndMenu();
}

void window_menu() {
  if (!ImGui::BeginMenu("Window")) return;
  if (ImGui::BeginMenu("Size")) {
    for (int scale = RG_WINDOW_SCALE_LEAST; scale <= largest_scale_that_fits(); scale++) {
      char label[48];
      snprintf(label, sizeof label, "%dx  (%d x %d)", scale, 240 * scale, 160 * scale);
      if (ImGui::MenuItem(label, nullptr, scale == rg_window_scale())) rg_window_set_scale(scale);
    }
    ImGui::EndMenu();
  }
  if (ImGui::MenuItem("Fullscreen", shortcut_of(RG_HOTKEY_FULLSCREEN), rg_window_fullscreen())) rg_window_toggle_fullscreen();
  ImGui::Separator();
  if (ImGui::MenuItem("Show frame rate", shortcut_of(RG_HOTKEY_FRAME_RATE), rg_window_shows_frame_rate())) rg_window_toggle_frame_rate();
  if (ImGui::MenuItem("Show frame time", nullptr, rg_window_shows_frame_time()))
    rg_window_set_show_frame_time(!rg_window_shows_frame_time());
  ImGui::Separator();
  if (ImGui::MenuItem("Keep this menu up", shortcut_of(RG_HOTKEY_MENU), rg_window_menu_kept_up())) rg_window_toggle_menu();
  ImGui::EndMenu();
}

void sound_menu() {
  if (!ImGui::BeginMenu("Sound")) return;
  int volume = rg_window_volume();
  ImGui::SetNextItemWidth(160.0f);
  if (ImGui::SliderInt("Volume", &volume, 0, 100, "%d%%")) rg_window_set_volume(volume);
  if (ImGui::MenuItem("Mute", shortcut_of(RG_HOTKEY_MUTE), rg_window_muted())) rg_window_toggle_mute();
  ImGui::EndMenu();
}

void controls_menu() {
  if (!ImGui::BeginMenu("Controls")) return;
  if (ImGui::MenuItem("Keys, gamepad buttons and hotkeys...")) rg_window_show_panel(RG_PANEL_CONTROLS, 1);
  ImGui::EndMenu();
}

void developer_menu() {
  if (!ImGui::BeginMenu("Developer")) return;
  if (ImGui::MenuItem("Game variables...")) rg_window_show_panel(RG_PANEL_VARIABLES, 1);
  if (ImGui::MenuItem("Show frame time", nullptr, rg_window_shows_frame_time()))
    rg_window_set_show_frame_time(!rg_window_shows_frame_time());
  if (ImGui::MenuItem(rg_window_paused() ? "Resume" : "Pause", shortcut_of(RG_HOTKEY_PAUSE))) rg_window_toggle_pause();
  if (ImGui::MenuItem("Step one frame", shortcut_of(RG_HOTKEY_STEP), false, rg_window_paused())) rg_window_step();
  ImGui::EndMenu();
}

// The bar is up when something asked for it, while the mouse is near it, and for a moment when the
// window opens and after the mouse moves.
bool menu_bar_wanted(Uint64 now_ns) {
  if (rg_window_menu_kept_up()) return true;
  if (now_ns - started_ns < BAR_STAYS_NS || now_ns - mouse_moved_ns < BAR_STAYS_NS) return true;
  return ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId | ImGuiPopupFlags_AnyPopupLevel);
}

void menu_bar() {
  if (!ImGui::BeginMainMenuBar()) return;
  game_menu();
  window_menu();
  sound_menu();
  controls_menu();
  developer_menu();
  ImGui::EndMainMenuBar();
}

// What a key is, for a button that chooses one.
const char *key_label(int key) { return key == RG_NO_KEY ? "(none)" : rg_window_key_name(key); }

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
        if (ImGui::Button(key_label(rg_window_button_key(button, slot)), ImVec2(110.0f, 0.0f))) rg_window_capture_key_for_button(button, slot);
        if (rg_window_button_key(button, slot) != RG_NO_KEY) {
          ImGui::SameLine();
          if (ImGui::SmallButton("x")) rg_window_bind_key(button, slot, RG_NO_KEY);
        }
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
      if (ImGui::Button(key_label(rg_window_hotkey_key(hotkey)), ImVec2(110.0f, 0.0f))) rg_window_capture_key_for_hotkey(hotkey);
      if (rg_window_hotkey_key(hotkey) != RG_NO_KEY) {
        ImGui::SameLine();
        if (ImGui::SmallButton("x")) rg_window_bind_hotkey(hotkey, RG_NO_KEY);
      }
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
      ImGui::TextWrapped("The settings file had lines the window could not use:\n%s", rg_window_problems());
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

// The frame rate in the top right corner, and what the game is doing if it is not just playing.
void status_overlay(Uint64 now_ns) {
  bool rate = rg_window_shows_frame_rate() != 0;
  if (!rate && !rg_window_paused() && !rg_window_fast_forwarding()) return;
  ImGuiViewport *viewport = ImGui::GetMainViewport();
  ImGui::SetNextWindowPos(ImVec2(viewport->WorkPos.x + viewport->WorkSize.x - 8.0f, viewport->WorkPos.y + 8.0f), ImGuiCond_Always,
                          ImVec2(1.0f, 0.0f));
  ImGui::SetNextWindowBgAlpha(0.55f);
  ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoSavedSettings |
                           ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoInputs |
                           ImGuiWindowFlags_NoMove;
  if (!ImGui::Begin("##status", nullptr, flags)) {
    ImGui::End();
    return;
  }
  if (rate) {
    double fps = rg_window_frames_a_second(now_ns);
    ImGui::Text("%.1f fps", fps);
    if (rg_window_shows_frame_time()) ImGui::Text("%.2f ms", fps > 0.0 ? 1000.0 / fps : 0.0);
  }
  if (rg_window_paused()) ImGui::TextColored(ImVec4(1.0f, 0.8f, 0.3f, 1.0f), "PAUSED");
  else if (rg_window_fast_forwarding()) ImGui::TextColored(ImVec4(0.5f, 0.9f, 1.0f, 1.0f), "FAST FORWARD %dx", rg_window_fast_speed());
  ImGui::End();
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
  if (!ImGui_ImplSDL3_InitForSDLRenderer(window, renderer)) return false;
  if (!ImGui_ImplSDLRenderer3_Init(renderer)) return false;
  the_window = window;
  started_ns = SDL_GetTicksNS();
  mouse_moved_ns = 0;
  return true;
}

void rg_menu_stop(void) {
  if (!the_window) return;
  ImGui_ImplSDLRenderer3_Shutdown();
  ImGui_ImplSDL3_Shutdown();
  ImGui::DestroyContext();
  the_window = nullptr;
}

void rg_menu_event(const SDL_Event *event) {
  if (!the_window) return;
  ImGui_ImplSDL3_ProcessEvent(event);
  if (event->type == SDL_EVENT_MOUSE_MOTION || event->type == SDL_EVENT_MOUSE_BUTTON_DOWN) mouse_moved_ns = SDL_GetTicksNS();
}

bool rg_menu_wants_keyboard(void) { return the_window && ImGui::GetIO().WantTextInput; }

void rg_menu_draw(SDL_Renderer *renderer, uint64_t now_ns) {
  if (!the_window) return;
  ImGui_ImplSDLRenderer3_NewFrame();
  ImGui_ImplSDL3_NewFrame();
  ImGui::NewFrame();

  if (menu_bar_wanted(now_ns)) menu_bar();
  status_overlay(now_ns);
  controls_window();
  variables_window();

  ImGui::Render();
  // The picture was drawn through a logical size (so it scales by a whole number); the menu is
  // laid out in the window's own units, so that is put aside while it is drawn.
  int logical_width = 0, logical_height = 0;
  SDL_RendererLogicalPresentation mode = SDL_LOGICAL_PRESENTATION_DISABLED;
  SDL_GetRenderLogicalPresentation(renderer, &logical_width, &logical_height, &mode);
  SDL_SetRenderLogicalPresentation(renderer, 0, 0, SDL_LOGICAL_PRESENTATION_DISABLED);
  ImGui_ImplSDLRenderer3_RenderDrawData(ImGui::GetDrawData(), renderer);
  SDL_SetRenderLogicalPresentation(renderer, logical_width, logical_height, mode);
}
