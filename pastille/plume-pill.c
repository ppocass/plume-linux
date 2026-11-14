// plume-pill — la pastille de Plume sous Linux.
//
// Elle reproduit celle du Mac (PillPanel.swift) : une capsule sombre qui
// apparait au centre bas de l'ecran pendant une dictee, avec **treize barres
// qui dansent au rythme du micro**. Rien a lire : sur le Mac il n'y a aucun
// texte dans la pastille ordinaire, seulement les barres, puis un ✓ vert.
//
// Trois phases, comme sur macOS :
//   recording   barres cyan (#33D6E0) qui suivent le niveau du micro
//   processing  barres ambre (#F5A623) qui ondulent en vague (le modele reflechit)
//   pasted      un ✓ vert (#5FD29A) — le texte est colle
//
// Elle est pilotee par des lignes sur l'entree standard :
//   level 0.42          un niveau du micro (0…1)
//   phase recording     change de phase
//   phase pasted
//   hide                fait disparaitre la pastille
//   show                la fait reapparaitre
//   quit                quitte
//
// Deux chemins d'affichage, mesures pendant le portage :
//   Wayland  gtk4-layer-shell (couche OVERLAY, ancree en bas)
//   X11      GTK + Xlib (type NOTIFICATION, position calculee)
//
// Pieges GTK4 deja payes, a ne pas repayer :
//   1. GTK_WINDOW_POPUP n'existe plus ; gtk_window_new() ne prend plus rien.
//   2. gtk4-layer-shell est Wayland seulement : sous X11 il refuse de
//      s'initialiser et toutes ses fonctions ne font rien.
//   3. override_redirect doit etre pose AVANT le map, sinon la fenetre
//      disparait.

#include <gtk/gtk.h>
// gtk4-layer-shell n'existe pas dans tous les depots (absent d'Ubuntu 24.04,
// donc de Linux Mint 22). Sans lui, la pastille fonctionne sous X11 — le cas
// courant — et ne se place simplement pas sous Wayland.
#if __has_include(<gtk4-layer-shell.h>)
#include <gtk4-layer-shell.h>
#define HAVE_LAYER_SHELL 1
#else
#define HAVE_LAYER_SHELL 0
#endif
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <gdk/x11/gdkx.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

// --- les mesures, copiees de PillPanel.swift -------------------------------
#define PILL_W 320
#define PILL_H 64
#define BAR_COUNT 13
#define BAR_WIDTH 3.0
#define BAR_SPACING 2.5
#define BAR_MAX_HEIGHT 18.0
#define MARGIN_BOTTOM 14      // « visible.minY + 14 » dans targetFrame()

#define COLOR_LISTEN "#33D6E0"
#define COLOR_THINK  "#F5A623"
#define COLOR_DONE   "#5FD29A"

enum Phase { PHASE_HIDDEN, PHASE_RECORDING, PHASE_PROCESSING, PHASE_PASTED };

static GtkWidget *window = NULL;
static GtkWidget *bars_box = NULL;
static GtkWidget *bars[BAR_COUNT];
static GtkWidget *check = NULL;
static GtkWidget *card = NULL;
static GtkCssProvider *provider = NULL;
static enum Phase phase = PHASE_HIDDEN;
static float levels[BAR_COUNT];
static double t_start = 0;
static gboolean wayland = FALSE;
static int stdin_fd = -1;
static GMainLoop *loop = NULL;

// Garde-fou : si plus aucune commande n'arrive pendant 5 minutes, c'est que le
// parent a disparu (crash, kill -9, terminal ferme). La pastille se ferme alors
// toute seule plutot que de rester a l'ecran pour toujours.
static gint64 last_command_us = 0;
#define IDLE_LIMIT_US (5LL * 60 * 1000000)

// --- le niveau, comme LevelMeter.push() sur macOS -------------------------
static void push_level(float level) {
    memmove(levels, levels + 1, (BAR_COUNT - 1) * sizeof(float));
    levels[BAR_COUNT - 1] = level;
}

