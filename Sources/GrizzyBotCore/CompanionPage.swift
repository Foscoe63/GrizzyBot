import Foundation

/// The companion's single page: a mobile web app. It keeps the token in this browser only, polls while
/// open, and can be added to the Home Screen. No third-party code, no external requests.
enum CompanionPage {
    static let html = #"""
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="GrizzyBot">
<meta name="theme-color" content="#111113">
<title>GrizzyBot</title>
<style>
:root{color-scheme:dark;--bg:#111113;--card:#1b1b1f;--line:#2a2a30;--text:#f2f2f4;--mute:#9a9aa5;--accent:#e65707;--ok:#34c759}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px -apple-system,system-ui,sans-serif;padding:env(safe-area-inset-top) 16px env(safe-area-inset-bottom)}
header{display:flex;align-items:center;gap:10px;padding:14px 0}h1{font-size:20px;margin:0;flex:1}
button{font:inherit;color:var(--text);background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 14px}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}button.danger{color:#ff6b57}
input,textarea{width:100%;font:inherit;color:var(--text);background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px;margin:10px 0}
.row{display:flex;gap:8px;align-items:center}.grow{flex:1}.mute{color:var(--mute);font-size:13px}
.msg{padding:10px 12px;border-radius:14px;margin:8px 0;white-space:pre-wrap;word-wrap:break-word}.you{background:#2b2b31;margin-left:36px}.bot{background:var(--card);margin-right:36px;border:1px solid var(--line)}
.dot{width:9px;height:9px;border-radius:50%;background:var(--mute);display:inline-block}.dot.busy{background:var(--ok)}.dot.wait{background:var(--accent)}
.pending{border-color:var(--accent)}pre{white-space:pre-wrap;word-wrap:break-word;margin:6px 0;font:13px ui-monospace,monospace;color:var(--mute)}
</style></head>
<body><div id="app"></div>
<script>
const $=(s,e=document)=>e.querySelector(s);const app=$('#app');
let token=localStorage.getItem('gb-token')||'',bot=null,timer=null;
// Scanning the pairing QR code opens /#token=…; the fragment never leaves the browser.
{const m=location.hash.match(/token=([0-9a-f]+)/i);if(m){token=m[1];localStorage.setItem('gb-token',token);history.replaceState(null,'',location.pathname)}}
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function api(path,body){
  const r=await fetch(path,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
  if(r.status===401){token='';localStorage.removeItem('gb-token');render();throw new Error('unauthorized')}
  if(r.status===429)throw new Error('Too many attempts. Wait a minute.');
  return r.json();
}
function login(msg){
  app.innerHTML=`<header><h1>GrizzyBot</h1></header><div class="card"><p class="mute">Enter the companion token from GrizzyBot → Settings → Connections → Phone companion.</p>
  <input id="t" type="password" placeholder="Token" autocomplete="off"><p class="mute" id="m">${esc(msg||'')}</p><button class="primary" id="go">Connect</button></div>`;
  $('#go').onclick=async()=>{token=$('#t').value.trim();localStorage.setItem('gb-token',token);try{await api('/api/bots');render()}catch(e){login(e.message==='unauthorized'?'That token did not work.':e.message)}};
}
async function home(){
  const [b,p]=await Promise.all([api('/api/bots'),api('/api/pending')]);
  let h=`<header><h1>GrizzyBot</h1><button id="out">Sign out</button></header>`;
  for(const a of p.pending){h+=`<div class="card pending"><b>${esc(a.botName)} is waiting</b><div class="mute">${esc(a.tool)}</div><pre>${esc(a.detail)}</pre>`+
    (a.here?`<div class="row"><button class="primary grow" data-a="allow" data-b="${esc(a.bot)}">Allow</button><button class="danger grow" data-a="deny" data-b="${esc(a.bot)}">Deny</button></div>`:`<div class="mute">Answer this one at your Mac.</div>`)+`</div>`}
  for(const x of b.bots){h+=`<div class="card row" data-open="${esc(x.id)}"><span class="dot ${x.waiting?'wait':(x.status==='running'?'busy':'')}"></span><div class="grow"><b>${esc(x.name)}</b><div class="mute">${esc(x.title||x.status)}</div></div><span class="mute">›</span></div>`}
  app.innerHTML=h;
  $('#out').onclick=()=>{token='';localStorage.removeItem('gb-token');render()};
  app.querySelectorAll('[data-open]').forEach(e=>e.onclick=()=>{bot=e.dataset.open;render()});
  app.querySelectorAll('[data-a]').forEach(e=>e.onclick=async()=>{e.disabled=true;await api('/api/approve',{bot:e.dataset.b,decision:e.dataset.a});home()});
}
async function chat(){
  const c=await api('/api/chat?bot='+encodeURIComponent(bot)+'&limit=30');
  const draft=$('#d')?$('#d').value:'';
  let h=`<header><button id="back">‹</button><h1>${esc(c.status||'Chat')}</h1><button id="stop">Stop</button></header>`;
  for(const m of c.messages){const you=m.startsWith('[you]');h+=`<div class="msg ${you?'you':'bot'}">${esc(m.replace(/^\[[^\]]*\]\s*/,''))}</div>`}
  h+=`<div class="row" style="position:sticky;bottom:12px;background:var(--bg);padding:8px 0"><textarea id="d" rows="2" placeholder="Message">${esc(draft)}</textarea><button class="primary" id="s">Send</button></div>`;
  app.innerHTML=h;window.scrollTo(0,document.body.scrollHeight);
  $('#back').onclick=()=>{bot=null;render()};
  $('#stop').onclick=async()=>{await api('/api/stop',{bot});chat()};
  $('#s').onclick=async()=>{const t=$('#d').value.trim();if(!t)return;$('#d').value='';await api('/api/send',{bot,text:t});setTimeout(chat,600)};
}
function render(){
  clearInterval(timer);
  if(!token)return login();
  const tick=()=>(bot?chat():home()).catch(e=>{if(e.message!=='unauthorized')app.insertAdjacentHTML('afterbegin','<p class="mute">'+esc(e.message)+'</p>')});
  tick();timer=setInterval(()=>{if(!document.hidden&&!(bot&&document.activeElement&&document.activeElement.id==='d'&&$('#d').value))tick()},4000);
}
render();
</script></body></html>
"""#
}
