// SDL2 C API bindings using c_import
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub const SDL_Init = c.SDL_Init;
pub const SDL_Quit = c.SDL_Quit;
pub const SDL_CreateWindow = c.SDL_CreateWindow;
pub const SDL_DestroyWindow = c.SDL_DestroyWindow;
pub const SDL_CreateRenderer = c.SDL_CreateRenderer;
pub const SDL_DestroyRenderer = c.SDL_DestroyRenderer;
pub const SDL_SetRenderDrawColor = c.SDL_SetRenderDrawColor;
pub const SDL_RenderFillRect = c.SDL_RenderFillRect;
pub const SDL_RenderPresent = c.SDL_RenderPresent;
pub const SDL_PollEvent = c.SDL_PollEvent;
pub const SDL_Delay = c.SDL_Delay;
pub const SDL_ShowWindow = c.SDL_ShowWindow;
pub const SDL_GetError = c.SDL_GetError;
pub const SDL_RenderClear = c.SDL_RenderClear;
pub const SDL_CreateTexture = c.SDL_CreateTexture;
pub const SDL_DestroyTexture = c.SDL_DestroyTexture;
pub const SDL_RenderCopy = c.SDL_RenderCopy;

pub const SDL_Event = c.SDL_Event;
pub const SDL_Window = c.SDL_Window;
pub const SDL_Renderer = c.SDL_Renderer;
pub const SDL_Rect = c.SDL_Rect;
pub const SDL_Texture = c.SDL_Texture;
pub const SDL_KeyboardEvent = c.SDL_KeyboardEvent;
pub const SDL_Keysym = c.SDL_Keysym;

// Scancode constants
pub const SDL_SCANCODE_ESCAPE = c.SDL_SCANCODE_ESCAPE;
pub const SDL_SCANCODE_RETURN = c.SDL_SCANCODE_RETURN;
pub const SDL_SCANCODE_TAB = c.SDL_SCANCODE_TAB;
pub const SDL_SCANCODE_BACKSPACE = c.SDL_SCANCODE_BACKSPACE;
pub const SDL_SCANCODE_DELETE = c.SDL_SCANCODE_DELETE;
pub const SDL_SCANCODE_UP = c.SDL_SCANCODE_UP;
pub const SDL_SCANCODE_DOWN = c.SDL_SCANCODE_DOWN;
pub const SDL_SCANCODE_LEFT = c.SDL_SCANCODE_LEFT;
pub const SDL_SCANCODE_RIGHT = c.SDL_SCANCODE_RIGHT;
pub const SDL_SCANCODE_HOME = c.SDL_SCANCODE_HOME;
pub const SDL_SCANCODE_END = c.SDL_SCANCODE_END;
pub const SDL_SCANCODE_PAGEUP = c.SDL_SCANCODE_PAGEUP;
pub const SDL_SCANCODE_PAGEDOWN = c.SDL_SCANCODE_PAGEDOWN;

// Event types
pub const SDL_QUIT = c.SDL_QUIT;
pub const SDL_KEYDOWN = c.SDL_KEYDOWN;
pub const SDL_KEYUP = c.SDL_KEYUP;
pub const SDL_MOUSEBUTTONDOWN = c.SDL_MOUSEBUTTONDOWN;
pub const SDL_MOUSEBUTTONUP = c.SDL_MOUSEBUTTONUP;
pub const SDL_MOUSEMOTION = c.SDL_MOUSEMOTION;
pub const SDL_WINDOWEVENT = c.SDL_WINDOWEVENT;

// Window events
pub const SDL_WINDOWEVENT_RESIZED = c.SDL_WINDOWEVENT_RESIZED;

// Button codes
pub const SDL_BUTTON_LEFT = c.SDL_BUTTON_LEFT;

// Keyboard states
pub const SDL_PRESSED = c.SDL_PRESSED;
pub const SDL_RELEASED = c.SDL_RELEASED;

// Key modifier flags
pub const KMOD_LCTRL = c.KMOD_LCTRL;
pub const KMOD_RCTRL = c.KMOD_RCTRL;
pub const KMOD_LALT = c.KMOD_LALT;
pub const KMOD_RALT = c.KMOD_RALT;
pub const KMOD_LSHIFT = c.KMOD_LSHIFT;
pub const KMOD_RSHIFT = c.KMOD_RSHIFT;

// Flags
pub const SDL_INIT_VIDEO = c.SDL_INIT_VIDEO;
pub const SDL_WINDOWPOS_UNDEFINED = c.SDL_WINDOWPOS_UNDEFINED;
pub const SDL_WINDOW_RESIZABLE = c.SDL_WINDOW_RESIZABLE;
pub const SDL_WINDOW_HIDDEN = c.SDL_WINDOW_HIDDEN;
pub const SDL_RENDERER_ACCELERATED = c.SDL_RENDERER_ACCELERATED;
pub const SDL_RENDERER_PRESENTVSYNC = c.SDL_RENDERER_PRESENTVSYNC;
