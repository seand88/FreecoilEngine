/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#ifndef MAC_PRESENT_BACKEND_H
#define MAC_PRESENT_BACKEND_H

#if defined(__APPLE__) && !defined(HEADLESS)

struct SDL_Window;

// macOS rendering backend. The engine renders through Mesa's surfaceless EGL
// (Zink -> KosmicKrisp -> Metal) into a pbuffer that acts as the GL default
// framebuffer; there is no window-system swapchain on the GL side, so every
// frame is read back and presented manually onto the window's CAMetalLayer
// (MetalPresent.mm). This module owns the EGL display/context/pbuffer
// lifecycle, the CAMetalLayer attachment, and the per-frame present path;
// CGlobalRendering calls in through this seam and stays platform-agnostic.
namespace MacPresent {
	// EGL bootstrap: display + pbuffer surface + GL context (compatibility
	// profile preferred), CAMetalLayer attach, Metal present init.
	// Call once, after the SDL window exists.
	bool CreateContext(SDL_Window* window);
	// Idempotent; skips actual EGL teardown by default (see implementation).
	void DestroyContext();
	void MakeCurrent(bool clear);
	// true between a successful CreateContext and DestroyContext
	bool ContextActive();

	// the EGL context handle (opaque; stored in CGlobalRendering::glContext)
	void* GetGLContext();
	// GL entry-point loader for gladLoadGLLoader (wraps eglGetProcAddress)
	typedef void* (*LoadProc)(const char* name);
	LoadProc GetGLLoadProc();

	// pbuffer (= GL default framebuffer) size in physical pixels
	void GetDrawableSize(int& w, int& h);
	// recreate the pbuffer at the window's current pixel size so resizes
	// render at true resolution; no-op when unchanged or before CreateContext
	void ResizeIfNeeded(SDL_Window* window);
	// NSWindow.backingScaleFactor with hardware-aware default-resolution
	// caps: never above the physical panel's pixel ratio (macOS scaled
	// desktops back the desktop with more pixels than the panel shows) and
	// within a per-GPU-core pixel budget (small GPU + large display), never
	// below 1x. Honors SPRING_MAC_NO_RETINA (force 1x) and
	// SPRING_MAC_FULL_BACKING (raw backing scale, no caps).
	double EffectiveBackingScale(SDL_Window* window);

	// Desktop-sized borderless windows ("windowed fullscreen", BAR's actual
	// fullscreen mode) must cover the ENTIRE screen. Cocoa constrains
	// normal-level windows to the visibleFrame (menu bar + Dock excluded),
	// leaving dead screen bands the cursor escapes into. With active=true
	// this forces the NSWindow frame to the full screen frame (legal for a
	// borderless styleMask) and auto-hides the menu bar and Dock while the
	// app is frontmost; active=false restores default presentation options.
	// Called from CGlobalRendering::SetWindowAttributes on every mode change.
	void EnforceBorderlessFullscreenFrame(SDL_Window* window, bool active);

	// Leaving SDL exclusive fullscreen can strand the display in the lowered
	// mode (no event fires). Restores the user's permanent display
	// configuration when the window's display size differs from the expected
	// desktop point size; no-op otherwise. Call when applying a
	// non-exclusive mode.
	void RestoreDesktopDisplayMode(SDL_Window* window, int desktopW, int desktopH);

	// read the default framebuffer back and present it onto the CAMetalLayer.
	// Returns false when the EGL context is not up — the caller falls back to
	// SDL_GL_SwapWindow.
	bool PresentFrame();

#ifdef SPRING_MAC_DIAGNOSTICS
	// SPRING_FRAME_CAPTURE: headless verification capture of the default FBO
	// (runs even when the actual present is suppressed)
	void DiagCaptureFrame();
	// SPRING_MAC_PRESENT_TEST: red/blue tracer-bullet flash via the Metal path
	void DiagRunPresentTest();
#endif
}

#endif // __APPLE__ && !HEADLESS

#endif // MAC_PRESENT_BACKEND_H
