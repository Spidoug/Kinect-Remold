# Native runtimes

`drivers/windows/` and `drivers/linux/` contain source and installer templates only. Generated output is never stored beneath those directories.

A full build publishes:

- Windows runtime: `binaries/windows/drivers/`
- Windows SDK: `binaries/windows/sdk/`
- Linux runtime: `binaries/linux/drivers/`
- Linux SDK: `binaries/linux/sdk/`

Linux uses script-only installation. See `docs/BUILD-DRIVERS.md`.
