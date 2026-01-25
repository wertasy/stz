//! X11 C API bindings
pub const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xft/Xft.h");
    @cInclude("X11/cursorfont.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/XKBlib.h");
    @cInclude("fontconfig/fontconfig.h");
});

// Helper function to get clipboard atom
pub fn getClipboardAtom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "CLIPBOARD", c.False);
}

pub fn getPrimaryAtom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "PRIMARY", c.False);
}

pub fn getStringAtom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "STRING", c.False);
}

pub fn getUtf8Atom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "UTF8_STRING", c.False);
}

pub fn getTargetsAtom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "TARGETS", c.False);
}

pub fn getDeleteWindowAtom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "WM_DELETE_WINDOW", c.False);
}
