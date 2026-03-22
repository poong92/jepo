---
name: jepo
description: JEPO session management and memory. Use for session start/end, saving conclusions, cross-session sync, or when user mentions session management, memory, or context preservation.
allowed-tools: Read, Write, Grep, Glob, Agent
---

# JEPO Session & Memory Management

## Role
Cross-session synchronization + memory management via auto-memory and local files.
Agent routing is handled automatically by Claude Code based on subagent descriptions.

## Session Sync

On start:
- MEMORY.md auto-loads -- no separate search needed
- If needed, Read project-specific files from memory/ folder

Before end:
1. Save work summary to memory/ folder (Write)
2. List incomplete tasks
3. Save key conclusions

## Memory Tools

- **Save**: Write tool -> memory/ folder as .md files
- **Search**: Read + Grep -> memory/ folder
- **Read**: Read tool -> specific files in memory/
- **Legacy**: Mem0 MCP for historical memory lookup if needed

## Memory Rules

- Include project name in filename (e.g., memory/myproject_conclusions.md)
- Include evidence (no speculative saves)
- Priority: conclusion > milestone > session_summary (newest first)

## Core Principles

1. Execution first (action over planning)
2. Memory persistence (auto-memory)
3. Evidence-based (only save verified results)
4. Data hygiene (no test/temp data in memory)
