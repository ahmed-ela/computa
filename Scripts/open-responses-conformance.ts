#!/usr/bin/env bun
// Dependencies and pinned upstream sources live in the isolated subpackage.
import { main } from "./OpenResponses/conformance.ts";
await main(process.argv.slice(2));
