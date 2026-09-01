# CardioSense Pro

ES197 Medical Device Project (Warwick) — ECG acquisition and analysis using an **AD8232** heart-rate sensor wired to an **Arduino Uno**.

## Files

- **`ClearCardio.mlapp`** — MATLAB App Designer GUI. Load a signal, filter it, detect R-peaks, compute heart rate, or stream live from the Arduino over serial, all from one window. Open it in MATLAB (double-click, or `appdesigner ClearCardio.mlapp`) to edit the design, or just run it.
- **`CardioSensePro.m`** — standalone all-in-one script version of the same pipeline (acquisition → filter → R-peak detection → heart rate/HRV metrics → plots). Run by typing `CardioSensePro` in the MATLAB Command Window. Supports two acquisition modes, set near the top of the file:
  - `'file'` — load a pre-recorded ECG CSV (good for testing without hardware)
  - `'arduino'` — live recording straight from the AD8232/Arduino

## Hardware wiring (AD8232 → Arduino Uno)

| AD8232 | Arduino |
|---|---|
| 3.3V | 3.3V |
| GND | GND |
| OUTPUT | A0 (analogue ECG signal) |
| LO+ | D10 (leads-off detection) |
| LO- | D11 (leads-off detection) |

The Arduino should run a sketch that reads `analogRead(A0)` at ~500 Hz (2 ms/loop) and sends each value as an integer, one per line, over serial at 9600 baud.

## Signal processing

Both the GUI and the script apply the same pipeline: a 50 Hz notch filter (UK mains), a 0.5–40 Hz band-pass filter, then R-peak detection to compute heart rate and RR-interval (HRV) metrics.

## Note on this repo

`ClearCardio.mlapp` and `CardioSensePro.m` were the two most developed versions found among several duplicate/in-progress copies scattered across old coursework folders. Earlier drafts were left out of this repo as superseded.
