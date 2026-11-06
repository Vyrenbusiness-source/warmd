using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEditor.Compilation;
using UnityEditor.TestTools.TestRunner.Api;
using UnityEngine;

namespace Warmd
{
    /// <summary>
    /// Keeps the Unity editor warm for the warmd CLI. Takes jobs from job.txt, writes a short result.txt.
    /// State lives in files, so a domain reload in the middle of a job loses nothing.
    /// </summary>
    [InitializeOnLoad]
    public static class WarmdDaemon
    {
        static readonly string Dir = Environment.GetEnvironmentVariable("WARMD_DIR")
            ?? Path.GetFullPath(Path.Combine(Application.dataPath, "..", ".warmd", "run"));
        static string F(string name) => Path.Combine(Dir, name);

        const int MaxLines = 14;
        const double DefaultIdleMinutes = 10;   // daemon_idle in warmd.conf, a forgotten editor holds gigabytes and a slot
        const string LastJobKey = "warmd_last_job";
        static double nextTick, nextBeat;
        static TestRunnerApi api;
        static bool callbacksReady;
        // warmd test --window: an editor with a window, started by warmd, so it ends when idle like a headless one
        static readonly bool OwnWindow = Environment.GetEnvironmentVariable("WARMD_WINDOW") == "1";
        const string PlacedKey = "warmd_placed";

        static WarmdDaemon()
        {
            // Only the process warmd started. Import workers and one-shot starts load this class too and must not take jobs.
            if (Environment.GetEnvironmentVariable("WARMD_DIR") == null) return;
            if (AssetDatabase.IsAssetImportWorkerProcess() || Environment.GetCommandLineArgs().Contains("-executeMethod")) return;
            Directory.CreateDirectory(Dir);
            File.WriteAllText(F("pid.txt"), Process.GetCurrentProcess().Id.ToString());
            if (!SessionState.GetBool("warmd_init", false))   // fresh editor start, not a domain reload
            {
                SessionState.SetBool("warmd_init", true);
                SessionState.SetString(LastJobKey, NowMs().ToString());
                foreach (var f in new[] { "state.txt", "job.txt", "result.txt", "errors.txt", "tests.txt", "current.txt", "current.full", "current.ms", "screen.txt" }) if (File.Exists(F(f))) File.Delete(F(f));
            }
            if (Application.isBatchMode)
            {
                // Workers cost about 1 GB each and can crash under -nographics, in-process import has neither problem
                AssetDatabase.ActiveRefreshImportMode = AssetDatabase.RefreshImportMode.InProcess;
                Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal;   // the machine stays usable
            }
            EditorUtility.audioMasterMute = true;   // test runs stay silent, warmd test --sound turns it on for one run
            CompilationPipeline.assemblyCompilationFinished += OnAssemblyCompiled;
            EditorApplication.playModeStateChanged += OnPlayMode;
            EditorApplication.update += Tick;
        }

        // ---- plumbing -------------------------------------------------------------------------

        static Dictionary<string, string> Read(string name)
        {
            var d = new Dictionary<string, string>();
            try
            {
                if (!File.Exists(F(name))) return d;
                foreach (var line in File.ReadAllLines(F(name)))
                {
                    int at = line.IndexOf('=');
                    if (at > 0) d[line.Substring(0, at)] = line.Substring(at + 1);
                }
            }
            catch (IOException) { }
            return d;
        }

        static void Write(string name, Dictionary<string, string> d)
        {
            string tmp = F(name + ".tmp");
            File.WriteAllLines(tmp, d.Select(p => p.Key + "=" + p.Value));
            if (File.Exists(F(name))) File.Delete(F(name));
            File.Move(tmp, F(name));
        }

        static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        static string Get(Dictionary<string, string> d, string key, string fallback = "") => d.TryGetValue(key, out var v) ? v : fallback;

