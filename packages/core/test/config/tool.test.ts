import { describe, expect } from "bun:test"
import { Agent } from "@opencode/core/agent"
import { Config } from "@opencode/core/config"
import { ConfigToolPlugin } from "@opencode/core/config/plugin/tool"
import { Plugin } from "@opencode/core/plugin"
import { PluginHost } from "@opencode/core/plugin/host"
import { Session } from "@opencode/core/session"
import { SessionMessage } from "@opencode/core/session/message"
import { Tool } from "@opencode/core/tool"
import { Document, Info } from "@opencode/schema/config"
import { ConfigTool } from "@opencode/schema/config/tool"
import { Effect, Schema } from "effect"
import { it } from "../lib/effect"
import { PluginTestLayer } from "../plugin/fixture"

describe("ConfigToolPlugin.Plugin", () => {
  it.live("applies end-turn declarations by effective tool name", () =>
    Effect.gen(function* () {
      const tools = yield* Tool.Service
      const config = yield* Config.Test
      const plugins = yield* Plugin.Service
      yield* tools.transform((editor) => {
        editor.add({
          name: "mcp-cross-project_ask_project",
          description: "",
          input: Schema.Struct({}),
          options: { codemode: false },
          execute: () => Effect.succeed({ content: "accepted" }),
        })
        editor.add({
          name: "ordinary",
          description: "",
          input: Schema.Struct({}),
          options: { codemode: false },
          execute: () => Effect.succeed({ content: "ok" }),
        })
      })
      yield* config.setEntries([
        new Document({
          type: "document",
          info: new Info({
            tool: { "mcp-cross-project_ask_project": new ConfigTool.Info({ end_turn: true }) },
          }),
        }),
      ])
      yield* ConfigToolPlugin.Plugin.effect(yield* PluginHost.make(plugins, "test"))
      const snapshot = yield* tools.snapshot()
      const run = (name: string) =>
        snapshot.execute({
          sessionID: Session.ID.make("ses_tool_config"),
          agent: Agent.ID.make("build"),
          messageID: SessionMessage.ID.make("msg_tool_config"),
          call: { type: "tool-call", id: `call-${name}`, name, input: {} },
        })
      expect((yield* run("mcp-cross-project_ask_project")).endTurn).toBe(true)
      expect((yield* run("ordinary")).endTurn).toBeUndefined()
    }).pipe(Effect.provide(PluginTestLayer)),
  )
})
