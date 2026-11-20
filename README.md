# renoise-automation-manager

A Renoise tool that shows every graphical automation envelope of a track overlaid in one floating window, each curve in its own color (similar to the automation view of other DAWs), and lets you edit them directly: points, pencil, line, rectangle selection, copy and paste. Changes are written to the song immediately and stay in sync with the native Automation editor.

<!-- Screenshot to add: real capture of the tool open in Renoise with a fictitious example song.
![The multi automation view with eight overlaid curves on one track](docs/screenshots/main-view.png)
*Eight automation curves of one track overlaid; the active curve is drawn on top with its points.*
-->

## Requirements

- Renoise 3.5 or newer (scripting API 6.2).
- Windows, macOS or Linux. Developed and checked on Windows 11.

## Download

Each GitHub release has two files in its **Assets** section:

- `com.glitch191.RenoiseAutomationManager-<tag>.xrnx`: the tool.
- `com.glitch191.RenoiseAutomationManager-<tag>.xrnx.sha256`: its SHA-256 checksum.

To verify the download in PowerShell, compare the output with the content of the `.sha256` file:

```powershell
Get-FileHash -Algorithm SHA256 .\com.glitch191.RenoiseAutomationManager-v1.0.0.xrnx
```

## Installation

Drag and drop the `.xrnx` file onto the Renoise window, or double-click it. Renoise installs it in its tools folder.

## Opening the tool

- `Tools > Multi Automation View...` in the main menu.
- `Multi Automation View...` in the right-click menu of the Track Automation editor or of the Pattern Editor.
- A keyboard shortcut: assign `Global > Tools > Toggle Multi Automation View` in `Edit > Preferences > Keys` (Renoise does not allow tools to set default shortcuts).

## Using it

The window has a toolbar, a legend on the left and the curve canvas.

**Legend.** One row per automated parameter, shown as `Device: Parameter`. The checkbox hides or shows the curve; a click on the color swatch or name makes the curve active. Hidden curves, colors and the track lock are stored in the song.

**Active curve.** Only one curve is editable at a time. It is drawn on top, thicker and opaque, with its points. Other curves are dimmed (opacity set in Settings, 35 % by default). Click near a curve (Edit or Select tool) to make it active without changing any point. Selecting a parameter in the native Automation editor activates its curve, and the other way round.

**Time modes** (first toolbar menu):

- *Current pattern*: the selected pattern, or the playing one when *Follow* is on and Renoise is playing.
- *Pattern range*: several sequence positions side by side (From, To, *Song* for the whole song), with pattern separators and numbers. A pattern used more than once in the range is hatched and labelled *alias*; editing it changes every occurrence, and the status line says so. Pattern track aliases are resolved to their source pattern.
- *Pattern + neighbours*: the current pattern is editable in the center, with 1 to 4 read-only neighbour patterns on each side.

**Tools:**

| Tool | Action |
| --- | --- |
| Edit (E) | Double-click: add a point. Drag a point: move it. Drag on empty space: rectangle selection. |
| Pencil (P) | Freehand drawing; points are created at the snap grid and replace the drawn range. |
| Line (L) | Straight ramp between press and release (or two clicks); replaces the range, can cross patterns in Pattern range mode. |
| Select (S) | Like Edit, focused on selections. |

**Mouse and keys:**

| Input | Action |
| --- | --- |
| Shift while dragging | Fine move (one tenth), without snap |
| Ctrl while dragging | Constrain to one axis |
| Right-click or Alt + click on a point | Delete it |
| Right-click with a selection | Menu: copy, cut, delete, shift, scale around center or from bottom |
| Alt + wheel (Alt + Shift + wheel) | Scale selected values around center (from bottom) |
| Left, Right | Shift the selection by one grid step (Shift: 1/256 line) |
| Del | Delete the selection |
| Ctrl + C, Ctrl + X, Ctrl + V | Copy, cut, paste at the mouse position (works on another curve or pattern) |
| Tab, Shift + Tab | Next, previous curve |
| Wheel | Scroll in time |
| Ctrl + wheel | Zoom in time around the mouse |
| Ctrl + plus, Ctrl + minus, Ctrl + 0 | Interface zoom up, down, back to 125 % |
| Esc | Cancel the gesture or the selection; close the window |

Other toolbar controls: *Snap* and the grid (Line, 1/2, 1/4, 1/8, Free), the interpolation of the active curve (Points, Lines, Curves), *Add lane* (menu of automatable parameters without automation), *Lock track* (keep showing this track), *Follow* (follow playback), *Fit* (show the whole range), *Legend*, *Settings*.

Every gesture (a drag, a pencil stroke, a line, a paste) is one undo step in Renoise, named for example `Multi Automation: Move points`.

