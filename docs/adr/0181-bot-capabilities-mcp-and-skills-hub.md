# 0181. Bot capabilities, MCP servers and the skills hub

Area: bots

## Copy a setup by cloning, then switch off what was not picked

The host has no selective clone, and MCP secrets come back redacted, so the phone cannot copy servers or plugins one by one. A new bot that copies another's setup is created with `clone_from`, which brings the source's config, `.env`, skills, memory and plugins. One `profiles.configure` then turns off the skills, toolsets and MCP servers that were unticked, and `plugins.manage` toggles off each unticked plugin. Unticked skills stay in the folder, only disabled. The capability step runs only when a list differs from the source's.

Lives in: `HermesMobile/Features/Bots/BotCreator.swift`

## A plugin-backed provider needs the plugin copied

A provider such as ClinePass is a per-Profile plugin. A fresh Profile seeds only the launch Profile's model block and credentials, never its plugins, so a bot made without copying a setup fails with "Unknown provider". Copy Setup From exists for this case.

Lives in: `HermesMobile/Features/Bots/BotCreateView.swift`

## Clear copied memory with an explicit Profile

A copy keeps the source's `MEMORY.md` and `USER.md` unless the user turns memory off. Clearing it is `POST /api/memory/reset?profile=<name>` with `target: all`, after the clone, and it names the Profile because a multiplexed host refuses a destructive call without one. A copy keeps the source's instructions unless new ones are typed, since `soul` is written after the clone.

Lives in: `HermesMobile/Features/Bots/BotCreator.swift`, `HermesMobile/Networking/Hermes/HermesREST.swift`

## MCP servers and hub skills are read fresh and never cached

The MCP Servers and skills hub screens name the Profile on every call and keep nothing past the screen, so a server never shows under another host or Profile. A key or token is sent once, in the call that saves it, and never stored on the phone. Every write ends in a fresh read, because the host's rows are the only truth about what changed, and only one write runs at a time. Each read carries a generation so a slow reply never lands after a Profile switch or a newer search.

A host without these methods answers -32601 (or 4017 for `skills.manage` without hub actions) and the screen says the host is too old. A plugin-provided MCP server is read-only. An OAuth server is finished on the host's machine. An install whose reply does not say `installed` is not a success, and a lost install reply is reported, never resent.

Lives in: `HermesMobile/Networking/Hermes/HermesMCPClient.swift`, `HermesMobile/Networking/Hermes/HermesSkillsHubClient.swift`, `HermesMobile/Features/Settings/MCPServersModel.swift`, `HermesMobile/Features/Skills/SkillsHubModel.swift`

## Adding from the editor keeps unsaved toggles

After a skill or MCP server is added from the bot editor's lists, the editor re-reads both lists and keeps each row the user toggled but has not saved.

Lives in: `HermesMobile/Features/Bots/BotProfileEditor.swift`
