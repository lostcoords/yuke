import { agentRows } from "yuke:agents-ui";
nodes.a.session.origin.site.session_id = "b";
agentRows("b").then(() => result = "accepted", (e) => result = e.message);
