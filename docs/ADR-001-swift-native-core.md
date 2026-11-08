# ADR-001: Use a Swift-native orchestration core

- Status: Accepted
- Date: 2026-07-24

## Context

The initial PRD suggested Python for iteration speed. The product target is a
single-user macOS menu-bar utility with a sub-two-second cold-start target,
long idle periods, local process supervision, sleep/wake recovery, and eventual
code signing and notarization.

The routing workload is I/O-bound, so Python, Rust, and Swift would all spend
negligible time on classification compared with model calls. The material
differences are distribution and platform integration.

## Decision

Implement the orchestrator, loopback API, CLI helper, and UI in Swift 5.9+.
Use structured concurrency, Foundation `Process`, Codable, SwiftUI/AppKit, and
`Network.framework`. Keep the JSON contracts language-neutral.

## Why not Python

Python would be fast enough at runtime, but shipping requires bundling and
signing a second runtime, increases cold-start and idle memory, and complicates
launch-at-login and native lifecycle diagnostics.

## Why not Rust

Rust is the preferred alternative if the daemon becomes cross-platform or
needs stronger low-level isolation. For macOS v1, a SwiftUI frontend plus Rust
daemon introduces an additional build, IPC, and packaging boundary without
improving the model/agent latency that users perceive.

## Consequences

- One native toolchain and one shared type system.
- No third-party runtime or server dependency.
- Direct use of macOS lifecycle and security APIs.
- The loopback HTTP implementation must remain deliberately small, bounded,
  and well tested.
- Cross-platform support would require extracting the language-neutral
  contracts and either porting the core or introducing a Rust daemon later.

