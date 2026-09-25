import { agentRows } from "yuke:internal/agents-ui";
agentRows("b").then((rows) => result = rows.map((row) => row.item.session.id + ":" + row.depth).join(","), (e) => result = e.message);
