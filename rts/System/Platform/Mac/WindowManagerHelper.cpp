/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "System/Platform/WindowManagerHelper.h"
#include <SDL_video.h>


namespace WindowManagerHelper {

void BlockCompositing(SDL_Window* window)
{
	//FIXME implement?
}


int GetWindowState(SDL_Window* window)
{
	return SDL_GetWindowFlags(window);
}


void SetWindowResizable(SDL_Window* window, bool resizable)
{
	// Was a stub: the engine window stayed permanently resizable on macOS,
	// so fullscreen/borderless windows kept the resizable styleMask (and the
	// fullscreen-Space eligibility SDL derives from it) against
	// SetWindowAttributes' intent. SDL2 implements this portably.
	SDL_SetWindowResizable(window, resizable ? SDL_TRUE : SDL_FALSE);
}

}; // namespace WindowManagerHelper
