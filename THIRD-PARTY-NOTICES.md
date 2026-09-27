# Third-party notices

Project authorship: Douglas Santana / @spidoug.

This document identifies third-party projects and build-time/runtime components referenced by Kinect Xbox 360 Remold. It is an attribution/index document, not a new project-wide license grant.

## AI-assisted development

This project was developed and reviewed with assistance from **OpenAI ChatGPT, GPT-5.6 Sol**.

The AI assistant was used as an engineering aid for source-code review, debugging, refactoring, documentation, build/runtime analysis, UI consistency work, and generation of implementation changes. AI assistance does not replace project authorship, maintainership, testing responsibility, licensing obligations, or hardware validation. AI-assisted code remains subject to the same project review, build, test, attribution, and license requirements as human-written changes.

The repository does not require ChatGPT, an OpenAI API, or any AI service at build time or runtime. No OpenAI model weights or proprietary AI runtime components are distributed with this project.

## Processing Core

SynKinect Studio builds against **Processing Core 4.4.6**. The repository does not commit the JAR; the Studio build downloads the specified artifact and verifies its SHA-256 before use.

Upstream: https://processing.org/

## JogAmp / JOGL / GlueGen

SynKinect Studio uses **JOGL 2.5.0** and **GlueGen Runtime 2.5.0**, including platform-native Windows/Linux AMD64 JARs. These files are generated runtime dependencies and are not committed to the repository. The builders obtain them from the JogAmp Maven repository and validate the configured SHA-256 values.

Upstream: https://jogamp.org/

## Microsoft Windows Camera reference

The Windows virtual-camera implementation uses Microsoft Windows Camera material under the license retained at:

- `licenses/MIT-Microsoft-Windows-Camera.txt`

The Windows native toolchain bootstrap also includes text snapshots of Microsoft Windows Driver Samples WDK WinGet/Visual Studio configuration files under `drivers/modules/kinect-xbox-360-remold/windows/source/build/`. They are retained as build metadata so the build uses a deterministic toolchain configuration without downloading mutable configuration text.

## Microsoft Kinect UAC firmware

Microsoft Kinect UAC firmware is not committed as a binary redistribution in this repository. The Windows build obtains **UACFirmware 01.02.709.00** from Microsoft Kinect for Windows Runtime v1.8, validates the Runtime installer and embeds the extracted firmware into AudioBridge. The normal Linux build obtains and verifies the same Runtime v1.8 package and extracts the exact same raw firmware; `KINECT_UAC_FIRMWARE` is an optional build-time offline source for that already-validated image. The Linux installer never downloads firmware.

External dependency identities and integrity pins used by the Windows native build are centralized in:

- `drivers/modules/kinect-xbox-360-remold/windows/source/build/Product.psd1`

The Microsoft Kinect body/skeleton runtime is not linked or used by SynKinect Studio. The Runtime v1.8 package is used here only as the official source for the Kinect UAC audio firmware path described above.

## v4l2loopback

The Linux build uses **v4l2loopback 0.15.4** as source for the generated virtual-camera kernel module. The source archive is downloaded only during the build, its pinned SHA-256 is verified, and the resulting kernel-specific `.ko` plus its SHA-256 are placed in the generated Linux bundle. The source archive and compiled module are not committed to this repository.

Upstream: https://github.com/v4l2loopback/v4l2loopback/

## WiX Toolset v3 build-time extractor

The Windows source build downloads the `wix` 3.14.1 NuGet package only as a build-time tool and uses its portable `dark.exe` to unpack the Microsoft Kinect Runtime v1.8 Burn bundle. WiX is not installed system-wide and is not included in the repository or installed Remold runtime.