// --- les hauteurs, formule exacte de PillPanel.height() -------------------
// macOS : max(3, 3 + 15 * pow(level, 0.8) + shimmer * 4)
//         shimmer = 0.5 + 0.5 * sin(t * 7 + i * 1.3)
// Le frémissement seul donne une vague lisible qui respire au calme — c'est
// ce qui evite les « treize points alignes » du bug corrige sur macOS.
static double bar_height(int i, double t) {
    if (phase == PHASE_PROCESSING) {
        // Traitement : une vague qui traverse les barres.
        double wave = sin(t * 6.0 - (double)i * 0.55);
        return 4.0 + 10.0 * ((wave + 1.0) / 2.0);
    }
    double level = (double)levels[i];
    double shimmer = 0.5 + 0.5 * sin(t * 7.0 + (double)i * 1.3);
    double h = 3.0 + 15.0 * pow(level, 0.8) + shimmer * 4.0;
    return h < 3.0 ? 3.0 : h;
}

// --- le style --------------------------------------------------------------
static char *build_css(void) {
    const char *accent = phase == PHASE_PROCESSING ? COLOR_THINK : COLOR_LISTEN;
    char *css = g_strdup_printf(
        "window { background: transparent; }\n"
        // La carte : capsule sombre. Sur macOS c'est .ultraThinMaterial + un
        // voile ; sous Linux il n'y a pas de materiau de flou universel, on
        // prend donc un noir legerement translucide, comme le style « encoche »
        // du Mac (Color(white: 0.055).opacity(0.97)) qui assume le noir.
        ".card {\n"
        "  background-color: rgba(14, 14, 15, 0.97);\n"
        "  border-radius: 32px;\n"
        "  border: 1px solid rgba(255,255,255,0.13);\n"
        "  box-shadow: 0 5px 14px rgba(0,0,0,0.42);\n"
        "}\n"
        // Les barres : des capsules (border-radius = moitie de la largeur).
        ".bar { background-color: %s; border-radius: 1.5px;"
        "       box-shadow: 0 0 4px %s; }\n"
        ".check { color: %s; font-size: 20px; font-weight: bold; }\n",
        accent, accent, COLOR_DONE);
    return css;
}

static void apply_style(void) {
    char *css = build_css();
    gtk_css_provider_load_from_string(provider, css);
    g_free(css);
}

// --- les barres : 13 capsules, chacune mise a jour a 30 images/s ----------
static gboolean tick(gpointer data) {
    if (phase == PHASE_RECORDING || phase == PHASE_PROCESSING) {
        double t = (g_get_monotonic_time() / 1000000.0) - t_start;
        for (int i = 0; i < BAR_COUNT; i++) {
            int h = (int)(bar_height(i, t) + 0.5);
            if (h < 3) h = 3;
            if (h > (int)BAR_MAX_HEIGHT) h = (int)BAR_MAX_HEIGHT;
            gtk_widget_set_size_request(bars[i], (int)BAR_WIDTH, h);
        }
    }
    return G_SOURCE_CONTINUE;
}

// --- la position, sous X11 -------------------------------------------------
static gboolean place_x11(gpointer data) {
    if (window == NULL) return G_SOURCE_REMOVE;
    GdkSurface *surface = gtk_native_get_surface(gtk_widget_get_native(window));
    if (surface == NULL) return G_SOURCE_CONTINUE;

    Display *dpy = GDK_DISPLAY_XDISPLAY(gdk_surface_get_display(surface));
    Window win = gdk_x11_surface_get_xid(surface);

    // Type NOTIFICATION : jamais decorée, jamais focalisee. C'est l'equivalent
    // X11 de .nonactivatingPanel sur macOS.
    Atom prop  = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
    Atom notif = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_NOTIFICATION", False);
    XChangeProperty(dpy, win, prop, XA_ATOM, 32, PropModeReplace,
                    (unsigned char *)&notif, 1);

    int screen = DefaultScreen(dpy);
    int sw = DisplayWidth(dpy, screen);
    int sh = DisplayHeight(dpy, screen);
    // Centre horizontal, 14 px au-dessus du bas — la valeur du Mac.
    XMoveWindow(dpy, win, (sw - PILL_W) / 2, sh - PILL_H - MARGIN_BOTTOM);
    XRaiseWindow(dpy, win);
    XFlush(dpy);
    return G_SOURCE_REMOVE;
}

