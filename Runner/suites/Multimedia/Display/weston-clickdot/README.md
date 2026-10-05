# weston-clickdot

Runs `weston-clickdot` inside an existing Wayland/Weston session and validates the client created and committed
a Wayland surface using `WAYLAND_DEBUG` output.

On CentOS, the shared dependency path provides `weston`, `weston-demo`, `seatd`, and `egl-utils`. With `--allow-relaunch`, the test starts `seatd.service` when needed, launches Weston on the selected DRM device, and adopts the generated Wayland socket.

## What it validates

- A connected DRM display is present (otherwise SKIP)
- A usable Wayland socket exists (otherwise SKIP)
- GPU acceleration is active (best-effort gating via `display_is_cpu_renderer auto`, otherwise continues)
- `weston-clickdot` binary exists (otherwise FAIL)
- **Optional**: Wayland protocol activity (default enabled)
  - Checks for `wl_compositor.create_surface` and `wl_surface.commit` patterns in the client log
- **Optional**: Screenshot delta (default disabled)
  - Captures before/after screenshots and validates hashes differ (visible change)
  - If `weston-screenshooter` is unauthorized or missing, screenshot validation is skipped

## Parameters (LAVA)

- `DURATION` (default `30s`)
- `VALIDATE_WAYLAND_PROTO` (default `1`)
- `VALIDATE_SCREENSHOT` (default `0`)

## Local run

```sh
cd Runner/suites/Multimedia/Display/weston-clickdot
./run.sh
cat weston-clickdot.res
