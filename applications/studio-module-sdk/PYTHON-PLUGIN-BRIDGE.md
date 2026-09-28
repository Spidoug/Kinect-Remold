<div align="center">

# Python & Non-Java Plugin Bridge

### Process/IPC boundary for modules that do not run inside the Studio JVM

[Module API](README.md) · [Applications](../README.md)

</div>

The Studio frontend contract is intentionally data-oriented. A Python process does not need to
reimplement the Studio UI. A bridge/adapter can translate JSON or IPC messages into
`StudioModuleUi` snapshots and action callbacks.

Recommended message model:

- module metadata: id, title, version, capabilities;
- UI snapshot: ordered panels;
- panel kinds: text, metrics, actions, visual, progress, table, form, log, spacer;
- visual payload: ARGB frame plus fit policy;
- action event: action id plus current form values;
- lifecycle event: activate, deactivate, selected-device change, shutdown;
- backend status: ready, busy, warning, error.

The transport is deliberately not hard-coded into the frontend API. A future Python adapter can
use stdin/stdout JSON, local sockets, named pipes, or another local IPC mechanism while preserving
the exact same host-rendered frontend.

Security boundary: external processes should receive only the capabilities and device services
explicitly granted by the Studio host. Do not expose arbitrary filesystem or shell access merely
because a module uses Python.
