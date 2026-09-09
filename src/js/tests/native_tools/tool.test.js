import { defineTool } from "yuke:tools";
defineTool("get_weather", {
  description: "Report the weather of one city.",
  parameters: {
    type: "object",
    properties: {
      city: { type: "string", description: "The city to report." },
      unit: { type: "string", enum: ["celsius", "fahrenheit"], description: "The unit of temperature." },
    },
    required: ["city"],
  },
  execute: async ({ city }) => ({ city, weather: "sunny" }),
});
