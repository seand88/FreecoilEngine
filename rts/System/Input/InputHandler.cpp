/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "InputHandler.h"
#include "System/TimeProfiler.h"
#include "System/Log/ILog.h"

#include <SDL_timer.h>
#include <SDL_mouse.h>
#include <SDL_version.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

InputHandler input;

// ---------------------------------------------------------------------------
// SPRING_DBG_INJECT (KEEP; off by default; zero cost when the env var is
// unset): scripted synthetic-input injection at the SDL event queue.
//
// Rationale: OS-level input synthesis (CGEvent on macOS) cannot reach the
// game when the console session is locked/headless, which blocks unattended
// verification of input-driven rendering fixes (minimap selection box #2,
// edge scrolling #7). Pushing events into SDL's own queue exercises the REAL
// input pipeline from SDL_PollEvent onward — InputHandler -> MouseInput
// (incl. the macOS Retina coordinate mapping under test in #7) ->
// CMouseHandler -> minimap/selection code — differing from a physical mouse
// only below the SDL boundary. Pair with SPRING_DBG_INPUT=1 to log how every
// injected event is received and mapped.
//
// Usage: SPRING_DBG_INJECT=<path>. The engine polls for <path> each event
// pump; the file may be written AFTER launch (drivers usually compute
// coordinates from runtime state first). Timeline starts when the file is
// first parsed. Lines (SDL *logical window* coordinates, y-down, origin
// top-left; '#' comments):
//   <t_sec> move  <x> <y>
//   <t_sec> down  <x> <y> [button]   (1=left 2=middle 3=right; default 1)
//   <t_sec> up    <x> <y> [button]
//   <t_sec> wheel <dy>               (positive = scroll up; integer lines)
// Events whose time has passed are pushed in order at the next pump.
namespace {

struct InjEvent {
	float t;
	int kind;   // 0=move 1=down 2=up 3=wheel
	int x, y, b;
};

class GestureInjector {
public:
	GestureInjector() {
		const char* p = getenv("SPRING_DBG_INJECT");
		if (p != nullptr && p[0] != '\0') {
			path = p;
			armed = true;
		}
	}

	void Pump() {
		if (!armed || done)
			return;
		if (!parsed) {
			TryParse();
			return;
		}
		const float now = (SDL_GetTicks() - t0) * 0.001f;
		while (next < evs.size() && evs[next].t <= now) {
			Push(evs[next]);
			++next;
		}
		if (next >= evs.size()) {
			done = true;
			LOG("[inject] done, %d events injected", (int)evs.size());
		}
	}

private:
	void TryParse() {
		FILE* f = fopen(path.c_str(), "r");
		if (f == nullptr)
			return;   // not written yet; keep polling
		char line[256];
		while (fgets(line, sizeof(line), f) != nullptr) {
			if (line[0] == '#' || line[0] == '\n' || line[0] == '\r')
				continue;
			float t = 0.0f;
			char kind[16] = {0};
			int a = 0, b = 0, c = 0;
			const int n = sscanf(line, "%f %15s %d %d %d", &t, kind, &a, &b, &c);
			if (n < 3)
				continue;
			if (strcmp(kind, "move") == 0 && n >= 4) evs.push_back({t, 0, a, b, 0});
			else if (strcmp(kind, "down") == 0 && n >= 4) evs.push_back({t, 1, a, b, (n >= 5 && c > 0) ? c : 1});
			else if (strcmp(kind, "up") == 0 && n >= 4) evs.push_back({t, 2, a, b, (n >= 5 && c > 0) ? c : 1});
			else if (strcmp(kind, "wheel") == 0) evs.push_back({t, 3, 0, 0, a});
		}
		fclose(f);
		parsed = true;
		t0 = SDL_GetTicks();
		LOG("[inject] armed: %d events from %s", (int)evs.size(), path.c_str());
	}

	void Push(const InjEvent& e) {
		SDL_Event ev;
		memset(&ev, 0, sizeof(ev));
		switch (e.kind) {
			case 0: {
				ev.type = SDL_MOUSEMOTION;
				ev.motion.timestamp = SDL_GetTicks();
				ev.motion.state = buttonMask;
				ev.motion.x = e.x;
				ev.motion.y = e.y;
				ev.motion.xrel = e.x - lastX;
				ev.motion.yrel = e.y - lastY;
				lastX = e.x; lastY = e.y;
			} break;
			case 1:
			case 2: {
				ev.type = (e.kind == 1) ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
				ev.button.timestamp = SDL_GetTicks();
				ev.button.button = e.b;
				ev.button.state = (e.kind == 1) ? SDL_PRESSED : SDL_RELEASED;
				ev.button.clicks = 1;
				ev.button.x = e.x;
				ev.button.y = e.y;
				if (e.kind == 1)
					buttonMask |= SDL_BUTTON(e.b);
				else
					buttonMask &= ~SDL_BUTTON(e.b);
				lastX = e.x; lastY = e.y;
			} break;
			case 3: {
				ev.type = SDL_MOUSEWHEEL;
				ev.wheel.timestamp = SDL_GetTicks();
				ev.wheel.y = e.b;
				ev.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
#if SDL_VERSION_ATLEAST(2, 0, 18)
				ev.wheel.preciseX = 0.0f;
				ev.wheel.preciseY = (float)e.b;
#endif
			} break;
			default: return;
		}
		SDL_PushEvent(&ev);
	}

	bool armed = false;
	bool parsed = false;
	bool done = false;
	std::string path;
	std::vector<InjEvent> evs;
	size_t next = 0;
	Uint32 t0 = 0;
	int lastX = 0, lastY = 0;
	Uint32 buttonMask = 0;
};

} // namespace
// ---------------------------------------------------------------------------

InputHandler::InputHandler() = default;

void InputHandler::PushEvent(const SDL_Event& ev)
{
	for (const auto& eventHandler : eventHandlers) {
		if (eventHandler) {
			if (eventHandler(ev))
				break;
		}
	}
}

void InputHandler::PushEvents()
{
	SCOPED_TIMER("Misc::InputHandler::PushEvents");

	// scripted gesture injection (no-op unless SPRING_DBG_INJECT is set);
	// pushed into SDL's queue HERE so the poll loop below drains the events
	// through the exact per-frame path real input takes
	{
		static GestureInjector injector;
		injector.Pump();
	}

	SDL_Event event;

	while (SDL_PollEvent(&event)) {
		// SDL_PollEvent may modify FPU flags
		streflop::streflop_init<streflop::Simple>();
		PushEvent(event);
	}
}

InputHandler::HandlerTokenT InputHandler::AddHandler(InputHandler::HandlerFuncT func)
{
	for (size_t i = 0; i < eventHandlers.size(); ++i) {
		if (eventHandlers[i] == nullptr) {
			eventHandlers[i] = func;
			return InputHandler::HandlerTokenT{ *this, i};
		}
	}
	eventHandlers.emplace_back(func);
	return InputHandler::HandlerTokenT{ *this, eventHandlers.size() - 1 };
}
