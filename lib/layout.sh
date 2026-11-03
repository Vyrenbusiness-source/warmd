# warmd layout: layout problems as short text lines instead of a screenshot.
# Loads the page in headless Chrome over the DevTools protocol at desktop and phone width (same browser as warmd shot)
# and reports: element wider than the viewport, text clipped by overflow hidden, overlapping text boxes, horizontal page scroll.

layout_js() { cat <<'JS'
const cp=require('child_process'),fs=require('fs'),path=require('path'),os=require('os');
const [,, chrome, target] = process.argv;
const sizes=[['desktop',1440,900],['phone',390,844]];
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
// Runs inside the page, returns [kind, selector, w, h] rows
const probe=`(()=>{
const vw=document.documentElement.clientWidth,rows=[];
const sel=e=>{let s=e.tagName.toLowerCase();if(e.id)return s+'#'+e.id;const c=[...e.classList].slice(0,2);if(c.length)s+='.'+c.join('.');
  const p=e.parentElement;if(p&&p!==document.body){const same=[...p.children].filter(x=>x.tagName===e.tagName);if(same.length>1)s+=':nth-of-type('+(same.indexOf(e)+1)+')';}return s;};
// Screen-reader text, tracking pixels and faded-out parts (GitHub renders plenty) are no layout problem: 1x1 or smaller,
// clipped to nothing, or inside such a box or an opacity 0 box counts as invisible
const gone=p=>{const cs=getComputedStyle(p),r=p.getBoundingClientRect();return cs.opacity==='0'||(cs.clip.startsWith('rect')&&!/[1-9]/.test(cs.clip))||cs.clipPath.includes('inset(50%')||(r.width<=1&&r.height<=1&&/(hidden|clip)/.test(cs.overflowX+cs.overflowY));};
const vis=e=>{const r=e.getBoundingClientRect(),cs=getComputedStyle(e);if(!(r.width>1&&r.height>1&&cs.visibility!=='hidden'&&cs.display!=='none'))return false;
  for(let p=e;p&&p!==document.body;p=p.parentElement)if(gone(p))return false;return true;};
const clips=(e)=>{for(let p=e.parentElement;p&&p!==document.documentElement;p=p.parentElement){const o=getComputedStyle(p);if(/(hidden|clip|auto|scroll)/.test(o.overflowX)&&p!==document.body)return true;}return false;};
const sz=e=>{const r=e.getBoundingClientRect();return [Math.round(r.width),Math.round(r.height)];};
const all=[...document.body.querySelectorAll('*')].filter(e=>!/^(SCRIPT|STYLE|LINK|META|TITLE)$/.test(e.tagName)&&vis(e));
if(document.documentElement.scrollWidth>vw+1)rows.push(['hscroll','html',document.documentElement.scrollWidth,vw]);
for(const e of all){const r=e.getBoundingClientRect();
  if((r.right>vw+1||r.left<-1)&&!clips(e)){const wide=all.some(p=>p!==e&&p.contains(e)&&(p.getBoundingClientRect().right>vw+1)&&!clips(p));if(!wide)rows.push(['wide',sel(e),...sz(e)]);}
  const cs=getComputedStyle(e);
  if(/(hidden|clip)/.test(cs.overflowX+cs.overflowY)&&(e.scrollWidth>e.clientWidth+1||e.scrollHeight>e.clientHeight+1)&&e.textContent.trim()&&!(cs.textOverflow==='ellipsis'))rows.push(['clipped',sel(e),...sz(e)]);}
const boxes=[];
for(const e of all){let own=false;for(const n of e.childNodes)if(n.nodeType===3&&n.textContent.trim())own=true;if(!own)continue;
  const rg=document.createRange();rg.selectNodeContents(e);const r=rg.getBoundingClientRect();if(r.width>0&&r.height>0)boxes.push([e,r]);}
const seen=new Set();
for(let i=0;i<boxes.length;i++)for(let j=i+1;j<boxes.length;j++){const [a,ra]=boxes[i],[b,rb]=boxes[j];if(a.contains(b)||b.contains(a))continue;
  const w=Math.min(ra.right,rb.right)-Math.max(ra.left,rb.left),h=Math.min(ra.bottom,rb.bottom)-Math.max(ra.top,rb.top);
  if(w>2&&h>2&&w*h>0.2*Math.min(ra.width*ra.height,rb.width*rb.height)){const k=sel(a)+' x '+sel(b);if(!seen.has(k)){seen.add(k);rows.push(['overlap',k,Math.round(w),Math.round(h)]);}}}
return rows;})()`;
(async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'warmd-layout-'));
  const ch=cp.spawn(chrome,['--headless=new','--disable-gpu','--no-first-run','--remote-debugging-port=0','--user-data-dir='+dir,'about:blank'],{stdio:['ignore','ignore','pipe']});
  let port=0,buf='';
  ch.stderr.on('data',d=>{buf+=d;const m=buf.match(/ws:\/\/127\.0\.0\.1:(\d+)\//);if(m)port=+m[1];});
  const done=c=>{try{ch.kill();}catch(e){}setTimeout(()=>{try{fs.rmSync(dir,{recursive:true,force:true});}catch(e){}process.exit(c);},200);};
  setTimeout(()=>{console.error('timeout');done(1);},60000).unref();
  for(let i=0;i<200&&!port;i++)await sleep(100);
  if(!port){console.error('Chrome did not start');return done(1);}
  const tab=await (await fetch('http://127.0.0.1:'+port+'/json/new?about:blank',{method:'PUT'})).json();
  const ws=new WebSocket(tab.webSocketDebuggerUrl);await new Promise(r=>ws.onopen=r);
  let id=0;const waits={};
  ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id&&waits[m.id])waits[m.id](m);};
  const send=(method,params={})=>new Promise(r=>{const i=++id;waits[i]=r;ws.send(JSON.stringify({id:i,method,params}));});
  await send('Page.enable');
  const merged=new Map();
  for(const [name,w,h] of sizes){
    await send('Emulation.setDeviceMetricsOverride',{width:w,height:h,deviceScaleFactor:1,mobile:false});
    await send('Page.navigate',{url:target});
    let ready=false;
    for(let k=0;k<100&&!ready;k++){await sleep(100);
      const r=await send('Runtime.evaluate',{expression:"document.readyState==='complete'",returnByValue:true});ready=r.result&&r.result.result&&r.result.result.value;}
    await sleep(200);
    const r=await send('Runtime.evaluate',{expression:probe,returnByValue:true});
    if(!r.result||!r.result.result||!Array.isArray(r.result.result.value)){console.error('probe failed');return done(1);}
    for(const [kind,s,a,b] of r.result.result.value){
      const key=kind+'|'+s;const m=merged.get(key)||{kind,s,sizes:{},where:[]};m.sizes[name]=[a,b];m.where.push(name);merged.set(key,m);}
  }
  const text={wide:'wider than the viewport',clipped:'text clipped by overflow hidden',overlap:'text boxes overlap',hscroll:'page scrolls horizontally'};
  const order={hscroll:0,wide:1,clipped:2,overlap:3};
  const rows=[...merged.values()].sort((x,y)=>order[x.kind]-order[y.kind]);
  const lines=rows.map(m=>{
    const where=m.where.length===sizes.length?'both':m.where[0];const sz=m.sizes[m.where[0]];
    const size=m.kind==='overlap'?sz[0]+'x'+sz[1]+' shared':m.kind==='hscroll'?sz[0]+' px in '+sz[1]+' px':sz[0]+'x'+sz[1];
    return where+' '+m.s+' '+size+' '+text[m.kind];});
  if(lines.length>14){const n=lines.length-13;lines.length=13;lines.push('... '+n+' more');}
  console.log(lines.join('\n'));
  done(0);
})().catch(e=>{console.error(String(e));process.exit(1);});
JS
}

