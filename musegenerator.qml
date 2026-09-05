//===========================================================================
// MuseGenerator - random melody generation in selected bars
//
// A MuseScore Studio 4.7 plugin.
// Generates a random melody diatonic to the score's key signature,
// within a configurable pitch range, and inserts it into the selected
// bars via the note-input cursor API.
//===========================================================================

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import MuseScore 3.0

MuseScore {
    id: root

    menuPath: "Plugins.MuseGenerator"
    title: "MuseGenerator v0.18.0"
    version: "0.18.0"
    description: "Fills the selected bars with a random melody diatonic to the key signature."
    categoryCode: "composing-arranging-tools"
    pluginType: "dialog"
    requiresScore: true

    width: 460
    height: 380

    // ------------------------------------------------------------------
    // Pitch / scale model
    // ------------------------------------------------------------------

    // keySig is the circle-of-fifths value from Cursor.keySignature (-7..+7).
    // The major tonic pitch class is (7 * keySig) mod 12.
    readonly property var majorKeyNames: ["Cb","Gb","Db","Ab","Eb","Bb","F","C","G","D","A","E","B","F#","C#"]
    readonly property var minorKeyNames: ["Ab","Eb","Bb","F","C","G","D","A","E","B","F#","C#","G#","D#","A#"]

    // Durations as fractions of a whole note. `w` is the base weight (higher
    // = more frequent). The base set is used always; sixteenths are appended
    // when the "include 16th" checkbox is on.
    readonly property var baseDurations: [
        { num: 1, den: 4, w: 3 },
        { num: 1, den: 8, w: 3 },
        { num: 1, den: 2, w: 1 },
        { num: 1, den: 1, w: 1 }
    ]
    readonly property var sixteenthDurations: [
        { num: 1, den: 16, w: 3 }
    ]

    // Syncopation control. Each candidate duration is weighted down based on
    // the cursor's position within the beat (assumed to be a quarter note):
    // - on "e"/"a" (a 16th off-beat): durations longer than a 16th are
    //   multiplied by `syncopationFactor` (lower = less 16th syncopation).
    // - on the "and" (8th off-beat): durations longer than an 8th are
    //   multiplied by `offbeatLongFactor` (mild suppression).
    // Set a factor to 0 to forbid that case entirely, 1 for no suppression.
    // NOTE: assumes a quarter-note beat (correct for 2/4, 3/4, 4/4; not for
    // compound time like 6/8).
    readonly property double syncopationFactor: 0.1
    readonly property double offbeatLongFactor: 0.3

    readonly property var sharpNames: ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    readonly property var flatNames:  ["C","Db","D","Eb","E","F","Gb","G","Ab","A","Bb","B"]

    // Spell a MIDI pitch as e.g. "Eb3" (C4 = middle C = 60)
    function noteName(pitch, useFlats) {
        var names = useFlats ? flatNames : sharpNames
        return names[pitch % 12] + (Math.floor(pitch / 12) - 1)
    }

    function randomInt(min, max) {
        // both inclusive
        return Math.floor(Math.random() * (max - min + 1)) + min
    }

    // Position of `pos` (a Fraction, whole-note units) within a quarter-note
    // beat, as a Fraction in [0, 1/4).
    function beatPosition(pos) {
        var quarter = fraction(1, 4)
        var pos16 = Math.round(pos.dividedBy(fraction(1, 16)).real)
        var q16 = Math.round(quarter.dividedBy(fraction(1, 16)).real)   // = 4
        return fraction(pos16 % q16, 16)
    }

    // Weight multiplier for a duration starting at beat position `pos16`
    // (a Fraction of a whole note within the beat).
    function onsetWeight(dur, pos16) {
        var eighth = fraction(1, 8)
        var sixteenth = fraction(1, 16)
        var onEighthGrid = pos16.equals(sixteenth.times(2))   // the "and"
        var onSixteenthGrid = !pos16.equals(fraction(0, 1)) && !onEighthGrid
        var durF = fraction(dur.num, dur.den)
        if (onSixteenthGrid && durF.greaterThan(sixteenth)) {
            return syncopationFactor
        }
        if (onEighthGrid && durF.greaterThan(eighth)) {
            return offbeatLongFactor
        }
        return 1
    }

    // Pick a duration, weighting down choices that would start on a weak
    // subdivision (see syncopationFactor / offbeatLongFactor).
    // `pos` is the current cursor position (Fraction, whole-note units).
    function randomDuration(pos) {
        var set = includeSixteenthsCheck.checked
                  ? baseDurations.concat(sixteenthDurations)
                  : baseDurations
        var pos16 = beatPosition(pos)
        var weights = []
        var total = 0
        for (var i = 0; i < set.length; i++) {
            var w = set[i].w * onsetWeight(set[i], pos16)
            weights.push(w)
            total += w
        }
        if (total <= 0) {
            // Fully suppressed (both factors 0 and we're off-grid): fall back
            // to a 16th to close the beat and get back on the grid.
            return { num: 1, den: 16 }
        }
        var r = Math.random() * total
        for (var i = 0; i < weights.length; i++) {
            r -= weights[i]
            if (r <= 0) {
                return set[i]
            }
        }
        return set[set.length - 1]
    }

    // Weight per melodic interval size, in diatonic steps (0 = unison,
    // 1 = step, 2 = third, ...). Smaller intervals are favoured, which
    // gives mostly stepwise motion with occasional leaps.
    readonly property var intervalWeights: [6, 10, 6, 4, 3, 2, 1, 1]

    // Hard limit on the size of any single melodic jump.
    readonly property int maxIntervalSemitones: 12

    // Counterpoint "leap resolves by step in the opposite direction" rule.
    // A leap of this size or larger (semitones) triggers the rule: a perfect
    // fifth = 7 semitones.
    readonly property int leapThresholdSemitones: 7
    // Weight multiplier applied to candidates that move opposite to the leap
    // direction. 3 = reversal is ~3x as likely as it would otherwise be, so
    // continuation in the leap's direction still happens, just less often.
    readonly property int leapResolutionBoost: 3

    // Chance that a sounded note triggers a chromatic alteration of its
    // pitch class by one semitone. Following notation convention (and good
    // sight-reading practice), an accidental introduced in a bar applies to
    // every later note of the same pitch in that bar, and resets at the next
    // bar line - so each altered pitch class marks several notes. Measured
    // on the default range: 0.06 here yields ~10% of notes carrying an
    // accidental (0.10 would yield ~16%).
    readonly property double accidentalProbability: 0.06

    // Apply the chromatic-accidental logic to a diatonic pitch.
    // - If this pitch class was already altered earlier in the bar, reuse
    //   that same alteration (accidentals persist within a bar).
    // - Otherwise, with probability `accidentalProbability`, shift it by one
    //   semitone (up or down), record it for the rest of the bar, and return.
    // Keeps the result within [low, high] and avoids double alterations and
    // enharmonics that read badly for sight-reading (E#, B#, Fb, Cb).
    function applyAccidental(pitch, low, high, barAlterations) {
        var pc = pitch % 12
        if (barAlterations.hasOwnProperty(pc)) {
            var shifted = pitch + barAlterations[pc]
            return (shifted >= low && shifted <= high) ? shifted : pitch
        }
        if (Math.random() >= accidentalProbability) {
            return pitch
        }
        // Choose a direction that stays in range and yields a natural
        // note name (not E#/B#/Fb/Cb). pc+1 lands on F or C (= E#, B#);
        // pc-1 lands on E or B (= Fb, Cb).
        var canUp = (pitch + 1 <= high) && (pc !== 4 && pc !== 11)
        var canDown = (pitch - 1 >= low) && (pc !== 5 && pc !== 0)
        var offset
        if (canUp && canDown) {
            offset = (Math.random() < 0.5) ? 1 : -1
        } else if (canUp) {
            offset = 1
        } else if (canDown) {
            offset = -1
        } else {
            return pitch   // no valid alteration for this note
        }
        barAlterations[pc] = offset
        return pitch + offset
    }

    // Pick the index of the next note in `pitches` (a sorted diatonic pitch
    // array, so index distance == diatonic steps), weighted towards small
    // intervals from the note at `prevIndex` and clamped to one octave.
    // `leapDirection` is the direction (+1 up, -1 down, 0 none) of the leap
    // that landed on the current note; if the rule applies, candidates in
    // the opposite direction are boosted.
    function pickNextIndex(pitches, prevIndex, leapDirection) {
        var weights = []
        var total = 0
        for (var i = 0; i < pitches.length; i++) {
            var semitones = Math.abs(pitches[i] - pitches[prevIndex])
            var w = 0
            if (semitones <= maxIntervalSemitones) {
                var steps = Math.abs(i - prevIndex)
                w = steps < intervalWeights.length ? intervalWeights[steps] : 1
                var direction = (i > prevIndex) ? 1 : ((i < prevIndex) ? -1 : 0)
                if (leapDirection !== 0 && direction === -leapDirection) {
                    w *= leapResolutionBoost
                }
            }
            weights.push(w)
            total += w
        }
        var r = Math.random() * total
        for (var i = 0; i < weights.length; i++) {
            r -= weights[i]
            if (r <= 0) {
                return i
            }
        }
        return weights.length - 1
    }

    // All MIDI pitches in [low, high] that are diatonic to the given key
    // signature. Uses the key signature's accidental set directly (the major
    // diatonic collection for that key sig), which covers both the major key
    // and its relative minor identically.
    function diatonicPitchesInRange(low, high, keySig) {
        var tonic = ((7 * keySig) % 12 + 12) % 12
        var steps = [0, 2, 4, 5, 7, 9, 11]   // major diatonic collection
        var pitches = []
        for (var p = low; p <= high; p++) {
            var rel = (((p - tonic) % 12) + 12) % 12
            if (steps.indexOf(rel) >= 0) {
                pitches.push(p)
            }
        }
        return pitches
    }

    // ------------------------------------------------------------------
    // Score interaction
    // ------------------------------------------------------------------

    // Returns { start, end, keySig, staff, fallback } or null. With a range
    // selection we fill the selected bars; otherwise we fill from the
    // score's note-input cursor to the end of the score. `staff` is the
    // staff index the generation targets (used to re-select for regrouping).
    function getTargetRange() {
        var sel = curScore.selection
        var probe = curScore.newCursor()
        var end = curScore.lastMeasure.tick.plus(curScore.lastMeasure.ticks)

        if (sel.isRange && sel.startSegment) {
            probe.rewind(Cursor.SELECTION_START)   // also sets track to first selected staff
            if (!probe.segment) {
                return null
            }
            return {
                start: sel.startSegment.fraction,
                // endSegment is excluded, null if selection runs to score end
                end: sel.endSegment ? sel.endSegment.fraction : end,
                keySig: probe.keySignature,
                staff: probe.staffIdx,
                fallback: false
            }
        }

        // Fallback: no range selected - use the score's note-input state.
        probe.inputStateMode = Cursor.INPUT_STATE_SYNC_WITH_SCORE
        if (!probe.segment) {
            return null
        }
        return { start: probe.fraction, end: end, keySig: probe.keySignature,
                 staff: probe.staffIdx, fallback: true }
    }

    function keyDescription(keySig) {
        return majorKeyNames[keySig + 7] + " major / "
               + minorKeyNames[keySig + 7] + " minor"
    }

    // Advance the melodic contour state and return the pitch for the next
    // sounded note (with accidental logic applied).
    function pickPitch(state, pitches, low, high, barAlterations) {
        var nextIndex = (state.prevIndex < 0)
                        ? randomInt(0, pitches.length - 1)   // first note: uniform
                        : pickNextIndex(pitches, state.prevIndex, state.leapDirection)
        var semitones = (state.prevIndex < 0)
                        ? 0
                        : Math.abs(pitches[nextIndex] - pitches[state.prevIndex])
        state.leapDirection = (semitones >= leapThresholdSemitones)
                              ? ((nextIndex > state.prevIndex) ? 1 : -1)
                              : 0
        state.prevIndex = nextIndex
        return applyAccidental(pitches[state.prevIndex], low, high, barAlterations)
    }

    function generateMelody() {
        var low = bottomNoteCombo.currentIndex
        var high = topNoteCombo.currentIndex
        if (low > high) {
            statusLabel.text = "Bottom note is above top note - adjust the range."
            return
        }

        var range = getTargetRange()
        if (!range) {
            statusLabel.text = "Select some bars first (or click a note to place the input cursor)."
            return
        }

        var pitches = diatonicPitchesInRange(low, high, range.keySig)
        if (pitches.length === 0) {
            statusLabel.text = "No diatonic notes inside the selected range."
            return
        }

        var cursor = curScore.newCursor()
        cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT
        cursor.rewindToFraction(range.start)

        curScore.startCmd("MuseGenerator: generate random melody")
        var state = { prevIndex: -1, leapDirection: 0 }   // melodic contour
        var currentBarTick = -1  // tick identifying the bar we are writing in
        var barAlterations = {}  // pitch class -> semitone offset, for the current bar
        while (cursor.fraction.lessThan(range.end)) {
            // Reset the per-bar accidental memory when we cross a bar line.
            var barTick = cursor.measure ? cursor.measure.tick.ticks : -1
            if (barTick !== currentBarTick) {
                currentBarTick = barTick
                barAlterations = {}
            }

            var d = randomDuration(cursor.fraction)
            cursor.setDuration(d.num, d.den)
            if (Math.random() < 0.15) {
                // A rest does not break the melodic contour - the next note
                // is still chosen relative to the last sounded note.
                cursor.addRest()
            } else {
                cursor.addNote(pickPitch(state, pitches, low, high, barAlterations))
            }
        }
        curScore.endCmd()

        // Stash the range for the deferred regroup, then close the dialog.
        pendingStartTicks = range.start.ticks
        pendingEndTicks = range.end.ticks
        pendingStaff = range.staff

        // "Regroup rhythms" is a notation action gated on the notation UI
        // context, which is not current while this (modal, always-on-top)
        // plugin dialog is open - dispatching it now yields "no one can
        // handle the action". So close the dialog and defer the command to
        // the next event-loop tick, once the notation context is restored.
        quit()
        regroupTimer.start()
    }

    // Range captured by generateMelody() for the deferred regroup step.
    property int pendingStartTicks: 0
    property int pendingEndTicks: 0
    property int pendingStaff: 0

    Timer {
        id: regroupTimer
        interval: 0
        repeat: false
        onTriggered: {
            // Re-select the target range (note input collapses the
            // selection). selectRange uses tick ints; endStaff is exclusive.
            curScore.selection.selectRange(pendingStartTicks, pendingEndTicks,
                                           pendingStaff, pendingStaff + 1)
            cmd("reset-groupings")
        }
    }

    onRun: {
        console.log("[musegenerator] onRun fired, building note-name model")
        // Read the key signature first so note names are spelled with
        // sharps or flats to match.
        var range = getTargetRange()
        var useFlats = range && range.keySig < 0

        var names = []
        for (var p = 0; p < 128; p++) {
            names.push(noteName(p, useFlats))
        }
        bottomNoteCombo.model = names
        topNoteCombo.model = names
        bottomNoteCombo.currentIndex = 28   // E1
        topNoteCombo.currentIndex = 52      // E3
        console.log("[musegenerator] note-name model built: " + names.length + " entries")

        if (range) {
            keySigLabel.text = "Key signature: " + keyDescription(range.keySig)
            if (range.fallback) {
                statusLabel.text = "Note: no range selected - generation will start "
                                   + "at the current input position."
            }
        } else {
            keySigLabel.text = "Key signature: unknown"
        }
        console.log("[musegenerator] v0.18.0 onRun done, keySig=" + (range ? range.keySig : "n/a"))
    }

    // ------------------------------------------------------------------
    // UI
    // ------------------------------------------------------------------

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Select the bars you want to fill, then click Generate. "
                  + "Notes are diatonic to the key signature, within the range below. "
                  + "Rhythms are regrouped to notation convention. "
                  + "The dialog closes after generation."
        }

        Label {
            id: keySigLabel
            font.bold: true
        }

        GridLayout {
            columns: 2
            Layout.fillWidth: true
            columnSpacing: 10
            rowSpacing: 8

            Label { text: "Bottom note" }
            ComboBox {
                id: bottomNoteCombo
                Layout.fillWidth: true
            }

            Label { text: "Top note" }
            ComboBox {
                id: topNoteCombo
                Layout.fillWidth: true
            }
        }

        CheckBox {
            id: includeSixteenthsCheck
            text: "Include 16th notes"
            checked: false
        }

        Item { Layout.fillHeight: true }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Button {
                Layout.fillWidth: true
                text: qsTr("Generate")
                onClicked: generateMelody()
            }
            Button {
                Layout.fillWidth: true
                text: qsTr("Close")
                onClicked: quit()
            }
        }

        Label {
            id: statusLabel
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: "#a05000"
        }
    }
}
