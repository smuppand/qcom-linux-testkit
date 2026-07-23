# X11 EGL/GLES

Validates the strict X11 EGL platform and available X11 EGL/GLES clients without accepting unrelated GBM, Wayland, surfaceless, device, or software-renderer results.

## Coverage

- Dynamically discovers the usable `DISPLAY` and `XAUTHORITY` pair.
- Uses `display_print_eglinfo_pipeline x11` from `lib_display.sh`.
- Requires the selected platform to remain `x11` and the pipeline to classify as hardware GPU rendering.
- Records the selected X11 EGL vendor, version, API version, driver, GL vendor, and renderer.
- Runs available `es2gears_x11`, `eglgears_x11`, and `egltri_x11` clients for a bounded duration.
- Runs client windows fullscreen by default through the shared X11 watcher.
- Discovers the client window by exact before/after window and PID snapshots, then reapplies fullscreen while the client remains alive.
- Returns `SKIP` on KGSL/proprietary Adreno boot mode.

## Options

```sh
./run.sh --help
./run.sh
./run.sh --fullscreen --duration 12
./run.sh --windowed --duration 12
./run.sh --apps es2gears_x11,egltri_x11
./run.sh --require-xfce
```

`--fullscreen` is the default. The shared helper checks installed fullscreen commands first. Package recovery is attempted only when a required command is missing; rendering validation continues with a warning when external fullscreen support is unavailable.

## Required shared EGL cache

The current `lib_display.sh` implementation must populate:

- `EGLI_LAST_PLATFORM`
- `EGLI_LAST_EGL_VENDOR`
- `EGLI_LAST_EGL_VERSION`
- `EGLI_LAST_EGL_API_VERSION`
- `EGLI_LAST_DRIVER`
- `EGLI_LAST_GL_VENDOR`
- `EGLI_LAST_GL_RENDERER`
- `EGLI_LAST_PIPE_KIND`
- `EGLI_LAST_OUT`

## Evidence

- `X11_EGL_GLES.res`
- `logs/X11_EGL_GLES/eglinfo-x11.log`
- `logs/X11_EGL_GLES/es2-info.log`
- Per-client logs and fullscreen status files under `logs/X11_EGL_GLES/`