        static void OnAssemblyCompiled(string assembly, CompilerMessage[] messages)
        {
            var errors = messages.Where(m => m.type == CompilerMessageType.Error).Select(m => $"{m.file}({m.line},{m.column}): {m.message}").ToArray();
            if (errors.Length > 0) File.AppendAllLines(F("errors.txt"), errors);
        }

        /// <summary>Test time lapse, warmd test --speed N. Fixed steps stay the same size, more of them run per real second.
        /// The game stays silent in a test run (no sound through the user's speakers) unless warmd test --sound asked for it.</summary>
        static void OnPlayMode(PlayModeStateChange change)
        {
            if (change != PlayModeStateChange.EnteredPlayMode) return;
            var state = Read("state.txt");
            if (Get(state, "sound") != "1") { EditorUtility.audioMasterMute = true; AudioListener.volume = 0f; }
            if (float.TryParse(Get(state, "speed"), NumberStyles.Float, CultureInfo.InvariantCulture, out float speed) && speed > 0f) Time.timeScale = speed;
        }

        static void Finish(Dictionary<string, string> state, bool ok, IEnumerable<string> lines)
        {
            long secs = (NowMs() - long.Parse(Get(state, "start", NowMs().ToString()))) / 1000;
            var body = new List<string> { $"{Get(state, "id")} {(ok ? "OK" : "FAIL")} {secs}s {Get(state, "kind")}" };
            body.AddRange(lines.Take(MaxLines));
            string tmp = F("result.tmp");
            File.WriteAllLines(tmp, body);
            if (File.Exists(F("result.txt"))) File.Delete(F("result.txt"));
            File.Move(tmp, F("result.txt"));
            Write("state.txt", new Dictionary<string, string> { { "phase", "idle" }, { "id", Get(state, "id") } });
            SessionState.SetString(LastJobKey, NowMs().ToString());
        }

        /// <summary>A forgotten daemon costs gigabytes for nothing. A visible editor stays open, unless warmd opened it.</summary>
        static void ExitWhenIdle()
        {
            if ((!Application.isBatchMode && !OwnWindow) || EditorApplication.isCompiling || EditorApplication.isUpdating) return;
            if (!double.TryParse(Environment.GetEnvironmentVariable("WARMD_IDLE_MIN"), out double minutes)) minutes = DefaultIdleMinutes;
            if (!long.TryParse(SessionState.GetString(LastJobKey, ""), out long last) || NowMs() - last < minutes * 60000) return;
            File.Delete(F("alive.txt"));
            File.Delete(F("pid.txt"));
            EditorApplication.Exit(0);
        }

        static string Short(string s, int n = 160)
        {
            s = (s ?? "").Replace("\r", " ").Replace("\n", " ").Trim();
            return s.Length <= n ? s : s.Substring(0, n);
        }

        // ---- loop -----------------------------------------------------------------------------

        static void Tick()
        {
            double now = EditorApplication.timeSinceStartup;
            if (now < nextTick) return;
            nextTick = now + 0.2;
            try
            {
                if (now >= nextBeat) { nextBeat = now + 1.0; File.WriteAllText(F("alive.txt"), NowMs().ToString()); if (OwnWindow) PlaceOnce(); }
                EnsureCallbacks();
                var state = Read("state.txt");
                string phase = Get(state, "phase", "idle");
                if (phase != "idle") Continue(state, phase);
                else if (File.Exists(F("job.txt"))) TakeJob(state);
                else ExitWhenIdle();
            }
            catch (Exception e)
            {
                var state = Read("state.txt");
                UnityEngine.Debug.LogError("[warmd] " + e);
                Finish(state, false, new[] { "daemon exception: " + Short(e.Message) });
            }
        }

        // ---- window on another monitor ---------------------------------------------------------
        // -monitor N is a player argument, an editor ignores it. The daemon moves its own main window instead:
        // WARMD_MONITOR (default 2), monitor 1 is the primary, the others follow by their Windows number.

