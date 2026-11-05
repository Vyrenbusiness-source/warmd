using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
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
                foreach (var f in new[] { "state.txt", "job.txt", "result.txt", "errors.txt", "tests.txt", "current.txt", "current.ms" }) if (File.Exists(F(f))) File.Delete(F(f));
            }
            if (Application.isBatchMode)
            {
                // Workers cost about 1 GB each and can crash under -nographics, in-process import has neither problem
                AssetDatabase.ActiveRefreshImportMode = AssetDatabase.RefreshImportMode.InProcess;
                Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal;   // the machine stays usable
            }
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

        /// <summary>Test time lapse, warmd test --speed N. Fixed steps stay the same size, more of them run per real second.</summary>
        static void OnPlayMode(PlayModeStateChange change)
        {
            if (change != PlayModeStateChange.EnteredPlayMode) return;
            if (float.TryParse(Get(Read("state.txt"), "speed"), NumberStyles.Float, CultureInfo.InvariantCulture, out float speed) && speed > 0f) Time.timeScale = speed;
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

        /// <summary>A forgotten daemon costs gigabytes for nothing. A visible editor stays open.</summary>
        static void ExitWhenIdle()
        {
            if (!Application.isBatchMode || EditorApplication.isCompiling || EditorApplication.isUpdating) return;
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
                if (now >= nextBeat) { nextBeat = now + 1.0; File.WriteAllText(F("alive.txt"), NowMs().ToString()); }
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
            File.Delete(F("current.txt")); File.Delete(F("current.ms"));
            state["phase"] = "testing";
            Write("state.txt", state);
            var filter = new Filter { testMode = Get(state, "mode", "Edit") == "Play" ? TestMode.PlayMode : TestMode.EditMode };
            string name = Get(state, "filter");
            if (name != "") filter.groupNames = new[] { name };
            string cat = Get(state, "cat");
            if (cat != "") filter.categoryNames = cat.Split(',');
            // Only the project's own tests: embedded or linked packages (an HDRP copy in Packages/) bring their own test
            // assemblies, whose failures say nothing about the project. packages=1 in the job runs them too.
            if (Get(state, "packages") != "1") filter.assemblyNames = ProjectAssemblies();
            api.Execute(new ExecutionSettings(filter));
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
                File.WriteAllText(F("current.ms"), NowMs().ToString());   // a file: entering PlayMode reloads the domain, statics are gone
            }

            public void TestFinished(ITestResultAdaptor result)
            {
                string state = result.ResultState ?? "";
                // A suite is never a test, also an empty one: a filter that matches nothing left the root suite as "1 passed".
                bool suite = result.Test.IsSuite || result.HasChildren;
                if (!suite && File.Exists(F("current.ms"))) File.Delete(F("current.ms"));
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
                if (rows.Count == 0) { failed.Add(null); lines[0] = "0 tests ran (filter matches nothing?)"; }
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
