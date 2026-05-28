# TypeFlow — Intelligent Typing Layer for AI-Native Terminals

## Problem

Modern AI-agent workflows have changed how developers use terminals.

Tools like Claude Code are no longer command-heavy environments only. Developers now spend large amounts of time writing:

- architecture explanations
- debugging descriptions
- planning prompts
- implementation instructions
- natural-language specifications
- bilingual communication
- iterative AI conversations

However, terminal applications on macOS still behave like traditional shell interfaces.

This creates a major UX gap:

| Environment | Writing Experience |
|---|---|
| Safari / Notes / ChatGPT app | Full autocorrect, predictive typing, grammar assistance |
| Warp / iTerm / Terminal.app | Minimal prose assistance |

For developers using Claude Code for many hours per day, this creates significant friction.

---

# Core Idea

Build an intelligent typing layer for AI-native terminal workflows that enables:

- native macOS autocorrection
- inline predictive text
- grammar correction
- AI-assisted prose completion
- bilingual writing support

ONLY while inside Claude Code sessions.

Outside Claude Code:

- terminal remains strict
- raw shell semantics preserved
- no dangerous autocorrect

This creates a safe separation between:

```text
Command Mode
```

and:

```text
Prompt / Prose Mode
```

---

# Why Existing Terminals Fail

Traditional terminals:

- prioritize raw keyboard fidelity
- often bypass Cocoa text systems
- do not fully implement NSTextInputClient
- are optimized for shell commands, not prose

As a result, macOS features such as:

- inline predictions
- grammar correction
- Writing Tools
- advanced spellcheck
- semantic completions

usually do not work correctly.

Even modern terminals like Warp only partially modernize the input layer.

---

# Key Insight

Claude Code interaction is fundamentally different from normal shell interaction.

Inside Claude Code, the user is primarily writing natural language.

Meaning:

```text
The terminal is behaving more like a chat editor than a shell.
```

This changes the architectural requirements.

---

# Proposed Solution

## Concept

A terminal-integrated typing layer that detects AI-agent sessions and dynamically switches the input system into:

```text
Prose Mode
```

while Claude Code is active.

---

# Architecture

## High-Level Model

```text
Native AppKit Text Editor
        ↓
Apple Writing Tools / NSTextInputClient
        ↓
AI Semantic Assistance Layer
        ↓
PTY Backend
        ↓
Claude Code
```

Instead of:

```text
Traditional shell-owned input buffer
```

---

# Modes

## 1. Command Mode

Used for:

- shell commands
- bash/zsh interaction
- terminal administration
- CLI tooling

Behavior:

- no aggressive autocorrect
- exact keyboard fidelity
- shell-safe editing
- standard terminal semantics

---

## 2. Prompt Mode

Activated when Claude Code is detected.

Behavior:

- Apple autocorrection enabled
- predictive typing enabled
- grammar correction enabled
- semantic AI completions
- bilingual correction support
- prose-oriented editing
- markdown-aware editing

This mode treats terminal input like a real writing environment.

---

# Claude Code Detection

Possible detection methods:

- process tree inspection
- active PTY process detection
- shell command matching (`claude`)
- terminal title detection
- environment variable detection
- subprocess hooks

Once detected:

```text
Enable Prose Mode
```

---

# macOS Technologies Involved

## Native Text System

Potential APIs:

- NSTextView
- NSTextInputClient
- NSTextInputContext
- NSSpellChecker
- Writing Tools APIs
- NSAccessibility APIs

---

# Potential AI Features

## Inline Completion

Example:

```text
I think we should split this service because...
```

AI predicts continuation while typing.

---

## Grammar Correction

Example:

```text
we need more informations about usage
```

Automatically corrected to:

```text
we need more information about usage
```

---

## Bilingual Assistance

Example:

User types:

```text
me di cuenta tarde
```

AI suggests:

```text
I realized it too late
```

or:

```text
I realized it late
```

with context-aware alternatives.

---

## Prompt-Aware Completion

Understands Claude-style prompting patterns.

Examples:

- implementation planning
- architecture prompts
- debugging prompts
- refactoring requests
- specification writing

---

# Why This Is Now Important

AI coding workflows are transforming terminals from:

```text
command execution environments
```

into:

```text
language interaction environments
```

The terminal is increasingly becoming:

- an AI IDE
- a prompt composition surface
- a conversational programming interface

Current terminal architecture is lagging behind this shift.

---

# Potential Product Directions

## Option 1 — Native Terminal

A fully new terminal application designed around:

- prose-aware editing
- AI-native interaction
- Apple Writing Tools integration
- Claude Code optimization

---

## Option 2 — Warp Extension Layer

If Warp exposes sufficient editor APIs:

- prose mode plugin
- AI correction middleware
- NSTextInput integration layer

---

## Option 3 — System Overlay Service

A macOS background service that:

- detects Claude Code sessions
- intercepts typing
- rewrites text inline
- injects corrections

using:

- Accessibility APIs
- CGEvent taps
- input method techniques

---

# UX Vision

## Desired Experience

Developer opens Warp.

Runs:

```bash
claude
```

Terminal automatically enters:

```text
Prose Mode
```

User receives:

- inline corrections
- predictive typing
- AI-assisted completions
- bilingual phrase assistance
- grammar improvements

without leaving terminal.

No copy/paste.

No overlay windows.

No browser context switching.

The experience feels native.

---

# Long-Term Direction

Future terminals will likely evolve into:

```text
Editor + AI Chat + Shell Hybrid Systems
```

rather than pure terminal emulators.

Claude Code workflows are an early signal of this transition.

---

# Summary

This idea is technically feasible.

The main challenge is not whether it can be built.

The challenge is redesigning terminal input architecture around modern AI-agent workflows rather than historical shell assumptions.

Restricting advanced writing assistance to Claude Code sessions dramatically reduces:

- safety risks
- shell corruption concerns
- command mutation issues

while enabling a significantly better user experience for prompt-heavy development workflows.

