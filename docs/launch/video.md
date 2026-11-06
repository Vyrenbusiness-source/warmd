# Launch video: one Unity test, cold vs. warm

Plan only, nothing recorded yet. Goal: a 30 to 45 second clip that shows the strongest measured number ([MEASURED.md](../MEASURED.md): one Unity test class, 56 s to 3 s) as a moving picture, for the README hero. Research said this is the best launch asset warmd lacks ([research.md](research.md#gaps-in-warmd-compared-with-them)).

## What the viewer sees

Two terminals side by side, same project, same test class, same commit, started at the same moment. Left "without warmd", right "with warmd". A timer runs in each pane. No narration; one caption line per beat.

| Time | Left: without warmd | Right: with warmd | Caption |
|---|---|---|---|
| 0 s | `Unity.exe -batchmode -runTests -testFilter <Class> ...` starts | `warmd test <Class>` starts | "Same test, same project. Left: Unity batch mode. Right: warmd." |
| 3 s | Editor still starting, log scrolls | `GREEN 12/12 in 3.1 s`, three lines | "warmd keeps a headless editor warm." |
| 5 s | log scrolls on | `warmd test <Class>` again: `GREEN (cache) 0.4 s` | "Unchanged code: answered from the green cache." |
| 8 s | still running | one-line edit that breaks an assertion, `warmd test <Class>`: `RED 1/12` plus the failing assertion only | "Red: only the assertion, not the log." |
| ~56 s | finishes, about 33 KB of log | idle | "33,323 bytes for the agent to read vs. 41." |
| end | | | Card: install lines, repo URL, "Windows, Unity and Godot editors". |

The output lines and times in the table are placeholders for the storyboard: the clip shows what warmd really prints, the captions use the numbers measured on the clip project.

Cut the dead time on the left with a visible fast-forward marker (e.g. "x4" in the corner), never silently, so nobody can say the clip hides the wait. Keep the full uncut take as a second file and link it under the clip.

## Setup before recording

1. A public, small Unity project, not a private one: a fresh Unity 6 project with one HDRP scene and one EditMode test class of about 12 tests, committed in a separate public repo so viewers can repeat it. The 56 s figure came from a large HDRP project; measure the clip project with `warmd bench` first and use its numbers in the captions, not the 56 s.
2. Reboot first, then wait until free RAM is above 30 % (this PC keeps kernel memory per process start until reboot, the cold run must not be slowed by that).
3. Cold side: no Unity running, `Library/` present (a first import is a different, longer story; say "Library imported" in the caption).
4. Warm side: `warmd test <Class>` once before recording so the daemon is up, then `warmd stop` is not called.
5. Same monitor, same font size (18 pt), dark theme, 1920 x 1080, terminal width 100 columns. Hide the prompt path and user name.

## Measurements to show and to keep

Record these per take in a table under the clip (same format as [MEASURED.md](../MEASURED.md)):

- Wall time from Enter to the result line, both sides (stopwatch overlay and the `time` of each command).
- Bytes of output the agent would read: `wc -c` of the Unity log file vs. the warmd output.
- Cache hit time of the repeat run.
- Red run: time and line count of the warmd output.
- Machine line: CPU, RAM, disk, Unity version, warmd version.

Three takes, report the median, keep all three raw logs in the public demo repo.

## Tools

- **Recording: OBS Studio** (free, Windows, records two terminal windows as one scene, 60 fps, a text source works as caption). Alternative: ShareX for a quick GIF draft.
- **Terminal: Windows Terminal** with two panes, Git Bash profile.
- **Timer overlay:** an OBS "Text (GDI+)" source fed by a small clock script, or simply `time` in each pane plus a big caption.
- **Edit and export:** DaVinci Resolve (free) or OBS's own trim; export MP4 (H.264, under 10 MB for GitHub) and a GIF under 5 MB for the README via `ffmpeg -i in.mp4 -vf "fps=12,scale=900:-1" out.gif`.
- **asciinema** does not fit: it records text only, the point of the clip is the wall clock.

## Where it goes

- README: GIF in the hero position, MP4 link below it.
- Release notes of the version it was recorded with: the MP4 attached.
