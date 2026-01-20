//! X11 C API bindings
const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xft/Xft.h");
    @cInclude("X11/cursorfont.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/XKBlib.h");
});

// Re-export C module for explicit access if needed
pub const C = c;

// Re-export common types for easier access
pub const Display = c.Display;
pub const Window = c.Window;
pub const GC = c.GC;
pub const XEvent = c.XEvent;
pub const KeySym = c.KeySym;
pub const XftDraw = c.XftDraw;
pub const XftColor = c.XftColor;
pub const XftFont = c.XftFont;
pub const Visual = c.Visual;
pub const Colormap = c.Colormap;
pub const Pixmap = c.Pixmap;
pub const XSetWindowAttributes = c.XSetWindowAttributes;
pub const XRenderColor = c.XRenderColor;

// Re-export common constants
pub const True = 1;
pub const False = 0;
pub const None = 0;
pub const InputOutput = c.InputOutput;
pub const AllocNone = c.AllocNone;

pub const KeyPress = c.KeyPress;
pub const KeyRelease = c.KeyRelease;
pub const ButtonPress = c.ButtonPress;
pub const ButtonRelease = c.ButtonRelease;
pub const MotionNotify = c.MotionNotify;
pub const Expose = c.Expose;
pub const ConfigureNotify = c.ConfigureNotify;
pub const ClientMessage = c.ClientMessage;
pub const SelectionNotify = c.SelectionNotify;
pub const SelectionRequest = c.SelectionRequest;
pub const PropertyNotify = c.PropertyNotify;
pub const FocusIn = c.FocusIn;
pub const FocusOut = c.FocusOut;

pub const CWBackPixel = c.CWBackPixel;
pub const CWBorderPixel = c.CWBorderPixel;
pub const CWBitGravity = c.CWBitGravity;
pub const CWEventMask = c.CWEventMask;
pub const CWColormap = c.CWColormap;

pub const KeyPressMask = c.KeyPressMask;
pub const KeyReleaseMask = c.KeyReleaseMask;
pub const ButtonPressMask = c.ButtonPressMask;
pub const ButtonReleaseMask = c.ButtonReleaseMask;
pub const PointerMotionMask = c.PointerMotionMask;
pub const StructureNotifyMask = c.StructureNotifyMask;
pub const ExposureMask = c.ExposureMask;
pub const FocusChangeMask = c.FocusChangeMask;

// Re-export common functions
pub const XOpenDisplay = c.XOpenDisplay;
pub const XDefaultScreen = c.XDefaultScreen;
pub const XRootWindow = c.XRootWindow;
pub const XDefaultVisual = c.XDefaultVisual;
pub const XCreateColormap = c.XCreateColormap;
pub const XDefaultDepth = c.XDefaultDepth;
pub const XCreateWindow = c.XCreateWindow;
pub const XStoreName = c.XStoreName;
pub const XCreateGC = c.XCreateGC;
pub const XFreePixmap = c.XFreePixmap;
pub const XFreeGC = c.XFreeGC;
pub const XDestroyWindow = c.XDestroyWindow;
pub const XCloseDisplay = c.XCloseDisplay;
pub const XMapWindow = c.XMapWindow;
pub const XSync = c.XSync;
pub const XPending = c.XPending;
pub const XNextEvent = c.XNextEvent;
pub const XCreatePixmap = c.XCreatePixmap;
pub const XCopyArea = c.XCopyArea;

pub const XftDrawCreate = c.XftDrawCreate;
pub const XftFontOpenName = c.XftFontOpenName;
pub const XftDrawDestroy = c.XftDrawDestroy;
pub const XftFontClose = c.XftFontClose;
pub const XftColorAllocValue = c.XftColorAllocValue;
pub const XftDrawRect = c.XftDrawRect;
pub const XftDrawString32 = c.XftDrawString32;
