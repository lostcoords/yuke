import { check } from "yuke:test";
import { plugins } from "yuke";
import { composerVim, transcriptVim } from "yuke/plugins";

// A view plugin holds its work behind `inject(["tui"])`, and no frontend provides that service here.
let built = 0;
plugins.use({ name: "probe", apply: (ctx) => { ctx.inject(["tui"], () => { built += 1; }); } });
check("no-tui-plugin", !plugins.has("tui"));
check("block-never-built", built === 0);

plugins.use(composerVim);
plugins.use(transcriptVim);
check("composer-vim-live", plugins.has("composer-vim"));
check("transcript-vim-live", plugins.has("transcript-vim"));
