# Roto-Control: what this project relies on

This is a working reference for the parts of Melbourne Instruments' Roto-Control protocol that
Performance Bridge uses, with the evidence for each statement. It is written in this project's own
words; it is not a copy of Melbourne Instruments' documentation. The `RotoControl` library
implements it.

**Sources.** Melbourne Instruments publishes the protocol and its own DAW integrations in
[Melbourne-Instruments/roto_control](https://github.com/Melbourne-Instruments/roto_control)
(commit 2d43a72, read 2026-10-29). The markers below say which part backs a statement:

- **[SysEx doc]**: the "ROTO-CONTROL SYSEX API", version 1.6 (dated 24 July 2026), listed there as matching ROTO-SETUP 3.0.1 to 3.2.0. It is not included in this repository.
- **[Serial doc]**: the "ROTO-CONTROL SERIAL API", version 1.3 (dated 26 November 2025). It is not included in this repository either.
- **[Ableton]**, **[Bitwig]**, **[Logic]**: Melbourne Instruments' integration code for each DAW, in the same repository (`src/ableton/ROTO_CONTROL.py`, `src/bitwig/…`, and `src/logic/config.lua`). Nothing from it is copied here.
- **[Bitwig guide]**: the 6-page "Melbourne Instruments Roto-Control" guide to the Bitwig Studio controller extension, in the same repository (`src/bitwig/src/main/resources/Documentation/…/Roto-Control.pdf`, created 9 November 2025). It is not included in this repository.
- **[manual]**: Melbourne Instruments' Roto-Control user manual, version 1.1.4 (16 April 2025), from their [support page](https://www.melbourneinstruments.com/support). It predates the firmware tested here, so it is used only for the names of the front-panel buttons and screens.
- **[release notes]**: the ROTO-SETUP release notes on the same page: 2.1.0 (28 October 2025), 3.0.1 (15 January 2026), 3.1.0 (23 February 2026), and 3.2.0 (3 June 2026).
- **[test N]**: a test against a Roto-Control, described in section 9 with the firmware version.

A statement with no marker is an inference, and says so.

**Status.** Three tests so far (section 9), with firmware 3.3.0. Section 8 lists what is still
open.

## 1. Two interfaces

- **SysEx and CCs over USB MIDI.** The Roto-Control talks to a DAW in both directions over its USB MIDI port: SysEx for track details, modes, and paging, and control change messages (CCs) for knobs, switches, and meters. [SysEx doc] This is the interface Performance Bridge uses.
- **A serial port.** A separate serial API, over a USB serial port, reads and writes the Roto-Control's stored setups and its mode. [Serial doc] Performance Bridge does not use it so far. A later version might use it to put the Roto-Control into MIX mode at startup.

## 2. SysEx framing and values

- **The frame.** Every SysEx message is `F0 00 22 03 02 <group> <command> <data> F7`. `00 22 03` is Melbourne Instruments' manufacturer ID, and `02` the Roto-Control's device ID. [SysEx doc]
- **Groups.** `0A` holds general commands, `0B` PLUGIN mode, and `0C` MIX mode. [SysEx doc] Performance Bridge uses all three.
- **Numbers.** Bytes are 7-bit, as in all MIDI data.
  - A number that can exceed 127, such as a track index or a track count, takes two bytes, "two 7-bit values". [SysEx doc] The high seven bits come first. [Ableton, Bitwig]
  - An RGB color component (0–255) takes two bytes the same way: bit 7 first, then the low seven bits. [Logic]
- **Names.** A name is 13 bytes of ASCII, ending in a 0 byte and padded with 0 bytes. [SysEx doc] That leaves 12 visible characters. Ableton cuts names to 12 characters, and clears the top bit of each byte of a value string. [Ableton] Performance Bridge replaces anything outside printable ASCII with `?`; that choice is this project's.
- **Pacing.** Ableton waits 5 ms after each SysEx message it sends. [Ableton] The SysEx doc says nothing about pacing. With no pause at all, the Roto-Control took a full track page and a full plugin page without losing a message. [test 3] `RotoControl` leaves pacing to the transport.

## 3. The handshake

1. The host sends DAW STARTED (`0A 01`) when it starts, and then sends nothing more until the Roto-Control pings it. [SysEx doc]
2. The Roto-Control sends PING DAW (`0A 02`). It does so after DAW STARTED, and also when it is plugged into a computer. It repeats the ping every second for a minute while it looks for a host. [SysEx doc]
3. The host answers with DAW PING RESPONSE (`0A 03 <type>`), naming its DAW: `01` Ableton Live, `02` Bitwig Studio, or `03` Logic Pro. The SysEx doc lists no other type. [SysEx doc]
4. The Roto-Control sends ROTO-DAW CONNECTED (`0A 0C`). Only then may the host send other commands. [SysEx doc]

After CONNECTED, Ableton sends its track information and the meter thresholds. [Ableton] Bitwig
asks for the Roto-Control's firmware version (`0A 0D`). [Bitwig]

**Which type to claim.** Performance Bridge has to claim to be one of the three DAWs. Ableton's
integration answers `01`, Bitwig's `02`, and Logic's `03`. [Ableton, Bitwig, Logic] Some of the
Roto-Control's behavior depends on the type:

- With Logic, the Roto-Control sends page-left and page-right commands in MIX mode while a single track is in focus, expects transport status as CCs instead of SysEx, and reserves CCs 81–127. [SysEx doc] Ableton's code handles the two page commands anyway. [Ableton]
- Between Ableton and Bitwig, the SysEx doc names differences only in PLUGIN mode (two fields the Roto-Control ignores for Ableton), and none in MIX mode or in the general commands. [SysEx doc] In use they differ in MIX mode too [test 3]:
  - With `01`, level knobs have a 0 dB indent at 13926 (0.85 of the range, where Live puts 0 dB), and the Roto-Control sends CC 64 when a knob lands in it (section 5). With `02` there is no indent at 13926 and no CC 64 [test 3]; there is an indent lower down, felt where a TotalMix fader reads "-0.8 dB", about 0.79 of the range (seen, 2026-10-30, with `sbdev bridge`). The inference is that it is Bitwig's 0 dB, which on a volume law of twice the cube of the position is at 0.5 raised to 1/3, 0.794 (count 13003); that law is from memory of Bitwig, not from Melbourne Instruments' code, and the exact position is not yet measured. With `RotoDriver`'s scale bent to put 0.794 at TotalMix's 0 dB (below), the indent was felt at 0.0 dB (seen, 2026-10-30), which fits the inferred position to within what a hand can feel. The indent caught the knob at 0 dB reliably (seen).

**A firmer indent.** Neither the SysEx API (1.6) nor the serial API (1.3) has a setting for how strongly an indent holds; they set only where indents are (for MIDI-mode setups and PLUGIN-mode controls). [SysEx doc, Serial doc] A "magnet" was tried on 2026-10-30 with `sbdev bridge`: once a level knob had sent nothing for 200 ms within a window of the indent, the host moved it into the indent and set 0 dB. It pulled nothing while the knob was being turned, only moved it afterward (seen: visible from about −6 dB, hard to see from −3 dB), so it felt like a delayed jump rather than a firmer indent, and it would move a knob left near 0 dB on purpose. It was removed.
  - With `01`, switches send 0 on release as well as 127 on press; with `02`, nothing on release.
  - The solo color differs: yellow with `02`, blue with `01` (seen).
- With `03`, PLUGIN mode never settled with the Bitwig-style replies `sbdev` sends: the Roto-Control sent SET PLUGIN MODE again about every 200 ms (section 4a). [test 3]

The handshake itself, MIX mode's messages, and the stored PLUGIN-mode mappings were the same
with `01` and `02`. [test 3] Neither type's indent is at TotalMix's 0 dB, which is at 0.817 of the
range: `01`'s, at 0.85, would read about +1.1 dB on a TotalMix fader, and `02`'s about −0.8 dB.
`RotoDriver` therefore bends the scale of level and send knobs, linearly on each side of the
indent, so that the indent is TotalMix's 0 dB. The inference is that `02` suits Performance Bridge
better: no CC 64 to ignore, and switches that give the same press messages without release
messages. `RotoHandshake` takes the type as a setting.

**Reconnecting.** The SysEx doc does not say what a host should do if the Roto-Control pings again
after CONNECTED. The inference is that the Roto-Control was restarted or plugged in again, so
`RotoHandshake` answers the ping and waits for CONNECTED again.

## 4. MIX mode

The Roto-Control drives MIX mode, and the host answers.

**From the Roto-Control:**

| Command | Bytes | What it means |
|---|---|---|
| SET MIX ALL TRACKS MODE | `0C 01 <set> <knobs> <switches> <send>` | All-tracks mode: eight tracks, one per knob. `set` is audio tracks (`00`) or master and return tracks (`01`). `knobs` is level (`00`), pan (`01`), or a send (`02`). `switches` is mute (`00`), solo (`01`), or record arm (`02`). `send` is the 0-based send the knobs control in send mode. |
| SET MIX TRACK MODE | `0C 02 <page>` | Single-track mode: the controls of one track, in pages of eight. `page` is a page number (0, 1, 2), not the multiple of 8 the SysEx doc gives [test 2]; see "Single-track pages" below. |
| SET ALL TRACKS MODE | `0C 05 <set>` | The user switched between audio and master/return tracks. |
| SET FIRST TRACK | `0A 06 <first:2>` | The user paged the tracks; `first` is a multiple of 8. |
| ROTO SELECT TRACK | `0A 09 <index:2>` | The user selected a track. |
| TOGGLE TRACK GROUPING | `0C 06 <index:2>` | The user toggled grouping on the selected track. |
| REQUEST SEND TRACK NAMES | `0C 07 <send>` | The host should send the block of eight send names that holds `send`. |
| REQUEST TRANSPORT STATUS | `0A 0A` | The host should send TRANSPORT STATUS. |

All of these are from the SysEx doc.

**To the Roto-Control:**

| Command | Bytes | What it does |
|---|---|---|
| NUM TRACKS | `0A 04 <count:2>` | The number of tracks in the current set. |
| FIRST TRACK | `0A 05 <first:2>` | The current track page; `first` is a multiple of 8. |
| TRACK DETAILS | `0A 07 <index:2> <name:13> <scheme> <grouped>` | One track of the current page, followed after the page's tracks by TRACK DETAILS END (`0A 08`). |
| SET TRACK DETAILS | `0A 11 …` | As TRACK DETAILS, shown at once. |
| RESET TRACK DETAILS | `0A 12 <index:2>` | Clears a track's screen at once. |
| SET TRACK COLOUR | `0A 13 <index:2> <r:2> <g:2> <b:2>` | A track's color as RGB. |
| SHOW CONTROL VALUE | `0A 18 <kind> <control> <text:13>` | Shows a value on a knob's (`kind` `00`) or switch's (`01`) screen; the screen goes back to the control's name after a timeout. A switch's value has not been seen to show (section 6). |
| TRANSPORT STATUS | `0A 0B <eight flags>` | Play, stop (always off), record, session record, loop, punch-in, punch-out, and re-enable automation, each `00` or `01`. |
| NUM SEND TRACKS | `0C 03 <count>` | The number of sends. |
| DAW SELECT TRACK | `0C 04 <index:2> <name:13> <scheme> <grouped>` | The host selected a track. |
| SEND TRACK NAMES | `0C 08 <start> <8 names>` | Eight send names, from `start`; a missing name is all 0 bytes. |
| REFRESH MIX MODE | `0C 09` | Asks the Roto-Control to redraw MIX mode. |
| DAW SELECT FOCUS TRACK | `0C 0A <index:2> <r:2> <g:2> <b:2>` | Selects the focus track, with its color. |
| SET MIX VU METER THRESHOLDS | `0C 0B <yellow> <red>` | Where the meters turn yellow and red, each 0–127; red must be above yellow. |

All of these are from the SysEx doc. `scheme` is an index (0–82) into the Roto-Control's color
table (the SysEx doc's Appendix A, not reproduced here), and `grouped` is `00` or `01`.

- **Single-track pages.** Ableton and Bitwig both put level on knob 1, pan on knob 2, and the first six sends on knobs 3–8 of the first page, and eight sends on each later page. [Ableton, Bitwig] They differ from the SysEx doc on how the page is numbered:
  - The SysEx doc says `page` is a multiple of 8 (0, 8, 16, …). [SysEx doc]
  - Ableton and Bitwig both treat it as a page number (0, 1, 2, …). With a multiple of 8, Ableton's arithmetic would point far past the sends. [Ableton, Bitwig]

  The Roto-Control sends page numbers. [test 2] `RotoOutgoing.sendNamesStart(forControlPage:numbering:)` handles both readings; drivers use `.pageNumbers`.
- **Which send names to send.** After SET MIX ALL TRACKS MODE or REQUEST SEND TRACK NAMES, the block starts at the multiple of 8 at or below the send index. [SysEx doc] After SET MIX TRACK MODE, the SysEx doc's examples (pages 0, 8, and 16 start at sends 0, 6, and 14) fit a block that starts at the page index minus 2, and at 0 for page 0. [SysEx doc] Read as page numbers, the same layout starts at 0 for page 0 and at 6 + (page − 1) × 8 after that, as in Ableton's code [Ableton], and that reading is the one the Roto-Control uses. [test 2]
- **When the screens are drawn.** The Roto-Control draws a single track's send labels when it gets DAW SELECT TRACK, not when it gets SEND TRACK NAMES; so after every SET MIX TRACK MODE the host sends the names, then DAW SELECT TRACK. On returning to all-tracks mode, the track screens are blank until the host sends the page again (NUM TRACKS, FIRST TRACK, and TRACK DETAILS). [test 2] Bitwig's code sends DAW SELECT TRACK on a single-track page change. [Bitwig]
- **What draws the strips.** After a power cycle, the strips stay blank until the host sends NUM TRACKS, TRACK DETAILS, and TRACK DETAILS END; nothing shows before END, and TRACK DETAILS and END without NUM TRACKS show nothing. FIRST TRACK was not needed for the first page (the inference is that it starts at 0). [test 3]
- **Strips outlast the host.** Left in MIX mode between the host quitting and a new handshake, the Roto-Control keeps the strips it was last sent: track 1's name and color, sent in one run, still showed in the next. A power cycle clears them, and so does switching to another mode and back (test 2). [test 2, test 3] So a host should send all eight strips on every connection, blanking any it does not use.
- **Track colors.** The color scheme in TRACK DETAILS sets each strip's color, and the SysEx doc's table gives the colors seen. [test 2]
- **Meter thresholds.** Ableton uses 87 and 113; Logic 106 and 120. [Ableton, Logic]
- **Meter dimming.** Ableton also sends `0C 0C` with eight bytes, one per track of the page, which the SysEx doc does not list. Ableton sends 1 for an unmuted track and 0 for a muted one, or, while any track is soloed, 1 for soloed tracks and 0 for the rest. [Ableton] The inference is that 0 dims a track's meter. `RotoControl` can send it, marked as undocumented.

## 4a. PLUGIN mode

In PLUGIN mode the host lists "plugins" (Ableton's devices), and the user maps the Roto-Control's
controls to their parameters. The Roto-Control stores each mapping on the device, under a hash of
the plugin and a hash of the parameter. [SysEx doc, Ableton] Performance Bridge could present parts
of TotalMix as plugins, for example the control room or the selected channel's EQ; that use is
this project's idea, not Melbourne Instruments'.

**The flow, as Ableton's integration runs it** [Ableton]:

1. The Roto-Control sends SET PLUGIN MODE (`0B 01`). Ableton first sends the track page (NUM TRACKS, FIRST TRACK, TRACK DETAILS), then answers with NUM PLUGINS (`0B 02`), FIRST PLUGIN (`0B 03`), a PLUGIN DETAILS (`0B 05`) for each plugin on the page, PLUGIN DETAILS END (`0B 06`), and DAW SELECT PLUGIN (`0B 08`).
2. When the user selects a plugin, the Roto-Control sends ROTO SELECT PLUGIN (`0B 07`, the index on the page).
3. For each control it has a mapping for on that plugin, the Roto-Control sends CONTROL MAPPED (`0B 0B`) with the parameter's index and hash. The host finds the parameter (by hash; by index when two share a hash) and answers with LEARN PARAM (`0B 0A`), which carries the parameter's name and position. From then on the control's CCs (section 5) change that parameter. Ableton answers this way only for knobs, unless the parameter is a macro; the SysEx doc says to answer every CONTROL MAPPED, and `sbdev` does, for switches too, without visible harm. [Ableton, SysEx doc, test 2]
4. To make a mapping, the user turns on learn mode (the Roto-Control sends SET DEVICE LEARN (`0B 09`) on) and moves a control, whose screen shows LEARNING. For a knob, turning starts learning and touch alone does not. [test 3] The parameter is then chosen in the DAW, the host sends LEARN PARAM, and the Roto-Control answers with CONTROL LEARNED (`0B 11`). [Bitwig guide, test 2] Ableton sends LEARN PARAM whenever a parameter is selected while learn mode is on. [Ableton]

**What a parameter can carry** (LEARN PARAM) [SysEx doc]:

- a name, and a position (14 bits);
- a center detent, for knobs;
- or a number of steps: the SysEx doc gives 0 (continuous) or `02`–`18` hex, so 2–24, and names for each step when there are no more than `10` hex (16) steps. Ableton's integration caps steps at 24 and step names at 16 [Ableton], which agrees.

**Hashes.** A plugin's hash is 8 bytes and a parameter's 6, each byte 7-bit. [SysEx doc] Ableton
takes them from SHA-1 digests of the device's and parameter's names. [Ableton] The inference is
that the Roto-Control uses them only as names for stored mappings, so any stable hash will do;
`RotoHash.of` uses FNV-1a.

**Host-set control names.** SET PLUGIN CONTROL DETAILS (`0B 13`) names a control (0–63) and sets
its color, without learning. The SysEx doc says it is normally used in Logic's SMART mode. Whether
it works with another DAW type is open (section 8): with type `02` it named nothing (test 2), and
with type `03` PLUGIN mode never settled (test 3).

**What test 2 found** (type `02`) [test 2]:

- PLUGIN DETAILS and this project's hashes are accepted: holding SEL shows the plugin names, and selecting one sends ROTO SELECT PLUGIN.
- An unmapped control sends its touch CC and nothing else, and SET PLUGIN CONTROL DETAILS does not name it. Every control has to be learned before it does anything.
- Learning works in the order the Bitwig guide gives: LEARN, then the control (its screen shows LEARNING), then LEARN PARAM from the host. CONTROL LEARNED came back 44–161 ms after LEARN PARAM. While learn mode is on, touching a knob sent no touch CC. (Test 2 recorded "touches"; test 3 found that turning is what counts.)
- On leaving learn mode, and after the host selects a plugin with mappings (DAW SELECT PLUGIN, including after the host restarts), the Roto-Control sends CONTROL MAPPED for every mapped control on the page. Once it also sent them with no message from the host before them (test 2, 235.558 s). The mappings are stored on the Roto-Control.
- A center detent settles the knob at 8191, the middle of the range (the host sent 8192).
- A switch mapped to a stepped parameter steps through the values itself, wrapping round, and sends each step as a share of 0–127: 0 and 127 for two steps; 42, 84, 127, and 0 for four. The step names were not shown; the inference is that the host is expected to show them with SHOW CONTROL VALUE, as Ableton's integration does with its value text. [Ableton]
- Once knob 1 had been learned under one plugin, it would not show LEARNING under another (seen); knob 2 could still be learned there. The inference from test 3 is that this came from touching without turning, not from the existing mapping.

**What test 3 found** (types `02`, `01`, and `03`) [test 3]:

- **Mappings are kept per plugin.** Knob 1 mapped to "Main Vol" under one plugin and to "Freq 1" under another, and knob 2 to "Gain 1" and "Phones 1"; selecting either plugin brought back its own mappings. A control mapped under one plugin was learned under another without UNMAP CONTROL.
- **UNMAP CONTROL clears the screen, not the stored mapping.** After UNMAP CONTROL, knob 1's name disappeared (seen), but selecting the same plugin again brought back CONTROL MAPPED for knob 1, twice out of twice.
- **Learning.** Turning a knob in learn mode showed LEARNING on the first slight turn (knobs 4 and 5), and eight touches without turning did not (seen); a knob turned with a rubber eraser, so not touched, showed LEARNING at once (seen). In learn mode the Roto-Control sent nothing at all while knobs were turned, and nothing says which control shows LEARNING: LEARN PARAM goes to whichever does. Leaving learn mode with a control still showing LEARNING sent nothing about it. CONTROL LEARNED came 40–92 ms after LEARN PARAM. During learning the whole screen belongs to the knob (top half LEARNED, bottom half the parameter name; seen).
- **A knob on a stepped parameter.** Mapped to a parameter with three steps, the knob moved in three haptic steps (seen) and sent only 0, 8191, and 16383. No step names showed, on the knob or, as in test 2, on a switch (seen).
- **SET PLUGIN MODE's data byte** was `00` in all 300 SET PLUGIN MODE messages in the eleven logs of tests 2 and 3, with either of two plugins selected. Its meaning is still unknown.
- **Type `03`.** Claiming Logic, the Roto-Control sent SET PLUGIN MODE 292 times in 61 seconds, every 185–281 ms (median 207 ms), each time after `sbdev`'s plugin page, and never sent CONTROL MAPPED; the screens flickered between the MENU window and screens 1–3 (seen). The inference is that it waits for something Logic's integration sends, such as the undocumented `0B 1E` (section 7).

**What PLUGIN mode lacks.** The meter CCs are listed for MIX mode only, and the per-track screens
and track paging are MIX-mode features. [SysEx doc]

## 5. CCs

All on MIDI channel 16. [SysEx doc] "Knob 1–8" means CC numbers in that order.

| Control | CC (decimal) | Values |
|---|---|---|
| Knobs 1–8 | 12–19 (high 7 bits) and 44–51 (low 7 bits) | 14 bits, 0–16383 |
| Switches 1–8 | 20–27 | 7 bits |
| Transport switches 1–8 | 28–35 | 7 bits |
| Knob touch 1–8 | 52–59 | 127 touched, 0 released |
| Level to 0 dB | 64 | the knob's index |
| Meters, tracks 1–8 | 65–80, in left and right pairs (65 and 66 for track 1) | 7 bits |

The CC numbers, that knobs are 14-bit and switches 7-bit, and the touch values are from the SysEx
doc, which only pairs the knob CCs. That CCs 12–19 carry the high 7 bits and CCs 44–51 the low 7
bits is from Bitwig's and Logic's code. [Bitwig, Logic] The rest:

- **Switch values.** In MIX mode, with type `02`, a switch sends 127 on each press and nothing on release, and changes no state by itself: the host decides the new state and sets the light (section 6). This holds in record-arm, mute, and solo modes. [test 1, test 2, test 3] With type `01` a switch also sends 0 on release, and still changes nothing by itself. [test 3] In PLUGIN mode a switch sends the mapped parameter's value instead (section 4a). [test 2] `RotoControlDecoder` reports the value as sent, and a driver reads it as a press or a value depending on the mode. Bitwig treats 127 as pressed and 0 as released. [Bitwig]
- **Transport switches.** Ableton reads them as play, stop, record, session record, loop, punch-in, punch-out, and re-enable automation. [Ableton] That order matches TRANSPORT STATUS. [SysEx doc] With type `02` the Roto-Control sends them in transport mode, 127 on press and 0 on release, and asks for TRANSPORT STATUS when that mode is entered. [test 2]
- **CCs 36 and 37.** Ableton also listens on these, the two CCs after the transport switches, for rewind and fast-forward. [Ableton, Bitwig] The SysEx doc does not list them. `RotoControl` reports them as other CCs.
- **CC 64.** The Roto-Control sends it, with a knob's index as the value, and Ableton then sets that knob's parameter to its default. [Ableton] The SysEx doc names it "level at 0 dB" without saying what triggers it. With type `01`, in all-tracks level mode, the Roto-Control sent it each time a knob landed in its 0 dB indent: ten times out of ten passes, always with the knob reporting exactly 13926 in the same millisecond, and the knob then said nothing for 32–601 ms. Seen: the indent was too weak to feel. With type `02` there was no CC 64 in 31 passes of knob 1 through 13926 (12 in level mode, 19 in pan mode). [test 3] Melbourne Instruments' release notes add 0 dB indents for volume (3.0.1, Logic) and for volume and send knobs (3.1.0, all three DAWs). [release notes] Sends, and the exact position of the `02` indent (section 3), are untested. CC 64 is therefore a notice that a knob reached the indent, not a reset gesture; a TotalMix driver that claims `02` will not see it.
- **Meters hold.** A meter has been observed to stay where it was set until the host sets it again; the host sends the falls as well as the rises. [test 2]
- **Meter values.** Ableton sends a track's meter as Live's meter reading (0–1) times 127, at most 12 times a second. [Ableton] How Live scales that reading is not in the integration, so the mapping from TotalMix's dB levels to 0–127 is this project's choice, still to be made.

## 6. Feedback to the Roto-Control

- **Moving a knob.** The host sends the same CC pair the knob sends: the high 7 bits on CC 12–19, then the low 7 bits on CC 44–51. [Bitwig, Logic] Bitwig computes the 14-bit value as the parameter (0–1) times 16383, rounded. [Bitwig]
- **Lighting a switch.** The host sends 127 (on) or 0 (off) on the switch's CC. [Ableton] In MIX mode this sets both the light and the label in the bottom half of the switch's screen. With 127 the light comes on in the mode's color and the label shows on that color: "ARM REC" in red; "MUTE" in orange; "SOLO" in yellow with type `02` and blue with type `01`. With 0 the light is off and the label gray. [test 2, test 3; seen] In mute and solo modes the label stays blank until the host first sets the light; "ARM REC" shows from the start. [test 3; seen]
- **Moving a knob.** The motor follows the host's position: 0 dB (13388) put knob 1 at about 3 o'clock, and the range runs from about 7 o'clock (0) to about 5 o'clock (16383), 300° of travel. [test 2]
- **Past the ends.** The knob has no physical stop (seen) [test 2]. Past an end it does one of two things [test 2, test 3]:
  - **Hold.** It goes silent and resists (seen). Forced on, it lets go and reports a position about 3,300–3,700 counts in from the other end, and carries on from there: 13004–13078 from 0, and 3325–3693 from 16383.
  - **Wrap.** It goes silent for 32–1,491 ms with no resistance (seen), reports the other end (0 to 16383, or 16383 to 0), and carries on from there.

  Every one of the 41 end events in the logs of tests 2 and 3 fits this rule: **a knob holds once the host has sent it a position in MIX mode, until the knob mode (level, pan, or send) changes; otherwise it wraps.** Twelve holds and 29 wraps fit; none does not. In particular:
  - the hold outlasted the host quitting and reconnecting, and switching to single-track mode and back (test 2);
  - a position set by LEARN PARAM in PLUGIN mode did not count (test 3);
  - changing the knob mode from level to pan cleared it, and changing back did not restore it (test 3);
  - in one run, a knob the host had not set wrapped while one it had set held (test 3).

  This is an inference from those events; the SysEx doc says nothing about it. The releases from 0, at 13004–13078, sit at the `02` indent's inferred position (13003, section 3), so the knob may let go into its indent; another inference, from that match alone. Test 1's "bounce" (0 to 16383 and back to 0) fits as two wraps, but its log was not kept, so whether the host had set that knob is unknown.

  A driver must therefore send every knob's position after each change of knob mode, and still treat a jump across most of the range as an end event, not as a new level: for a TotalMix fader, 0 to 16383 is off to +6 dB.

  How large a jump is an end event: in the kept logs of tests 2 and 3, a script comparing each knob report with that knob's last found every end event at 12,690 counts or more, and every other report at 2,942 or less, apart from the 8,191- and 8,192-count steps of a stepped knob in PLUGIN mode. `RotoDriver` therefore takes a jump of more than 8,000 counts in MIX mode as an end event, ignores it, and sends the knob back to its last position.
- **Unchanged values.** Bitwig does not resend a knob position it last sent, except that it resends all eight positions when it switches layers or modes. [Bitwig]
- **Value text lasts about 2 seconds** on the screen before the name comes back, as the user timed it. [test 2] It shows on a knob's screen in MIX and PLUGIN modes. On a switch's screen it showed nothing, in either mode, so a switch's state can be shown only by its light and label. [test 3; seen]
- **Value text.** Ableton sends SHOW CONTROL VALUE whenever a mapped parameter's value changes, from the knob or from Live, at most 12 times a second with one trailing update, and once when a knob is touched. [Ableton] Bitwig sends value text only in PLUGIN mode, within 100 ms (plugin parameters) or 300 ms (macro parameters) of the knob last moving; in MIX mode it sends none. [Bitwig]
- **Bitwig's command for value text.** Bitwig sends value text as `0A 0F`, the number the SysEx doc gives REQUEST ROTO SYSEX API VERSION, with the same layout as SHOW CONTROL VALUE. [Bitwig, SysEx doc] The inference is that `0A 0F` is an older form, from before SHOW CONTROL VALUE was documented. `RotoControl` sends `0A 18`, as Ableton and Logic do. [Ableton, Logic]
- **Hold-off for the motors.** Bitwig holds back a knob position for 100 ms after the knob last moved on its master and return layer, and has the same rule commented out on its track layer. While touch automation is on, it also ignores the knob for 500 ms after release, and it queues knob positions while it switches modes. [Bitwig] Ableton leaves knob feedback to Live's framework, so its rule is not visible in the integration. [Ableton] Performance Bridge will need its own rule, because TotalMix confirms nothing (docs/TOTALMIX-OSC.md, test 5): a position from TotalMix is a change made elsewhere. The planned rule, an inference, was to hold back positions for a knob while it is touched; test 1 shows a knob turning before its touch CC, so the rule will also have to count recent movement. Test 3 adds that touches often failed to register at all (seen; a double tap sent nothing), so movement is the more reliable sign. Melbourne Instruments removed the touch-sensitivity setting in 2.1.0. [release notes]

## 7. Errata in the SysEx doc

Noted so that nobody builds on them:

- Two sections are numbered 2.21.
- The PLUGIN headings for 3.26–3.29 use command numbers `20`–`23`, but the overview, and Logic's code, use `1A`–`1D`. [SysEx doc, Logic]
- DAW SELECT TRACK (4.4) shows the color field as `CS` in the command but defines it as `CI`. The field is the color scheme, as in TRACK DETAILS.
- The overview gives ROTO SELECT PLUGIN (`0B 07`) as sent to the Roto-Control, though its name says the Roto-Control selected the plugin; the Roto-Control does send it. [test 2]
- Appendix A writes one green value as "BO" (letter O), presumably `B0`.
- Appendix B's Logic formula for a mapped parameter's CC number divides where Logic's code takes the remainder. [SysEx doc, Logic] PLUGIN mode only.
- In PLUGIN mode, the overview also gives the wrong direction for SET PLUGIN LEARN (`0B 09`) and FIRST PLUGIN (`0B 03`), and 3.26 calls both halves of the sweep value "LSB". Logic's code uses a PLUGIN command, `0B 1E`, that the SysEx doc does not list. [SysEx doc, Logic]

## 8. Open questions

Settled by tests 1–3 (section 9): the handshake with types `01` and `02`; what MIX mode needs from
the host; pacing; the knob CCs; that host moves are not echoed; motor moves; the single-track page
numbering; transport switches; switches and lights in record-arm, mute, and solo modes; CC 64 and
the 0 dB indent with type `01`; the ends of the knob's range (as an inferred rule); and, in PLUGIN
mode, unmapped controls, learning and relearning, stored mappings, UNMAP CONTROL, detents, steps,
and step names.

1. **SET PLUGIN MODE's data byte.** It has always been `00`. Does it change with more than eight plugins (a page number, perhaps)?
2. **Type `03`.** What does the Roto-Control wait for in PLUGIN mode when the host claims Logic, and does SET PLUGIN CONTROL DETAILS work then?
3. **The 0 dB indent.** Where exactly is the `02` indent (inferred 13003)? Do send knobs get one, with `01` and `02`, as the 3.1.0 release notes say? Does `03` get one?
4. **The hold rule.** Does a power cycle clear it? Does anything other than a change of knob mode clear it, such as switching to PLUGIN mode and back? Is the release always about 3,300–3,700 counts in?
5. **The FX label.** With SEL held, screen 3's bottom half shows "FX" under "Send 1" (seen); pressing that switch chooses the send knob mode (test 4), and pressing it again steps through the sends (seen, 2026-10-30). Is "FX" anything more than the label for that button? The SysEx doc names no FX switch mode.

## 9. Tests

Run with `sbdev roto` (macOS), which prints every message in both directions with the time since
starting and takes commands for knobs, lights, meters, screens, and PLUGIN mode. Times of messages
that arrive while `sbdev` is still sending a reply are the times it could read them, not arrival
times.

### Test 1 (2026-10-29): handshake, MIX mode, knobs, and feedback

**Setup.** Roto-Control firmware 3.3.0 (commit `eaa37b0`), SysEx API 1.6, as the Roto-Control
reported them. macOS, one MIDI source and one destination named "Roto-Control". `sbdev roto --raw`
claiming Bitwig (`02`), with the default setup (16 tracks, 4 sends, 5 ms after each SysEx).

**Findings:**

- **The handshake.** DAW STARTED was answered by PING DAW within 1 ms. CONNECTED came within 5 ms of DAW PING RESPONSE; `sbdev` pauses 5 ms after each SysEx inside the MIDI callback, so the log cannot show less. The firmware and API versions came back in one packet, logged at 0.099 s. That is the first moment `sbdev` could read it, after its reply to CONNECTED, so the Roto-Control's own delay is unknown.
- **SET PLUGIN MODE with data.** The Roto-Control sent SET PLUGIN MODE straight after CONNECTED (the inference is that it was in PLUGIN mode), with one data byte (`00`) that the SysEx doc does not list. Bitwig's integration reads one byte there. [Bitwig] Its meaning is unknown.
- **MIX mode.** Switching to MIX mode sent SET MIX ALL TRACKS MODE (audio tracks, level, record arm, send 0). The host's NUM SEND TRACKS and SEND TRACK NAMES drew no error.
- **Touch and select.** Touching a knob sent ROTO SELECT TRACK for its track and then the touch CC, within 1 ms. Release sent the touch CC with 0.
- **Knob CCs.** Every update carried both CCs, high then low, even when the high value had not changed. Updates came about every 11 ms while a knob turned. The values covered 0 to 16383.
- **Touch can trail turning.** Once, knob 1 sent six position updates (27.540 s to 27.747 s) before its touch CC (27.747 s). A rule that holds back positions only while a knob is touched would miss that.
- **The jump to 16383.** Four times (knob 1 once, knob 2 three times), a knob turned down to 0 next reported 16383, 51–122 ms later. Three times it reported 0 again 111–321 ms after that; the fourth time it was released at 16383. See section 6.
- **Switches.** Switches 1 and 2 sent 127 on each press, twice each, and nothing on release, with the switches in record-arm mode.
- **No echo of host moves.** After `knob 1 0dB` and a sweep of knob 1 from 0 to 16383, the Roto-Control sent no CCs back.
- **Not recorded.** Whether the knob moved, the light lit, the meters showed, or "hello" appeared on knob 1's screen. Test 2 repeated these with notes.


### Test 2 (2026-10-29): feedback, single-track mode, transport, and PLUGIN mode

**Setup.** As in test 1 (firmware 3.3.0, `eaa37b0`; type `02`), in four runs of `sbdev roto --raw`
on branch `roto-midi`, the later runs with the changes made during the test (16 sends; send names
and DAW SELECT TRACK on single-track pages; the track page on returning to all-tracks mode). The
user noted what the Roto-Control showed and did; those notes are marked "seen" below. Clock
positions are approximate. Knobs were in pan mode (`0C 01 00 01 02 00`) throughout MIX mode.

**MIX mode:**

- **Track colors** (seen). Schemes 0, 11, 22, 33, 44, 55, 66, and 77 showed as pink, purple, blue, green, brownish gray, gray, royal blue, and red-brown, matching the SysEx doc's table, except that scheme 66 (a purple in the table) looked royal blue.
- **Knob range** (seen). No physical end stop. `sweep 1` took the knob from about 7 o'clock to about 5 o'clock, and `knob 1 0dB` to about 3 o'clock.
- **End stops.** Turned down past 0, the knob held (seen: resistance) and sent nothing. Turned on round, it let go and reported a position near the top. In the third run this happened five times from 0 (13010–13078) and four times from 16383 (3325–3693); for example, knob 1 sat at 0 from 195.236 s and next reported 13026 at 207.057 s. In the first run the knob instead wrapped without holding, ten times: for example, 0 at 20.008 s, then 16383 at 20.200 s and 16346 at 20.981 s.
- **Switches.** In record-arm mode, presses sent 127 and nothing on release. Seen: the screen showed "ARM REC" and a press made the light brighter; a press did not switch arm on or off. `led 1 on` lit the light red and showed "ARM REC" as on; `led 1 off` turned the light off and grayed the label.
- **Meters** (seen). `meter 1 100` filled the yellow part of the meter (thresholds 87 and 113) and the meter stayed there.
- **Value text** (seen). `show 1 hello` showed for about 2 seconds. `name 1 analog 1` renamed track 1's screen.
- **Single-track mode.** With 4 sends claimed, > did not page. With 16, SET MIX TRACK MODE carried 0, 1, and 2 for the three pages (seen: level, pan, and six sends; eight sends; two sends). Send labels showed only after DAW SELECT TRACK; once `sbdev` sent it after the names on every page, they showed on every page (seen). On returning to all-tracks mode the track screens were blank until the page was sent again (seen); once `sbdev` sent it on SET MIX ALL TRACKS MODE, they showed at once (seen).
- **Transport.** Entering transport mode sent REQUEST TRANSPORT STATUS. The eight transport switches sent CCs 28–35, 127 on press and 0 on release, each release 70–90 ms after its press.

**PLUGIN mode:**

- NUM PLUGINS, FIRST PLUGIN, four PLUGIN DETAILS, PLUGIN DETAILS END, and DAW SELECT PLUGIN were sent on SET PLUGIN MODE. Seen: no names on the screens until SEL was held, then the four plugin names.
- `ctl 1 main vol` (SET PLUGIN CONTROL DETAILS) showed nothing (seen); turning unmapped knob 1 sent only its touch CC.
- Learning knob 1 to "Main Vol": LEARN, then touches until LEARNING showed (seen), then `learn 1`; CONTROL LEARNED came 110 ms after LEARN PARAM, and the screen showed LEARNED and "Main Vol" (seen). On leaving learn mode the Roto-Control sent CONTROL MAPPED for knob 1 with this project's parameter hash; after `sbdev`'s LEARN PARAM answer (position 13388), the knob's first reported position was 13522.
- After quitting and restarting `sbdev`, the Roto-Control sent CONTROL MAPPED for knob 1 by itself, 52 ms after DAW SELECT PLUGIN.
- Switch 1 learned to "Dim" (two steps) sent 127, then 0, on successive presses; switch 2 learned to "Main Out" (four steps) sent 42, 84, 127, and 0. Seen: the screen showed the names ("Main Vol | Dim") but no step names, and did not change on a press.
- Under "Ch EQ", knob 1 would not show LEARNING in learn mode (seen), including after turning learn mode off and on three times; knob 2 would. The log has no LEARN PARAM for knob 1 under "Ch EQ". It also has two SET DEVICE LEARN off in a row (369.264 s, 372.545 s). Knob 2 learned to "Gain 1" (center detent) settled at 8191 (seen: a detent at 12 o'clock); the host had sent 8192.

### Test 3 (2026-10-30): the open questions

**Setup.** Firmware 3.3.0 (`eaa37b0`) and SysEx API 1.6, as in tests 1 and 2, with `sbdev roto
--raw` on `main` at `ced6f80`, in seven runs: run 1 claiming Bitwig (`02`) with the default setup;
run 2 claiming Ableton (`01`); run 3 claiming Logic (`03`); runs 4, 4b, and 4c with `--setup none`,
with a power cycle before 4c; and run 5 with `--gap 0`. The counts below come from scripts over
the raw logs of tests 2 and 3, which are kept outside this repository. The user's notes are marked
"seen". On the Roto-Control each knob has a screen below it, shared with its switch: the top half
belongs to the knob and the bottom half to the switch. The screen above the front-panel
buttons is the MENU window. [manual; seen]

**Front panel** (seen):

- FUNC switches MIX mode between all tracks and a single track.
- Holding SEL shows the modes: VOLUME, PAN, and Send 1 in the top halves of screens 1–3 ("FX" under Send 1), and MUTE, SOLO, and ARM in the bottom halves of screens 4–6, the current one lit (MUTE, in orange, when it was current). Releasing SEL sent SET MIX ALL TRACKS MODE with the new modes; holding it sent REQUEST SEND TRACK NAMES for send 0. The modes are kept across host runs and a power cycle.

**Findings:**

- **The handshake** was the same with all three types: CONNECTED 5 ms after DAW PING RESPONSE, the limit `sbdev`'s pause allows (1 ms in run 5, with no pause).
- **Type `01`** (run 2): MIX mode's messages were the same as with `02`, and the PLUGIN-mode mappings made under `02` came back unchanged. The differences are in section 3: the 0 dB indent with CC 64 (ten of ten passes), switches that send 0 on release (three presses, each released 130–250 ms later), and the solo color.
- **Type `03`** (run 3): the PLUGIN-mode loop in section 4a.
- **What MIX mode needs** (runs 4–4c): with `--setup none` the strips stayed blank. Sent one at a time, NUM TRACKS, FIRST TRACK, and track 1's TRACK DETAILS changed nothing on the screens; TRACK DETAILS END then drew track 1 (seen). In run 4b, track 1 still showed from run 4, and track 2's details and END drew track 2. After the power cycle (run 4c), track 2's details and END drew nothing, and NUM TRACKS, the same details, and END drew it (seen).
- **No pause** (run 5): with `--gap 0` the eight strips, the four plugin names, and the replies to CONTROL MAPPED all arrived (seen), and the Roto-Control answered DAW SELECT PLUGIN within 64 ms.
- **Switches in mute and solo modes** (run 1): one press each sent 127 and nothing on release, and changed neither the light nor the screen (seen); `led 1 on` and `led 1 off` set the light and the label (section 6).
- **Value text** (run 1): `show 1 -6.0 dB` showed briefly in PLUGIN mode; `showsw` showed nothing on a switch's screen, twice in PLUGIN mode and once in MIX mode (seen). The bytes sent had kind `01` (switch).
- **CC 64 and the 0 dB indent:** section 5.
- **The ends of the knob's range:** section 6. Run 1 had ten wraps; run 2 four; run 5 two wraps on knob 1 before `knob 1 -20dB` and three holds after it, a wrap on knob 2, which the host had not set, and wraps on knob 1 after the knob mode changed to pan and back to level.
- **PLUGIN mode** (run 1): per-plugin mappings, UNMAP CONTROL, learning by turning, and the stepped knob, all in section 4a.
- **Touch** (seen): touches often did not register, and a double tap sent nothing.

### Test 4 (2026-10-30): `RotoDriver` with TotalMix, through `sbdev bridge`

**Setup.** Firmware 3.3.0, type `02`, with `sbdev bridge` on branch `roto-driver` (commits
`ab1eb2f` to `fde305a`), in five runs with TotalMix FX "2.10 (1)" and a Digiface AES. The logs are
kept outside this repository; `sbdev bridge` logs SysEx from the Roto-Control and every message to
TotalMix, and from `fde305a` also every CC other than knobs and touches. The user's notes are
marked "seen".

**Findings:**

- **Strips, lights, and meters** (seen): the eight sources drew with their names; mute and PFL (on
  the record-arm switches) lit and followed TotalMix both ways; a meter moved with an input's level.
- **The 0 dB indent:** section 3 (felt at "-0.8 dB" before the scale was bent, and at 0.0 dB after).
- **The second track set** (seen): monitoring outputs in green, then sends in blue; a knob moved
  an output's fader, and the knob followed the fader moved in TotalMix.
- **Choosing a knob mode** (seen): with SEL held, a knob mode is chosen with the switch below it;
  the switch below Send 1 is labeled "FX". Choosing it sent SET MIX ALL TRACKS MODE with knobs on
  send. While SEL is held the Roto-Control showed a send name from an earlier run, so the host must
  send the names in every knob mode.
- **Single-track mode:** knob 3 set the focused input's level into the first send's submix. Switches
  1 and 2 sent no CC at all in single-track mode (run 5), so a host cannot use them there.
- **Knob reports on connecting** (run 6): within 0.6 s of the driver sending knob positions on
  connecting, knobs 5–7 reported positions near the ones sent (for example 0.444, 0.458, and
  0.456 for a position of about 0.46), and the driver passed them on to TotalMix. The user is not
  sure whether a hand was on those knobs. The inference is that the motors' travel was reported as
  turns; test 1 saw no echo of a host move, but there the knob was at rest. `RotoDriver` now
  ignores a knob's reports for 0.75 s after it moves the knob, and for 2 s those within 200 counts
  of where it put the knob. In run 7, with the guard and hands off the Roto-Control (seen), nothing
  went to TotalMix on connecting, but the Roto-Control still sent ROTO SELECT TRACK for knobs 3 and
  8 about 0.6 s after the knobs were moved, which supports the inference that motor travel is
  reported like a hand's.
- **SET CURRENT TRACK NAME** (run 7, seen): sent with "Outputs" while the second track set was
  shown, it renamed screen 8's top half, the strip of the track last reported by ROTO SELECT
  TRACK (7, counting from 0); the MENU window still showed "MIX-RTN". So it names the selected
  track, not the track set, and no command found sets the MENU window's text.
- **PLUGIN mode with no plugins** (run 7): answered with NUM PLUGINS 0, FIRST PLUGIN 0, and PLUGIN
  DETAILS END, the Roto-Control sent SET PLUGIN MODE once each time the user chose PLUGIN mode
  and nothing more. Seen: the knob screens black, the MENU window blue with "---" on top and the
  selected track's name below, and no flicker or cycling.
- **Meter colors** (`sbdev roto`, after run 7, seen): with thresholds 126 and 127, meter 1 at 125
  was green almost to its end, at 126 much the same (any yellow was at most a pixel or two), and
  at 127 full with a red last pixel. So a meter shows red at the red threshold itself. A yellow
  threshold of 126 leaves no visible yellow, so `RotoDriver` now borrows the levels of RME's own
  hardware meters (docs/TOTALMIX-OSC.md):
  yellow from −5 dBFS (117 on a −65…0 dBFS scale) and red from −1 dBFS (125). With those
  thresholds, meter values 112, 120, and 126 showed green, a yellow end, and a red end, as expected
  (seen).
- **Track colors against TotalMix's** (run 8, seen): with the playback pairs in TotalMix's eight
  colors and each mapped to the table color nearest in hue, schemes 9 (blue) and 61 (green)
  matched TotalMix; 50 looked slate blue, 57 brown, 56 burgundy, 2 ochre, and 24 royal blue
  (like 66 in test 2). So the screens show some table colors darker or bluer than their RGB
  values suggest, and the driver's colors are chosen by eye. A second round (run 10) found 61
  forest or olive green against TotalMix's lime, and 17 lemon against TotalMix's yellow-orange;
  in a third (run 11), 18 looked fluorescent and 1 plain orange, a better match for TotalMix's
  orange than 15. Run 12: 47 looked olive, and 59 brownish ("peanut butter"). Run 13: 19 matched
  TotalMix's green, and 73 was a little too green for its yellow.
- **SET TRACK COLOUR** (run 14, seen): sent after TRACK DETAILS END, it changed the strip's color
  in MIX mode (FFC800, a yellow-orange), with the strip's name in white, where scheme 73 alone had
  black text. The host cannot choose the text color. In run 15 an exact color sent for the third
  strip on the first page stayed on the third screen after paging, over the next page's own scheme,
  and after the Roto-Control was plugged in again an exact color sent for a strip did not show.
  So an exact color belongs to a screen rather than a track, and `RotoDriver` does not use them.
- **SOLO and ARM** (run 7, seen): with the switches on solo, a press set PFL in TotalMix and lit
  the switch; on record arm, a press did nothing.
- **Modes kept across sessions** (run 16, seen): on connecting, the Roto-Control reported SET MIX
  ALL TRACKS MODE with knobs on send 1 and switches on record arm, the modes left from run 15, so
  the knobs moved the first send's submix rather than the main one. No message sets these modes
  from the host.
- **Scheme 73** (run 16, seen): TotalMix's yellow drawn as scheme 73 looked "banana" against
  TotalMix's "mango". `sbdev bridge` has `color` commands to try exact colors again, sent to every
  strip on every page, and to tune a color with knobs 1–3.
- **A hang after exact colors** (run 17, seen): on a page of 7 strips (tracks 8–14 of 15), `color
  exact` sent SET TRACK COLOUR for tracks 8–14 and black for track 15, past the track count, twice
  in 7 seconds; the Roto-Control then hung. That the color past the track count caused the hang
  is an inference; the driver no longer sends colors for blank screens.
- **A hang after exact colors, again** (run 18, seen): with no color past the track count, `color
  exact` sent SET TRACK COLOUR for the seven strips (tracks 8–14) at once, and the Roto-Control
  froze. So the color past the track count was not the cause (or not the only one). Run 14, with
  one SET TRACK COLOUR per page, did not hang. That a burst of them causes the hang is an
  inference; `sbdev bridge` now sends them 150 ms apart, to test it.
- **Switch labels after a redraw** (run 19, seen): while `scheme tune` drew the page again and
  again (TRACK DETAILS … END, with no switch lights), the lower halves of several screens went
  dark. The labels are drawn with the switch lights, so `sbdev bridge` now sends the lights after
  each redraw (that this restores them is still to be seen).
- **A freeze after many redraws** (run 19, seen; its log was overwritten): after `scheme tune` had
  drawn the whole page up to every 100 ms for a while, the Roto-Control stopped responding: knobs
  and switches did nothing, some front-panel buttons still lit, and it did not answer DAW STARTED
  in the next run until plugged in again. Runs 17, 18, and 19 all froze while the host sent many
  SysEx messages in a short time; that this is the cause is an inference. `scheme tune` now sends
  one SET TRACK DETAILS per changed strip, at most every 250 ms.
- **`scheme tune`, lighter** (run 20, seen): one SET TRACK DETAILS per change, about 50 changes in
  30 s, and no freeze.
- **SET TRACK COLOUR's index** (run 20, seen; the reading is an inference): `color exact`, now
  paced 150 ms apart, sent colors for tracks 8–14 and the Roto-Control froze again. Across test 4,
  every SET TRACK COLOUR with an index of 0–7 worked (run 14: index 2) and every one with an index
  of 8 or more was followed by a freeze (run 15: index 13, the hang before run 16; runs 17, 18,
  and 20: indexes 8–15). With run 15's color staying on its screen across pages, this reads as:
  the index is the screen (0–7), not the track, and an index past 7 freezes the firmware.
  `RotoDriver` now sends the screen number.
- **Screen numbers on a later page** (run 21, seen): on the page of tracks 8–14, SET TRACK COLOUR
  with indexes 0–6 froze nothing but changed nothing on the screens, during `color tune` and
  `color 7 F0A030`. So the screen reading above does not hold either. A reading that fits every
  run (an inference): the firmware draws an exact color only for a track on the current page,
  but keeps it in an eight-entry table indexed by the track number, so indexes 0–7 work only on
  the first page (and stay with that screen afterward), and 8 or more overrun the table. If so,
  exact colors are usable only for the first eight tracks.
- **SET TRACK DETAILS** (run 22, seen): `swatch` sent SET TRACK DETAILS (`0A 11`, shown at once)
  for screens 1–4 on the first page with schemes 3, 17, 59, and 73; the names changed, the colors
  did not. Exact colors sent in run 21 (indexes 0–6) may still have been held for those screens,
  since the Roto-Control was not plugged in again in between, so this is not yet a clean result.
  `swatch` now draws the page with TRACK DETAILS … END instead.
- **Yellow** (run 23, seen): side by side, drawn as a page after plugging in again, schemes 3, 17,
  59, and 73 all showed; 73 was the closest to TotalMix's yellow ("not great"), 59 closer in hue
  but brownish. Yellow stays scheme 73.
- **The table's colors.** Melbourne Instruments' Bitwig integration lists an RGB value for each
  scheme (`ColorUtil.java` in [roto_control](https://github.com/Melbourne-Instruments/roto_control),
  MIT), which is a quicker guide than the SysEx doc's table to which schemes to try. By it, the
  neutral greys are 13 (white), 27, 41, 55, and 69 (darkest), with 70 black; 49, used for
  TotalMix's grey, is a bluish grey. How each looks on the screens still has to be seen.
- **Choosing a send** (2026-10-30, seen): with SEL held, pressing the switch under screen 3 (the
  one labeled "FX") again and again steps through the sends; turning knob 3 with SEL held did not
  change the send.
- **White** (run 24, seen): side by side, 13, 27, 41, 55, 69, and 49; TotalMix's default white is
  drawn as 27 (light grey). Schemes 2 and 30 were no better than 73 for yellow.
