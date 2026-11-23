// SPDX-License-Identifier: GPL-3.0-or-later
// The widget extension's entry point (Dishnur). xtool links an extension with
// `-e _NSExtensionMain`; a WidgetKit extension's own start is its bundle's
// main(), which @main would make the executable's entry. This definition is
// the entry xtool names, and it calls that main() (PlayportWidgets.swift).

extern void pp_widgets_main(void);

__attribute__((used, visibility("default")))
int NSExtensionMain(int argc, char *argv[])
{
    (void)argc, (void)argv;
    pp_widgets_main();
    return 0;
}
