# X11 Glmark2

Runs available X11 glmark2 desktop OpenGL and OpenGL ES variants with bounded, configurable scenes and rejects software rendering.

## Coverage

- Dynamically discovers the usable X11 runtime.
- Runs `glmark2` and `glmark2-es2` when available.
- Uses a short bounded benchmark list by default.
- Requires a successful command return, hardware renderer classification, and numeric `glmark2 Score`.
- Uses glmark2's native `--fullscreen` option; no external window watcher is needed.
- Returns `SKIP` on KGSL/proprietary Adreno boot mode.

## Options

```sh
./run.sh --help
./run.sh
./run.sh --fullscreen --duration 5
./run.sh --windowed --duration 5
./run.sh --timeout 45
./run.sh --binaries glmark2,glmark2-es2
./run.sh --benchmarks ':duration=5.0,build:use-vbo=true'
./run.sh --require-xfce
```

The default benchmark configuration is:

```text
:duration=<duration>.0,build:use-vbo=true
```

The timeout is calculated dynamically from the scene count when `--timeout auto` is used.

## Evidence

- `X11_Glmark2.res`
- Per-binary logs under `logs/X11_Glmark2/`