**Values.** Hovering or dragging a point shows the parameter, the time (pattern, line, sub-line, 0-based like the Pattern Editor) and the value. Real values are shown for linear parameters of native devices; other parameters are shown as a percentage. Reading values never changes a parameter.

**Settings** (button): interface zoom (100 to 200 %), window size (Compact, Wide, Ultrawide, or a custom width and height), default tool, snap, inactive curve opacity, follow playback, diagnostics. The diagnostics line shows the number of curves and points drawn, average and worst render time of the canvas (Lua drawing time measured with `os.clock`) and the playhead update rate. It can also be toggled with the `Global > Tools > Toggle Multi Automation View Diagnostics` key binding.

## Known limitations

- The window is a floating Renoise dialog: it cannot be docked in the lower frame and cannot be resized with the mouse. Use the size presets or custom size in Settings.
- The interface zoom scales sizes, lines and hit areas, but not the fonts of Renoise controls.
- The Curves interpolation and the point scaling in Lines mode are drawn with an approximation (monotone cubic curve, power curve); Renoise does not document its exact formulas.
- Real values are approximate for some parameters (linear mapping only); plugin and non-linear parameters are shown as percentages.
- Patterns used several times in the sequence share their automation: editing one occurrence changes all of them.
- Hidden curves, colors and the active curve are stored per track index: moving a track moves its settings to another track.
- Points can be moved in time within their own pattern only.
- The playhead moves at the Renoise idle rate (about 10 times per second) and by whole lines.
- During a drag, the new values are written to the song when the mouse button is released.

## Manual check list

1. Install the `.xrnx` (drag and drop), open the tool from the Tools menu, the Track Automation menu and the shortcut.
2. On a track with 8 automations: 8 distinct curves; hide one in the legend, it disappears; save, close and reopen the song: hidden state and colors are restored.
3. Click near an inactive curve: it becomes active, no point changes; Tab cycles curves; the native Automation editor follows.
4. Double-click adds a point, drag moves it (with Shift and Ctrl), right-click deletes it, snap grid works.
5. Pencil, Line (also across two patterns in Pattern range mode), rectangle selection, scale, shift, copy and paste to another curve and pattern, interpolation change, Add lane.
6. Ctrl + Z in Renoise undoes each gesture in one step.
7. Edit a point in the native editor: the tool updates in under half a second, and the reverse.
8. Change track, lock the track, delete a device, an automation, a track; load another song: no error in the scripting console.
9. Play the song: the playhead moves, Follow scrolls the view; Pattern range and neighbours modes match the native editor.
10. Ctrl + plus, Ctrl + minus, Ctrl + 0, the size presets on a 1920 x 1080 and a 3440 x 1440 screen.

## Development

Requirements: LuaJIT or Lua 5.1 for the tests, PowerShell for the scripts.

```powershell
# Run the tests
powershell -ExecutionPolicy Bypass -File scripts/test.ps1

# Install for development (junction into %APPDATA%\Renoise\V<latest>\Scripts\Tools, auto reload on)
powershell -ExecutionPolicy Bypass -File scripts/install-dev.ps1

# Build dist/com.glitch191.RenoiseAutomationManager.xrnx
powershell -ExecutionPolicy Bypass -File scripts/build-xrnx.ps1

# Verification previews of the drawing logic (SVG in out/previews, not Renoise screenshots)
luajit tests/preview.lua
```

The development install creates a git-ignored `dev.flag` file that enables `_AUTO_RELOAD_DEBUG`; it is never included in the archive. For editor support, clone the official API definitions into `.cache/renoise-definitions` (`git clone https://github.com/renoise/definitions .cache/renoise-definitions`); `.luarc.json` points LuaLS to them.

Releases: publishing a GitHub release runs `.github/workflows/release.yml`, which runs the tests, converts the tag to the numeric manifest Version (`v1.2.0` becomes `1.0200`), builds the archive and attaches it with its checksum. The workflow can also be started by hand (Actions tab, *Release*, *Run workflow*); the archive is then kept as a workflow artifact.

All songs and data used in tests and previews are fictitious.

## Project structure

```
main.lua            menus, key bindings, tool notifiers
manifest.xml        tool manifest
core/               pure logic, tested outside Renoise
  points.lua        point list operations for every tool
  timeline.lua      sequence positions on one time axis, aliases, multi-pattern ramps
  geometry.lua      time and value to pixels, zoom, scroll, grid
  interp.lua        approximate interpolation for drawing
  editor.lua        mouse and keyboard gestures, selection, clipboard
  render.lua        canvas drawing
  layout.lua        window sizes and zoom
  palette.lua, valuefmt.lua, hittest.lua, tooldata.lua
bridge/             Renoise song access: reading, writing, notifiers, preferences
ui/app.lua          window, toolbar, legend, settings
tests/              test runner, Renoise mock, SVG canvas, previews
scripts/            test, development install, archive build
```

## License

MIT, see [LICENSE](LICENSE).
