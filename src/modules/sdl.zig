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
pub const SDL_CreateRGBSurfaceFrom = c.SDL_CreateRGBSurfaceFrom;
pub const SDL_FreeSurface = c.SDL_FreeSurface;
pub const SDL_CreateTextureFromSurface = c.SDL_CreateTextureFromSurface;
pub const SDL_QueryTexture = c.SDL_QueryTexture;
pub const SDL_SetTextureBlendMode = c.SDL_SetTextureBlendMode;
pub const SDL_SetTextureColorMod = c.SDL_SetTextureColorMod;
pub const SDL_BLENDMODE_BLEND = c.SDL_BLENDMODE_BLEND;

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
pub const SDL_SCANCODE_0 = c.SDL_SCANCODE_0;
pub const SDL_SCANCODE_1 = c.SDL_SCANCODE_1;
pub const SDL_SCANCODE_2 = c.SDL_SCANCODE_2;
pub const SDL_SCANCODE_3 = c.SDL_SCANCODE_3;
pub const SDL_SCANCODE_4 = c.SDL_SCANCODE_4;
pub const SDL_SCANCODE_5 = c.SDL_SCANCODE_5;
pub const SDL_SCANCODE_6 = c.SDL_SCANCODE_6;
pub const SDL_SCANCODE_7 = c.SDL_SCANCODE_7;
pub const SDL_SCANCODE_8 = c.SDL_SCANCODE_8;
pub const SDL_SCANCODE_9 = c.SDL_SCANCODE_9;
pub const SDL_SCANCODE_A = c.SDL_SCANCODE_A;
pub const SDL_SCANCODE_B = c.SDL_SCANCODE_B;
pub const SDL_SCANCODE_C = c.SDL_SCANCODE_C;
pub const SDL_SCANCODE_D = c.SDL_SCANCODE_D;
pub const SDL_SCANCODE_E = c.SDL_SCANCODE_E;
pub const SDL_SCANCODE_F = c.SDL_SCANCODE_F;
pub const SDL_SCANCODE_G = c.SDL_SCANCODE_G;
pub const SDL_SCANCODE_H = c.SDL_SCANCODE_H;
pub const SDL_SCANCODE_I = c.SDL_SCANCODE_I;
pub const SDL_SCANCODE_J = c.SDL_SCANCODE_J;
pub const SDL_SCANCODE_K = c.SDL_SCANCODE_K;
pub const SDL_SCANCODE_L = c.SDL_SCANCODE_L;
pub const SDL_SCANCODE_M = c.SDL_SCANCODE_M;
pub const SDL_SCANCODE_N = c.SDL_SCANCODE_N;
pub const SDL_SCANCODE_O = c.SDL_SCANCODE_O;
pub const SDL_SCANCODE_P = c.SDL_SCANCODE_P;
pub const SDL_SCANCODE_Q = c.SDL_SCANCODE_Q;
pub const SDL_SCANCODE_R = c.SDL_SCANCODE_R;
pub const SDL_SCANCODE_S = c.SDL_SCANCODE_S;
pub const SDL_SCANCODE_T = c.SDL_SCANCODE_T;
pub const SDL_SCANCODE_U = c.SDL_SCANCODE_U;
pub const SDL_SCANCODE_V = c.SDL_SCANCODE_V;
pub const SDL_SCANCODE_W = c.SDL_SCANCODE_W;
pub const SDL_SCANCODE_X = c.SDL_SCANCODE_X;
pub const SDL_SCANCODE_Y = c.SDL_SCANCODE_Y;
pub const SDL_SCANCODE_Z = c.SDL_SCANCODE_Z;
pub const SDL_SCANCODE_F1 = c.SDL_SCANCODE_F1;
pub const SDL_SCANCODE_F2 = c.SDL_SCANCODE_F2;
pub const SDL_SCANCODE_F3 = c.SDL_SCANCODE_F3;
pub const SDL_SCANCODE_F4 = c.SDL_SCANCODE_F4;
pub const SDL_SCANCODE_F5 = c.SDL_SCANCODE_F5;
pub const SDL_SCANCODE_F6 = c.SDL_SCANCODE_F6;
pub const SDL_SCANCODE_F7 = c.SDL_SCANCODE_F7;
pub const SDL_SCANCODE_F8 = c.SDL_SCANCODE_F8;
pub const SDL_SCANCODE_F9 = c.SDL_SCANCODE_F9;
pub const SDL_SCANCODE_F10 = c.SDL_SCANCODE_F10;
pub const SDL_SCANCODE_F11 = c.SDL_SCANCODE_F11;
pub const SDL_SCANCODE_F12 = c.SDL_SCANCODE_F12;

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
