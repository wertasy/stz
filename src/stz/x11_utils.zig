//! X11 C API bindings
const stz = @import("stz");
const x11 = stz.c.x11;

// Helper function to get clipboard atom
pub fn getClipboardAtom(dpy: *x11.Display) x11.Atom {
    return x11.XInternAtom(dpy, "CLIPBOARD", x11.False);
}

pub fn getPrimaryAtom(dpy: *x11.Display) x11.Atom {
    return x11.XInternAtom(dpy, "PRIMARY", x11.False);
}

pub fn getStringAtom(dpy: *x11.Display) x11.Atom {
    return x11.XInternAtom(dpy, "STRING", x11.False);
}

pub fn getUtf8Atom(dpy: *x11.Display) x11.Atom {
    return x11.XInternAtom(dpy, "UTF8_STRING", x11.False);
}

pub fn getTargetsAtom(dpy: *x11.Display) x11.Atom {
    return x11.XInternAtom(dpy, "TARGETS", x11.False);
}

pub fn getDeleteWindowAtom(dpy: *x11.Display) x11.Atom {
    return x11.XInternAtom(dpy, "WM_DELETE_WINDOW", x11.False);
}
