# MuseGenerator

A MuseScore Studio 4.7 plugin for random melody generation.

## Files

- `musegenerator.qml` - the plugin (also installed to
  `~/Documents/MuseScore4/Plugins/`)
- `NOTES.md` - API research notes (verified against MuseScore v4.7.4 sources)
- `tmp/random_notes.qml` - third-party reference plugin

## Usage

1. **Restart MuseScore after editing the plugin.** "Reload plugins" does
   NOT pick up content changes (the persistent QML engine caches the
   compiled component - see NOTES.md). A full restart is required.
2. Enable "MuseGenerator" in the Plugin Manager if needed.
3. Open or create a score (a simple lead sheet / treble staff works best).
4. Select one or more bars (click first bar, Shift+click last bar).
5. Run Plugins -> MuseGenerator. The dialog shows the detected key
   signature and lets you set the pitch range:
   - Bottom note / Top note: spelled per the key signature (e.g. Eb3, F#4).
     Defaults to E1 - E3.
   - Include 16th notes (off by default): when on, sixteenth-note durations
     are added to the rhythm pool alongside the default whole/half/quarter/
     eighth notes.
   Syncopation is controlled: long notes rarely start on a 16th off-beat
   (e/a), so 16ths mostly appear as beamed pairs closing the beat, and
   long-note syncopation on the "and" is reduced. Both levels are tunable
   constants in the source (`syncopationFactor`, `offbeatLongFactor`).
6. Click "Generate". Expected: the selected bars on voice 1 of the top
   selected staff are replaced with a random melody of notes diatonic to the
   key signature within the chosen range, with mixed rhythms and occasional
   rests. Melodic motion favours small intervals (mostly steps, occasional
   leaps) and never jumps more than one octave. After a leap of a fifth or
   more the melody tends to turn back in the opposite direction (a classic
   counterpoint rule), though it can occasionally continue the same way.
   The status line reports the number of candidate pitches.
7. The dialog closes automatically, then MuseScore's "Regroup rhythms" tool
   is run on the target range so the generated rhythms/rests follow notation
   convention (e.g. a note starting on an off-beat is split/tied across
   beats). The regroup must run after the dialog closes because notation
   actions are gated by UI context - see NOTES.md.
8. About 1 note in 10 is chromatically altered by a semitone. As in standard
   notation, an accidental then applies to later notes of the same pitch for
   the rest of that bar, and resets at the next bar line - useful for
   sight-reading practice. Altered notes stay within the chosen range and
   never use E#/B#/Fb/Cb spellings.
9. Ctrl+Z undoes (generation and regroup are two undo steps, so one Ctrl+Z
   reverts the regroup, a second reverts the generation).

No range selected? The plugin falls back to filling from the current
note-input position to the end of the score.

## Known limitations

- Only voice 1 of the first selected staff is filled.
- The last note may spill slightly past the selection end if its duration
  overshoots the boundary.
- Key signature is read at the selection start; mid-selection key changes
  are not tracked.
- Syncopation control assumes a quarter-note beat (2/4, 3/4, 4/4); compound
  time (6/8 etc.) is not handled correctly.
- Transposing instruments untested (written key vs concert key mismatch is
  possible).
- `Math.random()` - not seedable, so results are not reproducible.

See NOTES.md for next-step ideas (scale/key awareness, seeded PRNG,
multi-staff, per-voice generation, preserving existing content).