        /// <summary>Once per editor session, a domain reload must not move it again. Tries for 15 s while the window comes up.</summary>
        static void PlaceOnce()
        {
            if (SessionState.GetBool(PlacedKey, false)) return;
            int tries = SessionState.GetInt(PlacedKey + "_tries", 0) + 1;
            SessionState.SetInt(PlacedKey + "_tries", tries);
            if (!int.TryParse(Environment.GetEnvironmentVariable("WARMD_MONITOR"), out int want) || want < 1) want = 2;
            string line;
            try { line = PlaceWindow(want); }
            catch (Exception e) { line = "window not moved: " + Short(e.Message); }
            if (line == null && tries < 15) return;
            SessionState.SetBool(PlacedKey, true);
            File.WriteAllText(F("screen.txt"), line ?? "window not moved: no editor main window found");
        }

        [StructLayout(LayoutKind.Sequential)] struct Rect32 { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct MonitorInfo { public int Size; public Rect32 Monitor, Work; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device; }
        delegate bool MonitorProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);
        delegate bool WindowProc(IntPtr hwnd, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorProc proc, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
        [DllImport("user32.dll")] static extern bool EnumWindows(WindowProc proc, IntPtr data);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect32 rect);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);

        /// <summary>The line for screen.txt, or null while the editor has no main window yet</summary>
        static string PlaceWindow(int want)
        {
            if (Application.platform != RuntimePlatform.WindowsEditor) return "window not moved: only on Windows";
            var monitors = new List<MonitorInfo>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (m, hdc, r, d) =>
            {
                var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
                if (GetMonitorInfo(m, ref info)) monitors.Add(info);
                return true;
            }, IntPtr.Zero);
            monitors = monitors.OrderBy(i => (i.Flags & 1) == 1 ? 0 : 1)
                .ThenBy(i => int.TryParse(Regex.Match(i.Device ?? "", @"\d+$").Value, out int n) ? n : 99).ToList();
            // The main window is the biggest visible Unity container window of this process
            uint me = (uint)Process.GetCurrentProcess().Id;
            IntPtr main = IntPtr.Zero; long area = 0;
            EnumWindows((h, d) =>
            {
                if (!IsWindowVisible(h) || GetWindowThreadProcessId(h, out uint pid) == 0 || pid != me) return true;
                var cls = new StringBuilder(64); GetClassName(h, cls, 64);
                if (cls.ToString() != "UnityContainerWndClass" || !GetWindowRect(h, out Rect32 r)) return true;
                long a = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
                if (a > area) { area = a; main = h; }
                return true;
            }, IntPtr.Zero);
            if (main == IntPtr.Zero) return null;
            if (monitors.Count < want) return "window stays on monitor 1: monitor " + want + " not found, " + monitors.Count + " connected";
            var w = monitors[want - 1].Work;
            ShowWindow(main, 9);   // SW_RESTORE: a maximized window does not move
            SetWindowPos(main, IntPtr.Zero, w.Left, w.Top, w.Right - w.Left, w.Bottom - w.Top, 0x0004 | 0x0010);   // SWP_NOZORDER | SWP_NOACTIVATE
            ShowWindow(main, 3);   // SW_MAXIMIZE on that monitor
            return "window editor on monitor " + want + " of " + monitors.Count + " (" + (w.Right - w.Left) + "x" + (w.Bottom - w.Top) + " at " + w.Left + "," + w.Top + ")";
        }

        static void EnsureCallbacks()
        {
            if (callbacksReady) return;
            api = ScriptableObject.CreateInstance<TestRunnerApi>();
            api.RegisterCallbacks(new TestCallbacks());
            callbacksReady = true;
        }

        static void TakeJob(Dictionary<string, string> last)
        {
            var job = Read("job.txt");
            File.Delete(F("job.txt"));
            string id = Get(job, "id"), kind = Get(job, "kind");
            if (id == "" || id == Get(last, "id")) return;
            var state = new Dictionary<string, string>(job) { { "start", NowMs().ToString() }, { "phase", kind } };
            File.Delete(F("errors.txt"));
            EditorUtility.audioMasterMute = Get(job, "sound") != "1";   // muted before every run unless it asks for sound
            // The run's own port (test_port_env in warmd.conf): parallel daemons never bind the same one
            if (Get(job, "port_env") != "" && Get(job, "port") != "") Environment.SetEnvironmentVariable(Get(job, "port_env"), Get(job, "port"));
            switch (kind)
            {
                case "ping":
                    Finish(state, true, new[] { "daemon alive, " + (Application.isBatchMode ? "batchmode" : "window") + ", Unity " + Application.unityVersion });
                    break;
                case "compile":
                    Write("state.txt", state);
                    AssetDatabase.Refresh();
                    if (!EditorApplication.isCompiling) CompilationPipeline.RequestScriptCompilation();
                    break;
                case "test":
                case "call":
                    state["phase"] = kind == "test" ? "test-wait" : kind;
                    Write("state.txt", state);
                    AssetDatabase.Refresh();   // new code first, the phase waits until the compile is done
                    break;
                case "quit":
                    Finish(state, true, new[] { "daemon stops" });
                    EditorApplication.Exit(0);
                    break;
                default:
                    Finish(state, false, new[] { "unknown job " + kind });
                    break;
            }
        }

        static void Continue(Dictionary<string, string> state, string phase)
        {
            long age = NowMs() - long.Parse(Get(state, "start", NowMs().ToString()));
            long timeoutMs = long.Parse(Get(state, "timeout", "900")) * 1000;
            bool busy = EditorApplication.isCompiling || EditorApplication.isUpdating;
            if (age > timeoutMs && phase == "testing")
            {
                Hung(state, "timeout after " + timeoutMs / 1000 + "s");
                return;
            }
            if (age > timeoutMs)
            {
                string test = File.Exists(F("current.txt")) ? File.ReadAllText(F("current.txt")) : "";
                Finish(state, false, new[] { "timeout after " + timeoutMs / 1000 + "s in phase " + phase, test == "" ? "" : "stuck in: " + test });
                return;
            }
            switch (phase)
            {
                case "compile":
                    if (busy || age < 2500) return;
                    if (EditorUtility.scriptCompilationFailed) Finish(state, false, ErrorLines());
                    else Finish(state, true, new[] { "compiled" });
                    break;
                case "test-wait":
                    if (busy || age < 300 || EditorApplication.isPlayingOrWillChangePlaymode) return;
                    if (EditorUtility.scriptCompilationFailed) { Finish(state, false, ErrorLines()); return; }
                    StartTests(state);
                    break;
                case "testing":
                    // test_timeout in warmd.conf: one test running longer counts as hung and red, the run ends with what finished before it
                    if (long.TryParse(Get(state, "test_timeout"), out long limit) && limit > 0 && File.Exists(F("current.ms"))
                        && long.TryParse(File.ReadAllText(F("current.ms")).Trim(), out long since) && NowMs() - since > limit * 1000)
                        Hung(state, "hung after " + limit + "s (test_timeout)");
                    break;   // RunFinished ends it, the timeouts above guard it
                case "call":
                    if (busy || age < 300) return;
                    if (EditorUtility.scriptCompilationFailed) { Finish(state, false, ErrorLines()); return; }
                    CallMethod(state);
                    break;
            }
        }

        /// <summary>Runs any public static method in the warm editor, for example a level builder: warmd call Namespace.Class.Method</summary>
        static void CallMethod(Dictionary<string, string> state)
        {
            string full = Get(state, "method");
            int dot = full.LastIndexOf('.');
            var method = AppDomain.CurrentDomain.GetAssemblies()
                .Select(a => a.GetType(full.Substring(0, Math.Max(dot, 0))))
                .FirstOrDefault(t => t != null)?.GetMethod(full.Substring(dot + 1), BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static);
            if (method == null) { Finish(state, false, new[] { "no static method " + full }); return; }
            try { method.Invoke(null, null); Finish(state, true, new[] { full + " done" }); }
            catch (TargetInvocationException e) { Finish(state, false, new[] { Short(e.InnerException.GetType().Name + ": " + e.InnerException.Message) }); }
        }

        /// <summary>A test that never ends: name it and report what finished before it, instead of a bare timeout.
        /// The runner is still stuck in that test, so warmd ends this editor on the HUNG line and the next job starts fresh.</summary>
        static void Hung(Dictionary<string, string> state, string why)
        {
            string test = File.Exists(F("current.txt")) ? File.ReadAllText(F("current.txt")).Trim() : "";
            var rows = File.Exists(F("tests.txt")) ? File.ReadAllLines(F("tests.txt")).Select(l => l.Split('\t')).Where(p => p.Length >= 3).ToList() : new List<string[]>();
            var failed = rows.Where(p => p[0] == "F").ToList();
            var lines = new List<string>
            {
                "HUNG " + (test == "" ? "before the first test" : test) + ": " + why,
                $"before it: {rows.Count(p => p[0] == "P")} passed, {failed.Count} failed, {rows.Count(p => p[0] == "S")} skipped"
            };
            lines.AddRange(failed.Take(MaxLines - 3).Select(p => "RED " + p[1].Split('.').Last() + ": " + p[2]));
            Finish(state, false, lines);
        }

        static IEnumerable<string> ErrorLines()
        {
            var lines = File.Exists(F("errors.txt")) ? File.ReadAllLines(F("errors.txt")).Distinct().ToList() : new List<string>();
            if (lines.Count == 0) return new[] { "script compilation failed, no detail" };
            return lines.Take(MaxLines - 1).Select(l => Short(l.Replace("\\", "/"), 200)).Concat(lines.Count > MaxLines - 1 ? new[] { "... " + (lines.Count - MaxLines + 1) + " more" } : new string[0]);
        }

        // ---- tests ----------------------------------------------------------------------------

        static void StartTests(Dictionary<string, string> state)
        {
            File.Delete(F("tests.txt"));
            File.Delete(F("current.txt")); File.Delete(F("current.full")); File.Delete(F("current.ms"));
            var filter = new Filter { testMode = Get(state, "mode", "Edit") == "Play" ? TestMode.PlayMode : TestMode.EditMode };
            string name = Get(state, "filter");
            if (name != "") filter.groupNames = new[] { name };
            string cat = Get(state, "cat");
            if (cat != "") filter.categoryNames = cat.Split(',');
            // Only the project's own tests: embedded or linked packages (an HDRP copy in Packages/) bring their own test
            // assemblies, whose failures say nothing about the project. packages=1 in the job runs them too.
            if (Get(state, "packages") != "1") filter.assemblyNames = ProjectAssemblies();
            // skip=<file>: full test names that already ran or hung in an earlier round (warmd goes on after a HUNG).
            // The same filter runs again, narrowed to every other test: testNames joins the other fields with AND.
            string skipFile = Get(state, "skip");
            if (skipFile != "" && File.Exists(skipFile))
            {
                var skip = new HashSet<string>(File.ReadAllLines(skipFile).Select(l => l.Trim()).Where(l => l != ""));
                state["phase"] = "test-list";
                Write("state.txt", state);
                api.RetrieveTestList(filter.testMode, root =>
                {
                    var rest = Leaves(root).Select(t => t.FullName).Where(n => !skip.Contains(n)).Distinct().ToArray();
                    if (rest.Length == 0) { Finish(state, true, new[] { "0 passed, 0 failed, 0 skipped (no test left after the skip list)" }); return; }
                    filter.testNames = rest;
                    state["phase"] = "testing";
                    Write("state.txt", state);
                    api.Execute(new ExecutionSettings(filter));
                });
                return;
            }
            state["phase"] = "testing";
            Write("state.txt", state);
            api.Execute(new ExecutionSettings(filter));
        }

        static IEnumerable<ITestAdaptor> Leaves(ITestAdaptor t)
        {
            if (!t.HasChildren) return t.IsSuite ? Enumerable.Empty<ITestAdaptor>() : new[] { t };
            return t.Children.SelectMany(Leaves);
        }

        static string[] ProjectAssemblies()
        {
            // Player holds the PlayMode test assemblies (no platform limit), without it a --play filter matched no test.
            return CompilationPipeline.GetAssemblies(AssembliesType.Editor).Concat(CompilationPipeline.GetAssemblies(AssembliesType.Player))
                .Select(a => a.name).Distinct()
                .Where(n =>
                {
                    string asmdef = CompilationPipeline.GetAssemblyDefinitionFilePathFromAssemblyName(n);
                    return asmdef == null ? n.StartsWith("Assembly-CSharp", StringComparison.Ordinal) : asmdef.Replace('\\', '/').StartsWith("Assets/", StringComparison.Ordinal);
                })
                .ToArray();
        }

        sealed class TestCallbacks : ICallbacks, IErrorCallbacks
        {
            public void RunStarted(ITestAdaptor testsToRun) { }
            public void TestStarted(ITestAdaptor test)
            {
                if (test.HasChildren) return;
                File.WriteAllText(F("current.txt"), test.Name);
                File.WriteAllText(F("current.full"), test.FullName);   // warmd steps over a hung test by this name
                File.WriteAllText(F("current.ms"), NowMs().ToString());   // a file: entering PlayMode reloads the domain, statics are gone
            }

            public void TestFinished(ITestResultAdaptor result)
            {
                string state = result.ResultState ?? "";
                // A suite is never a test, also an empty one: a filter that matches nothing left the root suite as "1 passed".
                bool suite = result.Test.IsSuite || result.HasChildren;
                if (!suite && File.Exists(F("current.ms"))) File.Delete(F("current.ms"));
                if (!suite && File.Exists(F("current.full"))) File.Delete(F("current.full"));   // a hang between tests names no test
                bool suiteFail = suite && state.StartsWith("Failed") && !state.Contains("Child");
                if (suite && !suiteFail) return;
                string tag = state.StartsWith("Failed") ? "F" : state.StartsWith("Skipped") || state.StartsWith("Ignored") || state.StartsWith("Inconclusive") ? "S" : "P";
                var at = Regex.Match(result.StackTrace ?? "", @"([A-Za-z0-9_.]+\.cs):(?:line )?(\d+)");   // the assert in the test: spares a log search
                string message = (at.Success ? at.Groups[1].Value + ":" + at.Groups[2].Value + " " : "") + Short(result.Message, 140);
                File.AppendAllText(F("tests.txt"), tag + "\t" + result.Test.FullName + "\t" + message.Replace('\t', ' ') + "\n");
            }

            public void RunFinished(ITestResultAdaptor result)
            {
                var state = Read("state.txt");
                if (Get(state, "phase") != "testing") return;
                var rows = File.Exists(F("tests.txt")) ? File.ReadAllLines(F("tests.txt")).Select(l => l.Split('\t')).Where(p => p.Length >= 3).ToList() : new List<string[]>();
                var failed = rows.Where(p => p[0] == "F").ToList();
                var lines = new List<string> { $"{rows.Count(p => p[0] == "P")} passed, {failed.Count} failed, {rows.Count(p => p[0] == "S")} skipped" };
                lines.AddRange(failed.Take(MaxLines - 2).Select(p => "RED " + p[1].Split('.').Last() + ": " + p[2]));
                if (failed.Count > MaxLines - 2) lines.Add("... " + (failed.Count - MaxLines + 2) + " more red");
                if (rows.Count == 0 && Get(state, "skip") != "") lines[0] = "0 passed, 0 failed, 0 skipped (no test left after the skip list)";
                else if (rows.Count == 0) { failed.Add(null); lines[0] = "0 tests ran (filter matches nothing?)"; }
                Finish(state, failed.Count == 0, lines);
            }

            public void OnError(string message)
            {
                var state = Read("state.txt");
                if (Get(state, "phase") == "testing") Finish(state, false, new[] { "runner error: " + Short(message) });
            }
        }
    }
}
