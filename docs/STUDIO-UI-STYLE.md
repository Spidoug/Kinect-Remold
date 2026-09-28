<div align="center">

# SynKinect Studio UI language

### Shared visual and textual rules for built-in and external modules

[Documentation](README.md) · [Module behavior](STUDIO-MODULE-BEHAVIOR.md) · [Module layout](MODULE-LAYOUT.md)

</div>

SynKinect Studio uses one frontend vocabulary and one presentation system across Windows and Linux. Modules provide localized semantic strings and state; the host owns typography, button rendering, hover/selected feedback, responsive layout, native dialogs and pointer-coordinate conversion.

## Capitalization

Visible UI text uses sentence case. Ordinary words are not promoted to all capitals or title case merely because they appear in a card, metric, button or status. Proper names and established technical abbreviations keep their conventional form, including `SynKinect`, `Kinect`, `RGB`, `RGB-D`, `IR`, `USB`, `ICP`, `IMU`, `HQ`, `WASAPI`, `SDK`, `API`, `XYZ`, `STL`, `OBJ`, `PLY`, `RMS` and `SNR`.

Examples: `Metric depth`, `Sensor calibration`, `Noise reducer`, `Tracked`, `Waiting`, `System camera`, `Build mesh`, and `Choose folder`.

## Shared state vocabulary

State values are concise and stable. Built-in modules prefer the common terms `Ready`, `Waiting`, `Live`, `Searching`, `Connecting`, `Reconnecting`, `Recording`, `Paused`, `Unavailable`, `Disabled`, `Failed` and `Recovered`. A specialized state may be used when it carries additional meaning, but it must not duplicate one of these with different capitalization.

The top summary card of each built-in module is titled `Status` in the active locale. Specialized lower panels retain semantic names such as `Capture`, `Playback`, `Beam control`, `Mesh tools` and `Actions`.

## Actions and controls

Buttons use short verb-first labels and sentence case. Toggle buttons describe the action that will occur when pressed (`Enable control` / `Disable control`, `Arm` / `Disarm`). Selection controls show their current value in the same component, such as `Hand: Auto`. Persistent selected state is represented by the button interior; the outline is reserved for pointer hover.

Folder and file selection is a host frontend service. Modules request a directory or destination file and the host opens the native operating-system chooser without forcing an arbitrary initial directory.

## Localization

Capitalization belongs to the locale catalog; the renderer does not uppercase or title-case strings automatically. Repeated concepts use the same translated term across modules. Technical abbreviations remain unchanged unless a locale has an established localized convention.

## External modules

External Studio modules should expose semantics rather than custom chrome. Using the host panel, metric, button, progress, table, status and dialog services automatically gives the module the same layout, interaction feedback and language rules as the built-in modules.


## Capability-driven controls

The Home/system panel must not branch on a Kinect generation name merely to decide which controls the user can see. Visibility and enablement are driven by the selected device's advertised capabilities and published endpoints. Generation remains internal transport metadata. This keeps 1414, 1473 and 1517 behavior identical at the UI boundary and lets future modules inherit common actions without adding generation-specific front-end code.

A control that represents a real operating-system resource, such as **Open camera**, is shown only when that resource/path is actually published. A readiness probe must not be presented as a user action.
