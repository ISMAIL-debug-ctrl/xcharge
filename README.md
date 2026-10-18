# XCharge

Battery charge limiter for Apple Silicon Macs (built on an M2 Pro, macOS 26) — a personal AlDente.

- Charge limit with sailing range, Discharge, Top Up
- Calibration mode: 100 → 10 → 100 → hold → back to limit
- Stops charging while asleep, heat protection, stay awake until limit
- Toggle macOS Optimized Battery Charging from the panel
- Menu bar app + root helper (`CHTE` charge inhibit, `CHIE` adapter off)

## Install (first time)
```
./install.sh
```

## Update
Press **Update now** in the panel, or run `./update.sh`. A password is only asked when the helper itself changed.

## Remove
```
./uninstall.sh
```
