export * as ConfigTool from "./tool.js"

import { Schema } from "effect"
import { optional } from "../schema.js"

export class Info extends Schema.Class<Info>("Config.Tool")({
  end_turn: Schema.Boolean.pipe(optional),
}) {}