layout_run() {
  local target="${1:-}" browser out
  browser="$(find_browser)" || { echo "FAIL no Chrome, Edge or Chromium found, set WARMD_BROWSER"; return 1; }
  command -v node >/dev/null 2>&1 || { echo "FAIL warmd layout needs node"; return 1; }
  if [ -z "$target" ]; then
    if [ -f "$PROJECT/index.html" ] && ! has_script dev; then target="file:///$(native_path "$PROJECT/index.html")"
    elif command -v a_start_server >/dev/null 2>&1; then a_start_server || return 1; target="$(server_url)"
    else echo "FAIL give a url or an html file"; return 1; fi
  elif [ -f "$target" ]; then target="file:///$(native_path "$(cd "$(dirname "$target")" && pwd)/$(basename "$target")")"
  fi
  mkdir -p "$RUN"; layout_js > "$RUN/layout.cjs"
  out="$(node "$(native_path "$RUN/layout.cjs")" "$(native_path "$browser")" "$target" 2>"$RUN/layout.log")" \
    || { echo "FAIL layout probe: $(grep -m1 . "$RUN/layout.log" | cut -c1-160)"; return 1; }
  # 14 problem lines plus the summary stay within 15 lines
  if [ -z "$out" ]; then echo "OK $(secs)s layout no problems at 1440 and 390 px"; else echo "$out"; echo "FOUND $(echo "$out" | wc -l | tr -d ' ') layout problems"; return 1; fi
}
