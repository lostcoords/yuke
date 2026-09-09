import { check } from "yuke:test";
import { plugins, services } from "yuke:ext";
import { composerVim } from "yuke:composer-vim";
import { transcriptVim } from "yuke:transcript-vim";

// A view plugin holds its work behind `inject(["tui"])`, and no frontend provides that service here.
let built = 0;
plugins.use({ name: "probe", apply: (ctx) => ctx.inject(["tui"], () => { built += 1; }) });
check("no-tui-service", services.get("tui") === undefined);
check("block-never-built", built === 0);

plugins.use(composerVim);
plugins.use(transcriptVim);
check("composer-vim-live", plugins.get("composer-vim") !== undefined);
check("transcript-vim-live", plugins.get("transcript-vim") !== undefined);
