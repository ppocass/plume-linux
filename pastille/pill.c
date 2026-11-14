// Pastille de Plume, prototype GTK4 — en C.
//
// Question : la pastille du Mac (capsule sombre, sans decoration, sans vol de
// focus, au-dessus de tout, posee en bas de l'ecran) peut-elle exister sous
// Linux ?
//
// Reponse mesuree pendant cette session :
//
//   macOS         : NSPanel(.nonactivatingPanel) + NSVisualEffectView + SwiftUI
//   Linux/Wayland : GtkWindow + gtk4-layer-shell (OVERLAY + ancre BAS)
//   Linux/X11     : GtkWindow presente normalement, puis deplacee par Xlib
//
// Deux pieges payes ici, a ne pas repayer :
//
//  1. gtk4-layer-shell est **Wayland seulement**. Sous X11, il refuse de
//     s'initialiser (« not on Wayland ») et toutes ses fonctions sont des
//     no-ops : pas de positionnement, pas de couche overlay.
//  2. Poser override_redirect APRES que GTK a mappe la fenetre la fait
//     **disparaitre** (le compositeur l'avait deja composee). Le type
//     NOTIFICATION et un deplacement Xlib suffisent, et n'inversent rien.
//
// Le cas X11 est celui d'Alexandre (Mint 22, XFCE) : c'est donc celui qui
// compte pour la premiere version Linux.

#include <gtk/gtk.h>
#include <gtk4-layer-shell.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <gdk/x11/gdkx.h>

static const char *CSS =
    "window { background: transparent; }\n"
    ".pill { background-color: rgba(22, 22, 24, 0.86);\n"
    "        border-radius: 28px;\n"
    "        border: 1px solid rgba(255,255,255,0.12);\n"
    "        padding: 0 20px; }\n"
    ".hint { color: rgba(255,255,255,0.58); font-size: 12px; }\n"
    ".bar  { background-color: #33D6E0; border-radius: 2px; }\n";

static const int BAR_HEIGHTS[5] = { 8, 16, 24, 14, 10 };
static const int WANT_W = 260, WANT_H = 56, MARGIN = 72;

typedef struct { Display *dpy; Window win; int x, y; } Placement;

// Deplace la fenetre une fois que GTK l'a peinte, et la declare comme
// notification (jamais decorée, jamais focalisee).
static gboolean place_x11(gpointer data) {
    Placement *p = data;

    Atom prop  = XInternAtom(p->dpy, "_NET_WM_WINDOW_TYPE", False);
    Atom notif = XInternAtom(p->dpy, "_NET_WM_WINDOW_TYPE_NOTIFICATION", False);
    XChangeProperty(p->dpy, p->win, prop, XA_ATOM, 32, PropModeReplace,
                    (unsigned char *)&notif, 1);

    XMoveWindow(p->dpy, p->win, p->x, p->y);
    XRaiseWindow(p->dpy, p->win);
    XFlush(p->dpy);
    g_print("pose       : type NOTIFICATION, deplacee en %d,%d\n", p->x, p->y);
    fflush(stdout);
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
    gtk_init();

    GtkWidget *window = gtk_window_new();
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
    gtk_window_set_deletable(GTK_WINDOW(window), FALSE);
    gtk_widget_set_can_focus(window, FALSE);
    gtk_widget_set_size_request(window, WANT_W, WANT_H);

    const char *backend = gdk_display_get_name(gdk_display_get_default());
    gboolean wayland = backend != NULL && g_str_has_prefix(backend, "wayland");

    if (wayland) {
        gtk_layer_init_for_window(GTK_WINDOW(window));
        gtk_layer_set_layer(GTK_WINDOW(window), GTK_LAYER_SHELL_LAYER_OVERLAY);
        gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_BOTTOM, TRUE);
        gtk_layer_set_margin(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_BOTTOM, MARGIN);
        gtk_layer_set_namespace(GTK_WINDOW(window), "plume-pill");
        g_print("affichage  : Wayland (gtk4-layer-shell, overlay + ancre bas)\n");
    } else {
        g_print("affichage  : X11 (GTK + Xlib pour le placement)\n");
    }

    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, CSS);
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(box, "pill");

    GtkWidget *bars = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 3);
    gtk_widget_set_valign(bars, GTK_ALIGN_CENTER);
    for (int i = 0; i < 5; i++) {
        GtkWidget *b = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_size_request(b, 3, BAR_HEIGHTS[i]);
        gtk_widget_set_valign(b, GTK_ALIGN_CENTER);
        gtk_widget_add_css_class(b, "bar");
        gtk_box_append(GTK_BOX(bars), b);
    }
    gtk_box_append(GTK_BOX(box), bars);

    GtkWidget *label = gtk_label_new("Plume — écoute…");
    gtk_widget_add_css_class(label, "hint");
    gtk_box_append(GTK_BOX(box), label);

    gtk_window_set_child(GTK_WINDOW(window), box);
    gtk_window_present(GTK_WINDOW(window));

    if (!wayland) {
        static Placement p;
        GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
        if (surface != NULL) {
            Display *dpy = GDK_DISPLAY_XDISPLAY(gdk_surface_get_display(surface));
            p.dpy = dpy;
            p.win = gdk_x11_surface_get_xid(surface);
            int screen = DefaultScreen(dpy);
            int sw = DisplayWidth(dpy, screen), sh = DisplayHeight(dpy, screen);
            p.x = (sw - WANT_W) / 2;
            p.y = sh - WANT_H - MARGIN;
            g_timeout_add(150, place_x11, &p);
            g_print("position   : %d,%d (centre bas, marge %d px, ecran %dx%d)\n",
                    p.x, p.y, MARGIN, sw, sh);
        }
    }

    g_print("taille     : %d x %d\n", WANT_W, WANT_H);
    g_print("decoration : aucune\n");
    g_print("focus      : jamais (can_focus = FALSE)\n");
    g_print("style      : capsule 86%% opaque, coins 28 px, barres #33D6E0\n");
    fflush(stdout);

    int frames = 0;
    while (frames < 2000) {
        while (g_main_context_pending(NULL)) g_main_context_iteration(NULL, FALSE);
        g_usleep(10000);
        frames++;
    }

    gtk_window_destroy(GTK_WINDOW(window));
    g_print("fermee proprement\n");
    return 0;
}
