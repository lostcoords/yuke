ctx.interaction.confirm = () => new Promise(() => {});
spawnAgent(ctx, { name: "invalid", message: "task", model: "small" }, { aborted: false }, site).then(() => result = "accepted", (e) => result = e.code);
