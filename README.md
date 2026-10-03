# Refresh

- Menu bar app for Apple Silicon MacBooks with two external monitors.
- Finds the highest refresh rate macOS will actually drive, and keeps it after replug and sleep.
- Diagnoses problems software cannot fix (wrong plug order, mirroring hubs, too few display engines).
- Uses private Apple APIs. It can break in any macOS update. Use at your own risk.
- Idle cost: 0% CPU, zero wakeups, about 28 MB memory.

## The problem

Apple Silicon chips have a fixed number of external display engines (base M1/M2/M3: 1, Pro: 2, Max: 4).
A very fast mode, for example 1440p at 360Hz, can need **two** engines.
With a second external monitor, that mode disappears and macOS falls back to a much lower rate (180Hz on the test setup).

Refresh adds new timings that fit in **one** engine and finds the highest one macOS accepts.

Proven on a MacBook Pro 14" M4 Pro, macOS 26.5: ASUS XG27ACDNG went from 180Hz to **345Hz** (325Hz with HDR) next to a Dell AW2521HF at 240Hz.

## How it works

1. **Scan.** Copy the monitor's own timing and change only the pixel clock. Append the candidates to its EDID as a new DisplayID block. Inject it with the private `IOAVServiceSetVirtualEDIDMode`. Read back which modes macOS offers. Narrow down to 1Hz in 3 rounds. Then find the HDR ceiling the same way.
2. **Confirm.** Switch to the new rate and ask "Keep this refresh rate?". No answer in 15 seconds: put back the old EDID, rate, HDR, rotation and layout.
3. **Keep.** macOS drops the injected EDID on replug and sleep. Refresh listens for display changes, re-injects, and restores rate, HDR, rotation and layout. Between events it does nothing.
4. **Diagnose.** Count display engines, read USB-C port states, find DisplayLink adapters, and explain what to do.

## Install

Needs macOS 14+, Apple Silicon, Swift 6 (Xcode command line tools).

```bash
scripts/build-app.sh
```

```bash
cp -R dist/Refresh.app /Applications/
```

```bash
open /Applications/Refresh.app
```

The app is ad-hoc signed. If macOS blocks it, right-click it in Finder and choose Open.

## Use

1. Plug in both monitors.
2. Click the menu bar icon. Choose **Find fastest refresh for ...**. The monitors blink for about a minute.
3. Click **Keep** when the new rate looks right.
4. Turn on **Start at Login**.

To change rotation, layout or HDR: set it in System Settings, then choose **Save Current Setup**.

## CLI

```bash
swift build -c release && .build/release/refresh
```

`list`, `edid <id>`, `scan <id>`, `reset [<id>]`, `save`, `keep`, `diagnose`. `refresh reset` drops every override and returns each monitor to its factory EDID.

## Limits

- Private APIs (`IOAVService*`, `MonitorPanel.framework`). Apple can remove them without notice.
- The scan blinks your monitors for about a minute.
- The ceiling is empirical. A mode macOS offers can still be black on some monitors; the 15s auto-revert covers that.
- Wrong plug order (HDMI monitor before the USB-C hub) leaves the hub display dark. Refresh detects it but cannot fix it: unplug the HDMI cable and plug it back in.
- Not supported: Intel Macs, layout editor, RGB/YCbCr color fix, two monitors with identical serial numbers, MST "dual HDMI" hubs (macOS mirrors them by design).

## License

MIT. See `LICENSE`.
