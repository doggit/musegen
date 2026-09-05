# MuseGenerator - development notes

## Goal

Generate a random melody and insert it into the selected bars of a score.

## API research summary

Documentation for the MuseScore 4.x plugin API is scarce. The most reliable
reference is the source code itself, specifically the engraving API v1 module:

- https://github.com/musescore/MuseScore/tree/v4.7.4/src/engraving/api/v1

Key findings (verified against the v4.7.4 tag):

- The plugin root object is `MuseScore` (import `MuseScore 3.0`). Properties:
  `menuPath`, `title`, `version`, `description`, `pluginType` ("dialog"),
  `requiresScore`, `categoryCode`, `thumbnailName`.
- `curScore` gives the current `Score` (`Score.newCursor()`,
  `Score.selection`, `Score.startCmd(name)` / `Score.endCmd()`).
- `Cursor` (see `cursor.h`) is the note-insertion workhorse:
  - `rewind(RewindMode)` with `SCORE_START` / `SELECTION_START` / `SELECTION_END`
  - `rewindToFraction(Fraction)` - position anywhere precisely
  - `setDuration(z, n)` - set note duration as a fraction (e.g. 1/4)
  - `addNote(pitch [, addToChord])`, `addRest()`
  - `inputStateMode`: `INPUT_STATE_INDEPENDENT` (default) vs
    `INPUT_STATE_SYNC_WITH_SCORE` (adopts the score's note-input position)
  - `fraction` property (since 4.6): position in whole-note units; the old
    `tick` property is deprecated but still usable.
- `Selection` (`selection.h`): `isRange`, `startSegment`, `endSegment`
  (excluded, null when selection runs to the end of the score),
  `startStaff`/`endStaff` (both inclusive).
- Fractions are created with the global `fraction(num, den)` helper and have
  `numerator`, `denominator`, `ticks`, `str`, plus `plus`/`minus`/
  `greaterThan`/`lessThan` methods (see `apistructs.h`).
- Careful with tick accessors - the naming is inconsistent:
  - `Segment.tick` returns an **int** (MIDI ticks); use `Segment.fraction`
    (since 4.6) for a `Fraction` object.
  - `Measure.tick` (start) and `Measure.ticks` (length) both return
    `Fraction` objects.
  - `Cursor.fraction` (since 4.6) returns a `Fraction`; `Cursor.tick` is a
    deprecated int.
- Key signatures: `Cursor.keySignature` returns the staff's key signature at
  the cursor position as a circle-of-fifths int (-7..+7, Key enum in
  `types/types.h`). The mode (major/minor) is NOT encoded - a key sig of 0
  is both C major and A minor, so the plugin offers a scale/mode choice.
  The major tonic pitch class is (7 * keySig) mod 12; the relative minor
  tonic is 9 semitones above it.
  - Note: this is the staff's *written* key. For transposing instruments
    (e.g. Bb clarinet) it may differ from the concert key. Untested - treat
    transposing staves as a known limitation for now.
  - Crash hazard: `keySignature` dereferences `inputState().staff()` which
    is null if the cursor has no segment. Only read it after a successful
    rewind / non-null `cursor.segment`.
- There is no API for pitch -> note-name strings. We spell pitches ourselves
  (C4 = 60 convention), choosing sharps/flats from the key signature sign.
- Element traversal: `Element.CHORD`, `chord.notes`, `chord.duration` etc.
  via `cursor.element` while iterating with `cursor.next()`.

Important behaviour of `Cursor.addNote()` (see `cursor.cpp`):

- Uses MuseScore's real note-input engine (`Score::addPitch`), so it
  overwrites existing chords/rests at the cursor position and advances the
  cursor. With a default `INPUT_STATE_INDEPENDENT` cursor, notes are entered
  in "replace" mode - perfect for filling bars.
- `setDuration()` must be called before each `addNote()` to vary rhythm.

## How `Cursor.rewind(SELECTION_START)` works

Sets the cursor to the selection's start segment and to the track of the
selection's first staff (`staffStart * 4`, i.e. voice 1). The plugin
therefore fills voice 1 of the first selected staff.

## Plugin installation

User plugins live in `~/Documents/MuseScore4/Plugins/`. The plugin is installed
as `musegenerator.qml` there. Enable it via Plugins -> Plugin Manager,
then run it via Plugins -> MuseGenerator.

## IMPORTANT: the dev loop requires a full restart

"Reload plugins" in the Plugin Manager does NOT pick up changes to a
plugin's QML content. Verified against the 4.7.4 source:

- `src/framework/extensions/internal/legacy/extpluginrunner.cpp` builds a
  fresh `QQmlComponent` from the file URL on each run - but on a single,
  persistent `QQmlEngine` (`m_engineV1` in `extensionsuiengine.cpp`).
- Nothing in the loader, runner, or UI engine ever calls
  `clearComponentCache()` / `trimComponentCache()`.
- So once the engine compiles your plugin's content type on first run, the
  stale compiled component is reused on subsequent runs even after editing
  the file. "Reload plugins" only rebuilds the file->URI map, not the
  compiled QML.

Observed symptom (real bug we hit): after editing the plugin, the dialog
TITLE BAR (from the fresh root object's `title` property) showed the new
version, but the dialog BODY (the cached compiled content) was unchanged.
A full MuseScore restart fixed it.

Dev loop: edit -> save -> restart MuseScore -> run plugin. The extracted
AppImage makes restarts cheap.

Debug tip: `console.log(...)` lines from a plugin appear in the MuseScore
log at `~/.local/share/MuseScore/MuseScore4/logs/MuseScore_*.log`. Grep for
a distinctive prefix (we use `[musegenerator]`).

## Design decisions / limitations

- Fills the selected range (or, with no range selection, from the current
  note-input position to the end of the score).
- Only voice 1 of the first selected staff.
- Pitch set: notes diatonic to the key signature (the major diatonic
  collection for that key sig, which covers both the major key and its
  relative minor identically), within the user-selected bottom/top note
  range (default E1-E3). No mode/scale choice - just diatonic-to-key.
- Rhythms: weighted random among whole/half/quarter/eighth notes; 15% rests.
  When the "Include 16th notes" checkbox is on (off by default), sixteenths
  are appended to the duration pool (`sixteenthDurations`).
- Triplets: REMOVED in v0.18.0. We tried generating eighth/quarter/half-note
  triplets via `cursor.addTuplet(fraction(3,2), span)` + three member writes,
  but could not reliably prevent subdivisions/nested tuplets inside them.
  Hard-won API lessons (in case we revisit):
  - `addTuplet`/`cmdCreateTuplet` only subdivides the chord/rest AT its
    start position; it does NOT remove content later in the span, so the
    span must be pre-cleared.
  - `Score::deleteItem` REFUSES to delete voice-0 rests, so a nested triplet
    containing a rest is not removed member-by-member; you must delete the
    whole TUPLET object (`removeElement(el.tuplet)`, handled via
    cmdDeleteTuplet).
  - `addTuplet` internally calls `changeCRlen(cr, fDuration)`; if the span's
    first element is not exactly `span` long, `changeCRlen`'s make-longer
    path splits it into beat-aligned pieces via `toDurationList`, and those
    fragments become subdivided tuplet members.
  - Even with the span consolidated to a single rest of exactly `span`,
    subdivisions still occasionally appeared - the precise trigger inside
    the engraving split was not pinned down. This is why we abandoned it.
- Syncopation control (Option B from discussion): each candidate duration is
  weighted by the cursor's position within a (quarter-note) beat via
  `onsetWeight`. On "e"/"a" (16th off-beat) durations longer than a 16th are
  multiplied by `syncopationFactor` (default 0.1); on the "and" durations
  longer than an 8th are multiplied by `offbeatLongFactor` (default 0.3).
  Beat position is derived from `cursor.fraction` by rounding to the 16th
  grid. Set a factor to 0 to forbid the case entirely (a 16th fallback keeps
  the cursor moving and back onto the grid). Verified by simulation: no
  onsets on the 16th grid when 16ths are disabled; with 16ths, off-grid
  onsets are almost always closed by a following 16th (beamed pairs).
  LIMITATION: assumes a quarter-note beat - wrong for compound time (6/8
  etc.). Reading the real beat unit from the time signature
  (`cursor.measure.timesigActual`) is a possible future improvement.
- Melodic contour: the next pitch is chosen relative to the previous one,
  weighted by interval size (diatonic steps, `intervalWeights` table) and
  hard-clamped to one octave (`maxIntervalSemitones = 12`). The first note
  is uniform over the range. Rests do not break the contour (the next note
  follows the last *sounded* note). Verified by simulation: max jump 12
  semitones, ~36% steps, ~2% octaves.
- Counterpoint "leap resolves by step" rule: after a leap of a fifth or
  larger (`leapThresholdSemitones = 7`), candidates in the opposite
  direction get a weight boost (`leapResolutionBoost = 3`), so the melody
  usually reverses after a leap but can still continue in the leap's
  direction. Verified by simulation: ~81% reversal, ~19% continuation after
  a leap.
- Chromatic accidentals (`applyAccidental`): each sounded note has a chance
  (`accidentalProbability`) to shift its pitch class by one semitone. Per
  notation convention, an alteration persists for the rest of the bar for
  that pitch class (tracked in a per-bar map keyed by pitch class, reset
  whenever `cursor.measure.tick` changes) - important for sight-reading
  practice. Alterations are clamped to the chosen range and never produce
  E#/B#/Fb/Cb (those read badly). NOTE: because an altered pitch class marks
  all its recurrences in the bar, the per-class trigger probability is NOT
  the per-note accidental rate - 0.06 yields ~10% of notes (measured);
  0.10 would yield ~16%.
- Accidentals are passed to MuseScore as raw MIDI pitches via `addNote`, so
  the exact glyph (F# vs Gb, courtesy naturals) is MuseScore's default
  note-entry spelling. Verify visually that altered notes render sensibly in
  both sharp and flat keys.
- Generation stops when the cursor passes the selection end; the last note
  may spill slightly past the boundary if its duration overshoots.
- After generation we run MuseScore's "Regroup rhythms" tool on the target
  range (see below). Generation and regroup are two separate undo steps.

## Running built-in commands from a plugin

`PluginAPI.cmd(name)` (qmlpluginapi.cpp) dispatches to MuseScore's actions
dispatcher (`actionsDispatcher()->dispatch(...)`), with a small
COMPAT_CMD_MAP for legacy names. Any action registered in
`src/notationscene/internal/notationactioncontroller.cpp` is reachable by
its action code.

"Regroup rhythms" is action code `reset-groupings`, registered as
`&Interaction::regroupNotesAndRests`, which calls
`Score::cmdResetNoteAndRestGroupings()` (engraving/editing/cmd.cpp). That
implementation operates on the current RANGE selection; if there is none it
does select-all then deselects (restoring state). So we must re-establish a
range selection on our target before dispatching, because note input
collapses the selection.

Re-selecting a range: `curScore.selection.selectRange(startTick, endTick,
startStaff, endStaff)` (selection.cpp). Ticks are int MIDI ticks; `endStaff`
is EXCLUSIVE (it does qBound(1, endStaff, nstaves) and requires
startStaff < endStaff), so a single staff N is `selectRange(..., N, N+1)`.
Get tick ints from a Fraction via `.ticks`; get the staff from the cursor
via `cursor.staffIdx` (= track / 4).

## reset-groupings is gated by UI context - must defer past dialog close

CONFIRMED problem: calling `cmd("reset-groupings")` from our `pluginType:
"dialog"` plugin fails with `no one can handle the action: reset-groupings`.

Root cause (traced through source):

- `ActionsDispatcher::doDispatch` only invokes handlers whose client returns
  true from `canReceiveAction(code)` (actions/internal/actionsdispatcher.cpp).
- `NotationActionController::canReceiveAction` falls through to the
  `m_isEnabledMap` entry, which for `reset-groupings` is `isNotationPage()`
  = `matchWithCurrent(UiCtxProjectOpened)`.
- `UiContextResolver::resolveCurrentUiContext`
  (context/internal/uicontextresolver.cpp) computes the current context from
  the top interactive URI. Our legacy dialog plugin is opened via
  `interactive()->openSync(musescore://extensions/v1/....qml)`
  (extensionsprovider.cpp `perform`, Type::Form). That URI is neither the
  notation page nor the special `muse://extensions/viewer`, so the resolver
  returns `UiCtxDialogOpened`.
- `match(UiCtxDialogOpened, UiCtxProjectOpened)` is false, so the notation
  action is gated off. (The `UiCtxUnknown` special-case in `match()` that
  WOULD allow it only triggers for `UiCtxUnknown`, not `UiCtxDialogOpened`.)

FIX: close the dialog first (`quit()`), then dispatch the command on the
next event-loop tick via a `Timer { interval: 0 }`. After the dialog closes
the notation page becomes the current context again, `isNotationPage()`
passes, and the regroup runs. The plugin QML object stays alive long enough
for the zero-interval timer to fire even though the dialog window is gone.
We stash the target range (start/end ticks + staff) in properties before
`quit()` so the timer handler can re-select and regroup.

## addTuplet behaviour (cursor.cpp) - REFERENCE ONLY, triplets removed in v0.18.0

`cursor.addTuplet(ratio, duration)`:
- `ratio` e.g. fraction(3, 2) = 3 notes in the time of 2.
- `duration` = TOTAL tuplet span as a fraction of a whole note (NOT the
  member note length). Member length = duration / ratio.denominator.
- Silently fails (LOGW, no exception) if the span crosses a bar line or the
  implied member length is not a valid duration - so always check fit
  BEFORE calling.
- After the call, the input duration is set to the member length and the
  cursor sits at the tuplet start, ready for member `addNote`/`addRest`.

## Ideas for next steps

- Parse existing elements in the selection first (like the bundled
  `NewRetrograde.qml` plugin does) to preserve non-note content or to
  generate per-voice.
- Track key changes within the selection (re-read `cursor.keySignature` as
  the generation cursor advances).
- Investigate transposing-instrument behaviour (written vs concert key and
  pitch).
- Melodic contour refinement: require stepwise (not just opposite-direction)
  resolution after a leap, prefer resolving to chord/scale tones, or add a
  cadence tendency (pull to the tonic at the end of the range).
- Make `intervalWeights` / `maxIntervalSemitones` / `leapThresholdSemitones`
  / `leapResolutionBoost` configurable in the UI if hard-coded values prove
  limiting.
- Options UI: pitch range, scale choice, rhythmic complexity, seed for
  reproducibility (Math.random has no seed - implement a small PRNG, e.g.
  mulberry32, in JS).
- Multi-staff fill by looping over `startStaff..endStaff` tracks.
- Tie handling, dynamics/articulations via `newElement(...)` + `cursor.add(...)`.
  (Tuplets via `Cursor.addTuplet` were tried and abandoned - see the triplet
  note under Design decisions.)