static void present(void) {
    if (window == NULL) return;
    gtk_widget_set_visible(window, TRUE);
    gtk_window_present(GTK_WINDOW(window));
    if (!wayland) {
        // La surface n'existe qu'apres la presentation : on la place ensuite.
        g_timeout_add(120, place_x11, NULL);
    }
}

static void hide_pill(void) {
    if (window == NULL) return;
    gtk_widget_set_visible(window, FALSE);
}

// --- changer de phase ------------------------------------------------------
static void set_phase(enum Phase p) {
    phase = p;
    if (p == PHASE_HIDDEN) { hide_pill(); return; }

    apply_style();
    gtk_widget_set_visible(bars_box, p != PHASE_PASTED);
    gtk_widget_set_visible(check, p == PHASE_PASTED);
    if (p == PHASE_PASTED) gtk_label_set_text(GTK_LABEL(check), "✓");

    if (p == PHASE_RECORDING) {
        for (int i = 0; i < BAR_COUNT; i++) levels[i] = 0;
        t_start = g_get_monotonic_time() / 1000000.0;
    }
    present();
}

// --- l'entree standard : le pilote de la pastille -------------------------
//
// Piege corrige : un `read()` peut couper une ligne en deux (« lev » puis
// « el 0.4\n »). Le premier jet cherchait un '\n' dans le tampon du read et
// jetait le reste, donc des niveaux disparaissaient au hasard. On garde
// maintenant un tampon qui s'accumule entre deux lectures.

static char pending[4096];
static size_t pending_len = 0;

static void handle_line(char *line) {
    last_command_us = g_get_monotonic_time();
    if (strncmp(line, "level ", 6) == 0) {
        push_level((float)atof(line + 6));
    } else if (strcmp(line, "phase recording") == 0) {
        set_phase(PHASE_RECORDING);
    } else if (strcmp(line, "phase processing") == 0) {
        set_phase(PHASE_PROCESSING);
    } else if (strcmp(line, "phase pasted") == 0) {
        set_phase(PHASE_PASTED);
    } else if (strcmp(line, "hide") == 0) {
        set_phase(PHASE_HIDDEN);
    } else if (strcmp(line, "show") == 0) {
        present();
    } else if (strcmp(line, "quit") == 0) {
        if (window) { gtk_window_destroy(GTK_WINDOW(window)); window = NULL; }
        if (loop) g_main_loop_quit(loop);
    }
}

