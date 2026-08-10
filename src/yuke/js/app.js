// yuke bootstrap: the baked default entry the host evaluates. It brings up the core (which
// installs globalThis.onEvent) and the default UI. A user's ~/.config/yuke/yuke.js is evaluated
// after this and layers on top — adding keymaps, patching prototypes, or swapping the view.
import "yuke:core";
import "yuke:defaults";
