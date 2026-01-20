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
pub const XTextProperty = c.XTextProperty;

pub const ShiftMask = c.ShiftMask;
pub const LockMask = c.LockMask;
pub const ControlMask = c.ControlMask;
pub const Mod1Mask = c.Mod1Mask;
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
pub const SelectionClear = c.SelectionClear;
pub const PropertyNotify = c.PropertyNotify;
pub const FocusIn = c.FocusIn;
pub const FocusOut = c.FocusOut;
pub const EnterNotify = c.EnterNotify;
pub const LeaveNotify = c.LeaveNotify;

// Mouse button constants
pub const Button1 = c.Button1;
pub const Button2 = c.Button2;
pub const Button3 = c.Button3;
pub const Button4 = c.Button4;
pub const Button5 = c.Button5;

pub const CWBackPixel = c.CWBackPixel;
pub const CWBorderPixel = c.CWBorderPixel;
pub const CWBitGravity = c.CWBitGravity;
pub const CWCursor = c.CWCursor;
pub const NorthWestGravity = c.NorthWestGravity;
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
pub const EnterWindowMask = c.EnterWindowMask;
pub const LeaveWindowMask = c.LeaveWindowMask;

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
pub const XkbKeycodeToKeysym = c.XkbKeycodeToKeysym;
pub const XResizeWindow = c.XResizeWindow;

pub const XftDrawCreate = c.XftDrawCreate;
pub const XftFontOpenName = c.XftFontOpenName;
pub const XftDrawDestroy = c.XftDrawDestroy;
pub const XftFontClose = c.XftFontClose;
pub const XftColorAllocValue = c.XftColorAllocValue;
pub const XftDrawRect = c.XftDrawRect;
pub const XftDrawString32 = c.XftDrawString32;
pub const XftTextExtents32 = c.XftTextExtents32;
pub const XftDrawChange = c.XftDrawChange;

// X11 Selection/Clipboard Atoms
pub const XA_STRING = c.XA_STRING;
pub const XA_ATOM = c.XA_ATOM;
pub const PropModeReplace = c.PropModeReplace;
// XA_CLIPBOARD might not be directly available in all C compilers via @cImport
// Define it manually if not available, using XInternAtom at runtime in code
const XA_CLIPBOARD_NAME = "CLIPBOARD";
const XA_PRIMARY_NAME = "PRIMARY";
const XA_STRING_NAME = "STRING";
const UTF8_STRING_NAME = "UTF8_STRING";

// Helper function to get clipboard atom
pub fn getClipboardAtom(dpy: *Display) c.Atom {
    return XInternAtom(dpy, XA_CLIPBOARD_NAME, False);
}

pub fn getPrimaryAtom(dpy: *Display) c.Atom {
    return XInternAtom(dpy, XA_PRIMARY_NAME, False);
}

pub fn getStringAtom(dpy: *Display) c.Atom {
    return XInternAtom(dpy, XA_STRING_NAME, False);
}

pub fn getUtf8Atom(dpy: *Display) c.Atom {
    return XInternAtom(dpy, UTF8_STRING_NAME, False);
}

// Selection functions
pub const XSetSelectionOwner = c.XSetSelectionOwner;
pub const XGetSelectionOwner = c.XGetSelectionOwner;
pub const XConvertSelection = c.XConvertSelection;
pub const XGetTextProperty = c.XGetTextProperty;
pub const XSetTextProperty = c.XSetTextProperty;
pub const XStoreBytes = c.XStoreBytes;
pub const XChangeProperty = c.XChangeProperty;
pub const XFree = c.XFree;
pub const XLookupString = c.XLookupString;
pub const XSendEvent = c.XSendEvent;
pub const XDefaultRootWindow = c.XDefaultRootWindow;
pub const XInternAtom = c.XInternAtom;
pub const XCreateFontCursor = c.XCreateFontCursor;
pub const XDefineCursor = c.XDefineCursor;
pub const XFreeCursor = c.XFreeCursor;
pub const XC_xterm = c.XC_xterm;
pub const XC_left_ptr = c.XC_left_ptr;

pub const XOpenIM = c.XOpenIM;
pub const XCloseIM = c.XCloseIM;
pub const XCreateIC = c.XCreateIC;
pub const XDestroyIC = c.XDestroyIC;
pub const XFilterEvent = c.XFilterEvent;
pub const XSetICFocus = c.XSetICFocus;
pub const XUnsetICFocus = c.XUnsetICFocus;
pub const XSetLocaleModifiers = c.XSetLocaleModifiers;
pub const Xutf8LookupString = c.Xutf8LookupString;

pub const XIM = c.XIM;
pub const XIC = c.XIC;
pub const XNInputStyle = c.XNInputStyle;
pub const XNClientWindow = c.XNClientWindow;
pub const XNFocusWindow = c.XNFocusWindow;
pub const XIMPreeditNothing = c.XIMPreeditNothing;
pub const XIMStatusNothing = c.XIMStatusNothing;

pub fn XConnectionNumber(dpy: *Display) c_int {
    return c.XConnectionNumber(dpy);
}
