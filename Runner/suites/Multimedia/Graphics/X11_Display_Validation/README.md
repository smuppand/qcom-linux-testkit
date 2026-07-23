# X11 Display Validation

Dynamically validates the active X11 server, authority, connected output, current XRandR mode and root-window state.

## Runtime policy

- Intended for upstream MSM DRM/KMS plus Mesa/freedreno on Xorg.
- Dynamically discovers `DISPLAY`, `XAUTHORITY`, session type, active output and refresh.
- Returns `SKIP` on a detected KGSL/proprietary Adreno boot; use Weston/Wayland tests for that stack.
- Does not stop LightDM/Xorg, start Weston, switch graphics packages, or modify the active display mode.
- Uses `lib_pkg_provider.sh` package sets rather than embedding package-manager commands.

## Run

```sh
./run.sh --help
./run.sh
```

The runner writes `X11_Display_Validation.res` and an `X11_Display_Validation_out/` evidence directory when applicable.
