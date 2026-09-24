# Applications

This directory contains SynKinect Studio source, resources, runtime launcher templates and the module SDK source. Generated application runtimes are not stored here.

Build outputs are:

- `binaries/windows/applications/SynKinectStudio/`
- `binaries/linux/applications/SynKinectStudio/`

The Studio resolves the sibling native runtime in the corresponding `binaries/<os>/drivers/` directory and does not embed a duplicate driver tree.
