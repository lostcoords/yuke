import { check } from "yuke:internal/test";
import { style, resolveRowStyle, overlayStyleGroup } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { tuiPlugin } from "yuke:internal/tui";
import { chatPlugin } from "yuke:internal/chat";
import { sessionsPlugin } from "yuke:internal/session";
import { transcriptView } from "yuke:internal/transcript-view";
import "yuke:internal/ui";

plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);
plugins.use(transcriptView);

// The default look names palette colors, so a palette change recolors it.
style.setPalette({ accent: "#010101", accentMuted: "#020202", surface: "#030303" });
check("brand-accent", style.resolve("YukeBrand").fg === "#010101");
const user = style.resolve("TxUser");
check("user-card", user.bg === "#030303" && !user.reverse);
// A selection over a user message keeps its own background, so it stays visible.
check("select-over-user", resolveRowStyle(overlayStyleGroup("TxUser", "TxSelect"), "TxUser").bg === "#020202");