static gboolean check_idle(gpointer data) {
    if (last_command_us == 0) return G_SOURCE_CONTINUE;
    if (g_get_monotonic_time() - last_command_us > IDLE_LIMIT_US) {
        if (window) { gtk_window_destroy(GTK_WINDOW(window)); window = NULL; }
        if (loop) g_main_loop_quit(loop);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static gboolean read_stdin(gpointer data) {
    char chunk[1024];
    while (stdin_fd >= 0) {
        ssize_t n = read(stdin_fd, chunk, sizeof(chunk));
        if (n < 0) break;                       // EAGAIN : plus rien pour l'instant
        if (n == 0) {                           // le parent a ferme : on s'arrete
            if (window) { gtk_window_destroy(GTK_WINDOW(window)); window = NULL; }
            if (loop) g_main_loop_quit(loop);
            return G_SOURCE_REMOVE;
        }
        // Accumuler, puis traiter chaque ligne complete.
        if (pending_len + (size_t)n >= sizeof(pending)) pending_len = 0;  // securite
        memcpy(pending + pending_len, chunk, (size_t)n);
        pending_len += (size_t)n;
        pending[pending_len] = '\0';

        char *start = pending;
        char *nl;
        while ((nl = strchr(start, '\n')) != NULL) {
            *nl = '\0';
            handle_line(start);
            start = nl + 1;
        }
        // Ce qui reste (ligne incomplete) repasse au debut du tampon.
        pending_len = strlen(start);
        memmove(pending, start, pending_len + 1);
    }
    return G_SOURCE_CONTINUE;
}

int main(int argc, char **argv) {
    gtk_init();

    const char *backend = gdk_display_get_name(gdk_display_get_default());
    wayland = backend != NULL && g_str_has_prefix(backend, "wayland");

    window = gtk_window_new();
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
    gtk_window_set_deletable(GTK_WINDOW(window), FALSE);
    gtk_widget_set_can_focus(window, FALSE);
    gtk_widget_set_size_request(window, PILL_W, PILL_H);

#if HAVE_LAYER_SHELL
    if (wayland) {
        gtk_layer_init_for_window(GTK_WINDOW(window));
        gtk_layer_set_layer(GTK_WINDOW(window), GTK_LAYER_SHELL_LAYER_OVERLAY);
        gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_BOTTOM, TRUE);
        gtk_layer_set_margin(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_BOTTOM, MARGIN_BOTTOM);
        gtk_layer_set_namespace(GTK_WINDOW(window), "plume-pill");
    }
#else
    if (wayland) {
        fprintf(stderr, "plume-pill : compile sans gtk4-layer-shell, "
                        "le placement Wayland est indisponible\n");
    }
#endif

    provider = gtk_css_provider_new();
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(), GTK_STYLE_PROVIDER(provider), 800);

    // La carte : une capsule qui contient les barres, centrees.
    card = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(card, "card");
    gtk_widget_set_halign(card, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(card, GTK_ALIGN_CENTER);

    bars_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, (int)BAR_SPACING);
    gtk_widget_set_halign(bars_box, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(bars_box, GTK_ALIGN_CENTER);
    for (int i = 0; i < BAR_COUNT; i++) {
        bars[i] = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_size_request(bars[i], (int)BAR_WIDTH, 8);
        gtk_widget_set_valign(bars[i], GTK_ALIGN_CENTER);
        gtk_widget_add_css_class(bars[i], "bar");
        gtk_box_append(GTK_BOX(bars_box), bars[i]);
    }
    gtk_widget_set_halign(bars_box, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(bars_box, GTK_ALIGN_CENTER);
    gtk_widget_set_hexpand(bars_box, TRUE);
    gtk_box_append(GTK_BOX(card), bars_box);

    check = gtk_label_new("✓");
    gtk_widget_add_css_class(check, "check");
    gtk_widget_set_visible(check, FALSE);
    gtk_widget_set_halign(check, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(check, GTK_ALIGN_CENTER);
    gtk_widget_set_hexpand(check, TRUE);
    gtk_box_append(GTK_BOX(card), check);

    // La carte fait TOUTE la pastille (320x64), comme sur macOS : la capsule
    // est large et les treize barres occupent le centre.
    gtk_widget_set_size_request(card, PILL_W, PILL_H);
    gtk_widget_set_hexpand(card, TRUE);
    gtk_widget_set_vexpand(card, TRUE);
    gtk_window_set_child(GTK_WINDOW(window), card);

    for (int i = 0; i < BAR_COUNT; i++) levels[i] = 0;
    apply_style();
    gtk_widget_set_visible(window, FALSE);

    g_timeout_add(33, tick, NULL);   // 30 images par seconde

    stdin_fd = fileno(stdin);
    // Non bloquant : la boucle GTK reste fluide meme sans donnees.
    int flags = fcntl(stdin_fd, F_GETFL, 0);
    fcntl(stdin_fd, F_SETFL, flags | O_NONBLOCK);
    g_timeout_add(20, read_stdin, NULL);
    last_command_us = g_get_monotonic_time();
    g_timeout_add_seconds(30, check_idle, NULL);

    loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(loop);
    return 0;
}
