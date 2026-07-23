# X11 GLX

Validates hardware-accelerated GLX and bounded `glxgears` frame progress against the active XRandR refresh.

## Coverage

- Dynamically discovers the usable `DISPLAY` and `XAUTHORITY` pair.
- Uses the shared `display_x11_print_glx_pipeline()` parser from `lib_display.sh` and rejects indirect, unaccelerated, or software GLX rendering.
- Captures the active XRandR refresh before starting the benchmark.
- Runs `glxgears` for a bounded duration and parses decimal interval output such as `5.0 seconds`.
- Uses the native `glxgears -fullscreen` option; no external window watcher is needed.
- Returns `SKIP` on KGSL/proprietary Adreno boot mode.

## Options

```sh
./run.sh --help
./run.sh
./run.sh --fullscreen --duration 12
./run.sh --windowed --duration 12
./run.sh --require-xfce
```

`--fullscreen` is the default. Expected FPS is derived dynamically from the active XRandR mode and is never hardcoded to 60 Hz.

## Evidence

- `X11_GLX.res`
- `logs/X11_GLX/glxinfo-B.log`
- `logs/X11_GLX/glxgears.log`
