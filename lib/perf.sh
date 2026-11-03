# warmd perf: measure the product against a stored baseline and refuse regressions.
# Metrics: web build size and Chrome load time, Unity frame time (test category Perf), Godot frame time of a scene,
# and for any project the median of 3 timed runs of perf_cmd from warmd.conf. Baseline file: warmd.perf in the project root.
CFG_perf=""; CFG_perf_cmd=""; CFG_perf_tolerance=5; CFG_perf_dir=""; CFG_perf_scene=""; CFG_perf_floor_ms=50; CFG_perf_runs=3

perf_now_ms() {
  local n; n="$(date +%s%N 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) echo $(( $(date +%s) * 1000 ));; *) echo $(( n / 1000000 ));; esac
}
perf_median() { sort -n | awk '{a[NR]=$1} END{ if(NR) print a[int((NR+1)/2)] }'; }

# perf_time_cmd <shell command>: median wall ms of perf_runs runs, rc 1 if one run fails
perf_time_cmd() {
  local i t0 out=""
  for i in $(seq 1 "$CFG_perf_runs"); do
    t0="$(perf_now_ms)"
    ( cd "$PROJECT" && sh -c "$1" ) >"$RUN/perf-cmd.log" 2>&1 || { echo "FAIL perf command failed: $(tail -2 "$RUN/perf-cmd.log" | tr '\n' ' ' | cut -c1-160)" >&2; return 1; }
    out="$out$(( $(perf_now_ms) - t0 ))"$'\n'
  done
  printf '%s' "$out" | perf_median
}

perf_out_dir() {
  local d
  for d in "$CFG_perf_dir" dist build out; do [ -n "$d" ] && [ -d "$PROJECT/$d" ] && { echo "$PROJECT/$d"; return 0; }; done
  return 1
}

# Serves the built folder, loads it in headless Chrome over the DevTools protocol, prints the median loadEventEnd in tenths of ms.
perf_load_js() { cat <<'JS'
const http=require('http'),fs=require('fs'),path=require('path'),cp=require('child_process'),os=require('os');
const [,, root, chrome, runs] = process.argv;
const types={'.html':'text/html','.js':'text/javascript','.mjs':'text/javascript','.css':'text/css','.json':'application/json','.svg':'image/svg+xml','.png':'image/png','.wasm':'application/wasm'};
const srv=http.createServer((q,r)=>{let p=path.join(root,decodeURIComponent(q.url.split('?')[0]));if(fs.existsSync(p)&&fs.statSync(p).isDirectory())p=path.join(p,'index.html');
  fs.readFile(p,(e,d)=>{if(e){r.writeHead(404);r.end();return;}r.writeHead(200,{'content-type':types[path.extname(p)]||'application/octet-stream','cache-control':'no-store'});r.end(d);});});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{
  await new Promise(r=>srv.listen(0,'127.0.0.1',r));
  const url='http://127.0.0.1:'+srv.address().port+'/';
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'warmd-perf-'));
  const ch=cp.spawn(chrome,['--headless=new','--disable-gpu','--no-first-run','--remote-debugging-port=0','--user-data-dir='+dir,'about:blank'],{stdio:['ignore','ignore','pipe']});
  let port=0,buf='',gone=null;
  ch.stderr.on('data',d=>{buf+=d;const m=buf.match(/ws:\/\/127\.0\.0\.1:(\d+)\//);if(m)port=+m[1];});
  ch.on('error',e=>{gone='error: browser did not start: '+e.message;});
  let quit='';ch.on('exit',c=>{if(!port)quit=', the browser launcher exited with code '+c;});
  const done=(c,why)=>{if(why)console.error(why+(buf?' | browser stderr: '+buf.trim().split(/\r?\n/).slice(-3).join(' / '):''));try{ch.kill();}catch(e){}srv.close();process.exit(c);};
  setTimeout(()=>done(1,'error: load run timed out after 120s'),120000).unref();
  // The port comes from stderr or from the DevToolsActivePort file, some Windows sessions never deliver Chrome's stderr
  const portFile=path.join(dir,'DevToolsActivePort');
  for(let i=0;i<600&&!port&&!gone;i++){await sleep(100);
    try{const p=+fs.readFileSync(portFile,'utf8').split(/\r?\n/)[0];if(p>0)port=p;}catch(e){}}
  if(!port)return done(1,gone||'error: no DevTools port from the browser after 60s'+quit);
  const tab=await (await fetch('http://127.0.0.1:'+port+'/json/new?about:blank',{method:'PUT'})).json();
  const ws=new WebSocket(tab.webSocketDebuggerUrl);await new Promise(r=>ws.onopen=r);
  let id=0;const waits={};
  ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id&&waits[m.id])waits[m.id](m);};
  const send=(method,params={})=>new Promise(r=>{const i=++id;waits[i]=r;ws.send(JSON.stringify({id:i,method,params}));});
  await send('Page.enable');await send('Network.enable');await send('Network.setCacheDisabled',{cacheDisabled:true});
  const vals=[];
  for(let i=0;i<+runs;i++){
    await send('Page.navigate',{url:'about:blank'});await sleep(200);
    await send('Page.navigate',{url});
    let v=null;
    for(let k=0;k<300&&v==null;k++){await sleep(100);
      const r=await send('Runtime.evaluate',{expression:"(()=>{const n=performance.getEntriesByType('navigation')[0];return n&&n.loadEventEnd>0?n.loadEventEnd:null})()",returnByValue:true});
      v=r.result&&r.result.result?r.result.result.value:null;}
    if(v==null)return done(1,'error: page did not fire load within 30s: '+url);
    vals.push(v);
  }
  vals.sort((a,b)=>a-b);
  console.log(Math.round(vals[Math.floor((vals.length-1)/2)]*10));
  done(0);
})().catch(e=>{console.error(String(e));process.exit(1);});
JS
}

