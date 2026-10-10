#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// GApplication is single-instance: when the desktop opens AppImages with us
// (or `appmanager some.AppImage` runs while a window is open), the running
// instance receives them through the "open" signal and passes them to Dart on
// the "appmanager/open" channel.

struct _MyApplication {
  GtkApplication parent_instance;
  GtkWindow* window;
  FlMethodChannel* open_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void create_window(MyApplication* self, char** dart_args) {
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(self)));
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));

  // Use a header bar when running in GNOME, a traditional title bar on other
  // X11 window managers (they may do more exotic layout, e.g. tiling).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "AppImage Manager");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "AppImage Manager");
  }
  gtk_window_set_icon_name(window, APPLICATION_ID);
  gtk_window_set_default_size(window, 960, 640);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, dart_args);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_clear_object(&self->open_channel);
  self->open_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "appmanager/open", FL_METHOD_CODEC(codec));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window == nullptr) {
    char* no_args[] = {nullptr};
    create_window(self, no_args);
  } else {
    gtk_window_present(self->window);
  }
}

// Implements GApplication::open.
static void my_application_open(GApplication* application, GFile** files,
                                gint n_files, const gchar* hint) {
  MyApplication* self = MY_APPLICATION(application);
  g_autoptr(GPtrArray) paths = g_ptr_array_new_with_free_func(g_free);
  for (gint i = 0; i < n_files; i++) {
    gchar* path = g_file_get_path(files[i]);
    if (path != nullptr) g_ptr_array_add(paths, path);
  }
  if (self->window == nullptr) {
    // A fresh window gets the files as its command-line arguments.
    g_autoptr(GPtrArray) args = g_ptr_array_new();
    for (guint i = 0; i < paths->len; i++) {
      g_ptr_array_add(args, g_ptr_array_index(paths, i));
    }
    g_ptr_array_add(args, nullptr);
    create_window(self, reinterpret_cast<char**>(args->pdata));
    return;
  }
  g_autoptr(FlValue) list = fl_value_new_list();
  for (guint i = 0; i < paths->len; i++) {
    fl_value_append_take(
        list, fl_value_new_string(
                  static_cast<const gchar*>(g_ptr_array_index(paths, i))));
  }
  fl_method_channel_invoke_method(self->open_channel, "open", list, nullptr,
                                  nullptr, nullptr);
  gtk_window_present(self->window);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_object(&self->open_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Without this the X11 WM_CLASS is the binary name ("AppRun.wrapped" inside
  // the AppImage), so docks can't match the window to our .desktop file's
  // StartupWMClass and show a generic icon.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_OPEN, nullptr));
}
