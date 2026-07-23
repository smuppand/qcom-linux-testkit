# X11 GStreamer Display

Validates available GStreamer X11 video sinks with a live bounded pipeline.

## Coverage

- Dynamically discovers the usable X11 runtime.
- Tests `ximagesink` and `glimagesink` by default.
- Adds `xvimagesink` automatically when the active X server exposes an XVideo adaptor.
- Requires the pipeline to reach PLAYING, remain active for the requested duration, and report no GStreamer error.
- Forces the GL sink to the X11/EGL path.
- Runs sink windows fullscreen by default using the shared X11 watcher.
- Discovers each new sink window through exact before/after snapshots, avoiding the root, greeter, desktop, and stale windows.
- Returns `SKIP` on KGSL/proprietary Adreno boot mode.

## Options

```sh
./run.sh --help
./run.sh
./run.sh --fullscreen --duration 10
./run.sh --windowed --duration 10
./run.sh --sink ximagesink
./run.sh --sink ximagesink,glimagesink,xvimagesink
./run.sh --require-xfce
```

The pipeline remains live and bounded:

```text
videotestsrc is-live=true ! videoconvert ! <sink> sync=true
```

Fullscreen is a visual policy only. A fullscreen warning does not convert a valid rendering pipeline into a failure. Installed fullscreen commands are reused directly. The `graphics-x11-fullscreen` package set is consulted only when a required command is missing.

## Evidence

- `X11_GStreamer_Display.res`
- Per-sink logs and fullscreen status files under `logs/X11_GStreamer_Display/`
