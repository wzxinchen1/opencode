export * as ConfigToolPlugin from "./tool.js"

import { define } from "@opencode/plugin/effect/plugin"
import { Effect } from "effect"
import { Config } from "../../config.js"
import { Tool } from "../../tool.js"
import { ConfigEntryObserver } from "./entry-observer.js"

export const Plugin = define({
  id: "opencode.config.tool",
  effect: Effect.fn(function* (ctx) {
    const config = yield* Config.Service
    const tools = yield* Tool.Service
    const loaded = yield* ConfigEntryObserver.observe(config, ctx.event, tools.reload())
    yield* tools.transform((editor) => {
      const configured = Config.latest(loaded.entries, "tool")
      if (!configured) return
      for (const [name, info] of Object.entries(configured))
        if (info.end_turn !== undefined) editor.endTurn(name, info.end_turn)
    })
  }),
})