# Prints "name value" lines for the current state. Time values are stored as integers.
perf_collect() {
  local d t b ex v f a bb
  case "$KIND" in
    web)
      if [ -n "$CFG_build" ]; then ( cd "$PROJECT" && sh -c "$CFG_build" ) >"$RUN/perf-build.log" 2>&1
      elif has_script build; then ( cd "$PROJECT" && "$(pm)" run build ) >"$RUN/perf-build.log" 2>&1
      else : >"$RUN/perf-build.log"; fi || { echo "FAIL perf build failed: $(tail -2 "$RUN/perf-build.log" | tr '\n' ' ' | cut -c1-160)" >&2; return 1; }
      if d="$(perf_out_dir)"; then
        echo "size_bytes $(find "$d" -type f -exec cat {} + | wc -c | tr -d ' ')"
        if b="$(find_browser)" && command -v node >/dev/null 2>&1; then
          perf_load_js > "$RUN/perf-load.cjs"
          v="$(node "$(native_path "$RUN/perf-load.cjs")" "$(native_path "$d")" "$(native_path "$b")" "$CFG_perf_runs" 2>"$RUN/perf-load.log")" \
            || { echo "FAIL perf load metric failed: $( { grep -m1 -iE "error|fail" "$RUN/perf-load.log" || tail -1 "$RUN/perf-load.log"; } | cut -c1-200) (browser $b)" >&2; return 1; }
          echo "load_ms10 $v"
        else echo "(no Chrome or node, load metric skipped)" >&2; fi
      else echo "(no build folder, set perf_dir, size metric skipped)" >&2; fi;;
    unity)
      ex="$(cd "$PROJECT" && WARMD_NOCACHE=1 bash "$WARMD_HOME/bin/warmd" test --play --cat Perf 2>&1)" || { echo "FAIL perf test category Perf: $(echo "$ex" | tail -2 | tr '\n' ' ' | cut -c1-160)" >&2; return 1; }
      # Tests of category Perf print "PERF <name> frame_ms=<float>", the lines are read from the run output
      echo "$ex" | grep -oE 'PERF [A-Za-z0-9_.]+ frame_ms=[0-9.]+' | awk '{sub("frame_ms=","",$3); printf "frame_ms10_%s %d\n",$2,$3*10+0.5}';;
    godot)
      if [ -n "$CFG_perf_scene" ]; then
        f="$(godot_exe)" || { echo "FAIL Godot not found, set WARMD_GODOT" >&2; return 1; }
        # Wall time of 330 frames minus 30 frames: the engine start cancels out
        a="$(perf_time_cmd "\"$f\" --path \"$(native_path "$PROJECT")\" \"$CFG_perf_scene\" --disable-vsync --quit-after 30")" || return 1
        bb="$(perf_time_cmd "\"$f\" --path \"$(native_path "$PROJECT")\" \"$CFG_perf_scene\" --disable-vsync --quit-after 330")" || return 1
        echo "frame_ms10 $(( (bb - a) * 10 / 300 ))"
      fi;;
  esac
  if [ -n "$CFG_perf_cmd" ]; then
    t="$(perf_time_cmd "$CFG_perf_cmd")" || return 1
    echo "cmd_ms $t"
  fi
  return 0
}

# perf_compare <baseline> <current>: one line per regression, nothing when equal or better
perf_compare() {
  awk -v tol="$CFG_perf_tolerance" -v floor="$CFG_perf_floor_ms" '
    NR==FNR { base[$1]=$2; next }
    { n=$1; v=$2
      if (!(n in base)) { printf "new metric %s=%s has no baseline, run warmd perf --save\n", n, v; bad=1; next }
      b=base[n]; seen[n]=1
      f=0; if (n == "cmd_ms") f=floor; else if (n ~ /ms10/) f=floor*10
      if (v > b*(1+tol/100) && v-b > f) { printf "%s %d -> %d (+%.1f%%, limit %s%%)\n", n, b, v, (v-b)*100/b, tol; bad=1 } }
    END { for (k in base) if (!(k in seen)) { printf "metric %s is in the baseline but was not measured\n", k; bad=1 }; exit bad }
  ' "$1" "$2"
}

perf_run() { # [--save]
  local save=0 cur="$RUN/perf-current.txt" basef="$PROJECT/warmd.perf" bad
  [ "${1:-}" = --save ] && save=1
  [ $save = 1 ] || [ -f "$basef" ] || { echo "FAIL perf: no baseline, run warmd perf --save first"; return 2; }
  perf_collect > "$cur" || return 1
  [ -s "$cur" ] || { echo "FAIL perf: nothing to measure here. Web: a build script. Unity: tests of category Perf. Godot: perf_scene. Any project: perf_cmd in warmd.conf"; return 2; }
  if [ $save = 1 ]; then
    sort "$cur" > "$basef"
    echo "OK $(secs)s perf baseline saved: $(tr '\n' ' ' < "$basef" | cut -c1-160)"; return 0
  fi
  if bad="$(perf_compare "$basef" "$cur")"; then
    echo "OK $(secs)s perf within ${CFG_perf_tolerance}%: $(tr '\n' ' ' < "$cur" | cut -c1-160)"; return 0
  fi
  echo "FAIL perf regression: $(echo "$bad" | tr '\n' ';' | cut -c1-240)"; return 1
}
