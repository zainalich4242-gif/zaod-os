#!/usr/bin/env bash
set -Eeuo pipefail

# ZAOD OS Part 5: native, GitHub-backed App Store.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="${ROOTFS:-${SCRIPT_DIR}/chroot}"

 die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup_mounts() {
    local mountpoint
    for mountpoint in /dev/pts /sys /proc /dev; do
        if mountpoint -q "${ROOTFS}${mountpoint}"; then
            umount -R "${ROOTFS}${mountpoint}" || true
        fi
    done
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./05-setup-app-store.sh"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "Run this on an amd64/x86_64 host."

ROOTFS="$(realpath -m -- "${ROOTFS}")"
[[ -f "${ROOTFS}/etc/debian_version" ]] || die "No Debian root filesystem found at ${ROOTFS}; run Parts 1-4 first."
grep -q '^12\.' "${ROOTFS}/etc/debian_version" || die "${ROOTFS} is not Debian 12 (Bookworm)."

mkdir -p "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev/pts"
trap cleanup_mounts EXIT
mount --bind /dev "${ROOTFS}/dev"
mount -t proc proc "${ROOTFS}/proc"
mount --rbind /sys "${ROOTFS}/sys"
mount --make-rslave "${ROOTFS}/sys"
mount -t devpts devpts "${ROOTFS}/dev/pts" 2>/dev/null || true

printf '%s\n' "Installing App Store runtime dependencies..."
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 \
    chromium \
    curl \
    ca-certificates

mkdir -p "${ROOTFS}/opt/zaod-store/assets" "${ROOTFS}/opt/zaod-store/config"

cat > "${ROOTFS}/opt/zaod-store/catalog.json" <<'EOF'
{
  "apps": [
    {
      "id": "zaod-studio",
      "name": "ZAOD Studio",
      "version": "1.0",
      "category": "Development",
      "description": "Create and build lightweight .zos application packages.",
      "icon_url": "",
      "screenshots": [],
      "download_url": "",
      "package_type": ".zos",
      "featured": true
    }
  ]
}
EOF

cat > "${ROOTFS}/opt/zaod-store/server.py" <<'PYEOF'
#!/usr/bin/python3
import json
import os
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

ROOT = '/opt/zaod-store'
PORT = 17631
REGISTRY = '/var/lib/zaod/installed.json'


class ZaodStoreHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        super().end_headers()

    def json_response(self, status, payload):
        body = json.dumps(payload).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/status':
            try:
                with open(REGISTRY, 'r', encoding='utf-8') as file:
                    registry = json.load(file)
            except Exception:
                registry = {'applications': {}}
            self.json_response(200, {'applications': registry.get('applications', {})})
            return
        super().do_GET()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        length = int(self.headers.get('Content-Length', '0'))
        try:
            payload = json.loads(self.rfile.read(length) or b'{}')
        except json.JSONDecodeError:
            self.json_response(400, {'ok': False, 'error': 'Invalid JSON'})
            return

        if parsed.path == '/api/install-url':
            url = payload.get('url')
            if not url or not urllib.parse.urlparse(url).scheme in ('http', 'https'):
                self.json_response(400, {'ok': False, 'error': 'Invalid package URL'})
                return
            name = os.path.basename(urllib.parse.urlparse(url).path) or 'zaod-package.zos'
            if not name.lower().endswith('.zos'):
                name += '.zos'
            target = os.path.join('/tmp', name)
            try:
                urllib.request.urlretrieve(url, target)
                result = subprocess.run(
                    ['/usr/local/bin/zos-install', target],
                    env={**os.environ, 'ZAOD_ZOS_AUTOINSTALL': '1'},
                    capture_output=True,
                    text=True,
                    timeout=300,
                )
                if result.returncode != 0:
                    self.json_response(500, {'ok': False, 'error': result.stderr or result.stdout})
                else:
                    self.json_response(200, {'ok': True, 'message': result.stdout.strip()})
            except Exception as exc:
                self.json_response(500, {'ok': False, 'error': str(exc)})
            return

        if parsed.path == '/api/remove':
            app_id = payload.get('id', '')
            if not app_id or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in app_id):
                self.json_response(400, {'ok': False, 'error': 'Invalid app id'})
                return
            result = subprocess.run(['/usr/local/bin/zos-remove', app_id], capture_output=True, text=True)
            self.json_response(200 if result.returncode == 0 else 500,
                                {'ok': result.returncode == 0,
                                 'message': (result.stdout or result.stderr).strip()})
            return

        self.json_response(404, {'ok': False, 'error': 'Unknown API endpoint'})


if __name__ == '__main__':
    os.chdir(ROOT)
    server = ThreadingHTTPServer(('127.0.0.1', PORT), ZaodStoreHandler)
    print(f'ZAOD Store listening on http://127.0.0.1:{PORT}', flush=True)
    server.serve_forever()
PYEOF
chmod 0755 "${ROOTFS}/opt/zaod-store/server.py"

cat > "${ROOTFS}/opt/zaod-store/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>ZAOD Store</title>
  <link rel="stylesheet" href="store.css">
</head>
<body>
  <aside class="sidebar">
    <div class="brand"><span class="brand-mark">Z</span><strong>ZAOD Store</strong></div>
    <nav>
      <button class="nav-item active" data-view="browse">Browse</button>
      <button class="nav-item" data-view="gaming">Gaming</button>
      <button class="nav-item" data-view="development">Development</button>
      <button class="nav-item" data-view="content">Content Creation</button>
      <button class="nav-item" data-view="utilities">Utilities</button>
      <button class="nav-item" data-view="developer">Developer Console</button>
    </nav>
  </aside>

  <main>
    <header class="topbar">
      <label class="search"><input id="search" type="search" placeholder="Search ZAOD apps" autocomplete="off"></label>
      <button id="settings" class="icon-button" title="Store settings">&#9881;</button>
    </header>

    <section id="browse-view" class="view active">
      <div class="section-heading"><div><span class="eyebrow">ZAOD Library</span><h1>Discover</h1></div></div>
      <div id="featured" class="featured"></div>
      <h2>Apps</h2>
      <div id="app-grid" class="grid"></div>
    </section>

    <section id="developer-view" class="view">
      <div class="section-heading"><div><span class="eyebrow">Creator tools</span><h1>Developer Console</h1></div></div>
      <form id="developer-form" class="developer-form">
        <fieldset>
          <legend>GitHub connection</legend>
          <label>Target repository<input id="repo" placeholder="owner/repo" required></label>
          <label>Personal access token<input id="token" type="password" placeholder="github_pat_..." required></label>
        </fieldset>
        <fieldset>
          <legend>Package details</legend>
          <div class="form-grid">
            <label>App name<input id="app-name" required></label>
            <label>App ID<input id="app-id" placeholder="lowercase-app-id" pattern="[a-z0-9-]+" required></label>
            <label>Version<input id="app-version" value="1.0" required></label>
            <label>Category<select id="app-category"><option>Gaming</option><option>Development</option><option>Content Creation</option><option>Utilities</option></select></label>
          </div>
          <label>Description<textarea id="app-description" rows="3" required></textarea></label>
        </fieldset>
        <fieldset>
          <legend>Files</legend>
          <div class="form-grid">
            <label>Icon (.png/.jpg)<input id="app-icon" type="file" accept="image/png,image/jpeg" required></label>
            <label>Screenshots<input id="app-screenshots" type="file" accept="image/*" multiple></label>
            <label>Package (.zos/.apk)<input id="app-package" type="file" accept=".zos,.apk" required></label>
          </div>
        </fieldset>
        <button class="primary" type="submit">Publish to GitHub</button>
        <div id="publish-status" class="status" role="status"></div>
      </form>
    </section>
  </main>

  <dialog id="store-settings">
    <form method="dialog">
      <h2>Store settings</h2>
      <label>GitHub catalog repository<input id="catalog-repo" placeholder="owner/repo"></label>
      <label>Catalog branch<input id="catalog-branch" value="main"></label>
      <button class="primary" id="save-settings" value="default">Save</button>
      <button value="cancel">Cancel</button>
    </form>
  </dialog>
  <script src="store.js"></script>
</body>
</html>
EOF

cat > "${ROOTFS}/opt/zaod-store/store.css" <<'EOF'
:root { color-scheme: dark; --bg:#08111e; --panel:#0e1a2a; --panel2:#13243a; --text:#edf4fb; --muted:#9fb2c7; --accent:#1688df; --accent2:#72dfff; }
* { box-sizing:border-box; }
body { margin:0; height:100vh; overflow:hidden; background:linear-gradient(145deg,#07101b 0%,#0a1728 58%,#10243a 100%); color:var(--text); font:14px/1.45 "Noto Sans", "Segoe UI", sans-serif; }
body::before { content:""; position:fixed; inset:-20%; background:radial-gradient(circle at 72% 18%,rgba(22,136,223,.22),transparent 32%); pointer-events:none; }
button,input,select,textarea { font:inherit; }
.sidebar { position:fixed; left:0; top:0; bottom:0; width:230px; padding:18px 12px; border-right:1px solid rgba(255,255,255,.08); background:rgba(7,16,27,.82); backdrop-filter:blur(16px); }
.brand { height:44px; display:flex; align-items:center; gap:10px; padding:0 8px; }
.brand-mark { width:30px; height:30px; display:grid; place-items:center; border-radius:7px; background:var(--accent); font-weight:800; }
nav { display:flex; flex-direction:column; gap:4px; margin-top:14px; }
.nav-item { height:40px; border:0; border-radius:6px; padding:0 12px; text-align:left; color:var(--muted); background:transparent; cursor:pointer; }
.nav-item:hover,.nav-item.active { color:white; background:rgba(114,223,255,.10); }
main { margin-left:230px; height:100vh; overflow:auto; position:relative; }
.topbar { position:sticky; z-index:10; top:0; height:68px; display:flex; align-items:center; justify-content:space-between; padding:12px 28px; border-bottom:1px solid rgba(255,255,255,.06); background:rgba(8,17,30,.78); backdrop-filter:blur(18px); }
.search { width:min(520px,62vw); }
.search input { width:100%; height:40px; border:1px solid rgba(255,255,255,.10); border-radius:6px; padding:0 14px; color:white; background:rgba(255,255,255,.06); outline:none; }
.search input:focus { border-color:var(--accent); }
.icon-button { width:38px; height:38px; border:0; border-radius:6px; color:var(--muted); background:transparent; cursor:pointer; }
.view { display:none; padding:26px 28px 48px; }.view.active { display:block; }
.section-heading { display:flex; align-items:end; justify-content:space-between; }.eyebrow { color:var(--accent2); font-size:12px; text-transform:uppercase; }.section-heading h1 { margin:2px 0 18px; font-size:32px; }
.featured { min-height:190px; display:grid; grid-template-columns:repeat(3,1fr); gap:14px; }
.feature-card { min-height:190px; position:relative; overflow:hidden; border:1px solid rgba(255,255,255,.08); border-radius:8px; padding:22px; background:linear-gradient(135deg,rgba(22,136,223,.72),rgba(16,36,58,.94)); }
.feature-card::after { content:""; position:absolute; width:220px; height:220px; right:-80px; bottom:-100px; border:1px solid rgba(114,223,255,.25); transform:rotate(32deg); }.feature-card h3 { margin:16px 0 4px; }.feature-card p { max-width:65%; color:#d5e3ef; }
h2 { margin:26px 0 12px; font-size:18px; }.grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(210px,1fr)); gap:12px; }
.app-card { min-height:220px; border:1px solid rgba(255,255,255,.08); border-radius:8px; padding:14px; background:rgba(19,36,58,.72); }
.app-card .icon { width:64px; height:64px; object-fit:cover; border-radius:12px; background:#10243f; }.app-card h3 { margin:12px 0 3px; }.app-card .description { height:42px; overflow:hidden; color:var(--muted); font-size:12px; }.meta { display:flex; justify-content:space-between; color:#aebed0; font-size:12px; }
.primary,.secondary { height:36px; border-radius:5px; padding:0 13px; cursor:pointer; }.primary { border:1px solid #319bf0; background:#1688df; color:white; }.secondary { border:1px solid rgba(255,255,255,.12); background:rgba(255,255,255,.06); color:white; }.card-actions { display:flex; gap:8px; margin-top:10px; }
.developer-form { max-width:760px; }.developer-form fieldset { margin:0 0 14px; border:1px solid rgba(255,255,255,.10); border-radius:8px; }.developer-form legend { color:var(--accent2); }.developer-form label { display:flex; flex-direction:column; gap:6px; margin:10px 0; color:var(--muted); }.developer-form input,.developer-form select,.developer-form textarea { border:1px solid rgba(255,255,255,.11); border-radius:5px; padding:9px; background:rgba(255,255,255,.06); color:white; }.form-grid { display:grid; grid-template-columns:1fr 1fr; gap:10px 14px; }.status { min-height:20px; margin-top:10px; color:var(--accent2); }
dialog { width:min(460px,calc(100vw - 40px)); border:1px solid rgba(255,255,255,.12); border-radius:8px; background:#10243a; color:white; }dialog label { display:flex; flex-direction:column; gap:6px; margin:10px 0;}dialog input{border:1px solid rgba(255,255,255,.12);border-radius:5px;padding:9px;background:#07111f;color:white}
@media(max-width:800px){.sidebar{width:68px}.brand strong,.nav-item{text-indent:-999px}.brand-mark{margin:auto}.nav-item{padding:0}.nav-item::after{content:""}.nav-item.active{background:rgba(114,223,255,.12)}main{margin-left:68px}.featured{grid-template-columns:1fr}.form-grid{grid-template-columns:1fr}}
EOF

cat > "${ROOTFS}/opt/zaod-store/store.js" <<'EOF'
const fallbackCatalog = {apps:[{id:'zaod-studio',name:'ZAOD Studio',version:'1.0',category:'Development',description:'Create and build lightweight .zos application packages.',icon_url:'',screenshots:[],download_url:'',package_type:' .zos'.trim(),featured:true}]};
let catalog = fallbackCatalog;
let installed = {};

const settingsKey = 'zaod-store-settings';
const developerKey = 'zaod-store-developer';

function getSettings(){try{return JSON.parse(localStorage.getItem(settingsKey)||'{}')}catch(e){return {}}}
function saveSettings(value){localStorage.setItem(settingsKey,JSON.stringify(value));}

async function loadInstalled(){
  try{const response=await fetch('/api/status',{cache:'no-store'});const data=await response.json();installed=data.applications||{};}catch(e){installed={};}
}

async function loadCatalog(){
  const settings=getSettings();
  if(!settings.repo)return;
  const branch=encodeURIComponent(settings.branch||'main');
  const url=`https://raw.githubusercontent.com/${settings.repo}/${branch}/catalog.json`;
  try{
    const response=await fetch(url,{cache:'no-store'});
    if(!response.ok)throw new Error('Catalog unavailable');
    catalog=await response.json();
  }catch(e){catalog=fallbackCatalog;}
}

function escapeHtml(value){const el=document.createElement('span');el.textContent=value==null?'':String(value);return el.innerHTML}

function appIcon(app){return app.icon_url||'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" rx="12" fill="%2310243f"/><text x="32" y="40" text-anchor="middle" fill="white" font-family="sans-serif" font-size="20">Z</text></svg>'}

function render(){
  const query=(document.getElementById('search').value||'').trim().toLowerCase();
  const activeView=document.querySelector('.nav-item.active').dataset.view;
  let apps=(catalog.apps||[]).filter(app=>{
    const matchesQuery=!query||(app.name||'').toLowerCase().includes(query)||(app.description||'').toLowerCase().includes(query);
    const matchesView=activeView==='browse'||activeView==='gaming'&&app.category==='Gaming'||activeView==='development'&&app.category==='Development'||activeView==='content'&&app.category==='Content Creation'||activeView==='utilities'&&app.category==='Utilities';
    return matchesQuery&&matchesView;
  });
  const featured=document.getElementById('featured');
  featured.innerHTML=(catalog.apps||[]).filter(app=>app.featured).slice(0,3).map(app=>`<article class="feature-card"><small>${escapeHtml(app.category)}</small><h3>${escapeHtml(app.name)}</h3><p>${escapeHtml(app.description)}</p>${action(app)}</article>`).join('')||'';
  document.getElementById('app-grid').innerHTML=apps.map(app=>`<article class="app-card"><img class="icon" src="${escapeHtml(appIcon(app))}" alt=""><h3>${escapeHtml(app.name)}</h3><div class="meta"><span>${escapeHtml(app.category)}</span><span>${escapeHtml(app.version)}</span></div><p class="description">${escapeHtml(app.description)}</p><div class="card-actions">${action(app)}</div></article>`).join('')||'<p>No matching apps.</p>';
}

function action(app){
  if(installed[app.id])return `<button class="secondary" data-action="remove" data-id="${escapeHtml(app.id)}">Uninstall</button><button class="primary" disabled>Installed</button>`;
  if(app.package_type=== '.apk'.trim())return `<a class="primary" href="${escapeHtml(app.download_url)}" download style="display:grid;place-items:center;text-decoration:none">Download</a>`;
  if(app.download_url)return `<button class="primary" data-action="install" data-url="${escapeHtml(app.download_url)}">Install</button>`;
  return '<button class="secondary" disabled>Not published</button>';
}

async function installUrl(url){
  const card=[...document.querySelectorAll('[data-action="install"]')].find(button=>button.dataset.url===url);
  if(card){card.disabled=true;card.textContent='Installing...';}
  const response=await fetch('/api/install-url',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url})});
  const data=await response.json();
  await loadInstalled();render();
  alert(data.ok?data.message:data.error||'Installation failed');
}

async function removeApp(id){
  if(!confirm('Uninstall this app?'))return;
  const response=await fetch('/api/remove',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})});
  const data=await response.json();await loadInstalled();render();
  alert(data.ok?data.message:data.error||'Uninstall failed');
}

document.addEventListener('click',event=>{
  const nav=event.target.closest('.nav-item');
  if(nav){document.querySelectorAll('.nav-item').forEach(item=>item.classList.remove('active'));nav.classList.add('active');document.querySelectorAll('.view').forEach(view=>view.classList.remove('active'));document.getElementById(nav.dataset.view==='browse'?'browse-view':'developer-view').classList.add('active');render();return;}
  const actionButton=event.target.closest('[data-action]');
  if(actionButton?.dataset.action==='install')installUrl(actionButton.dataset.url);
  if(actionButton?.dataset.action==='remove')removeApp(actionButton.dataset.id);
});
document.getElementById('search').addEventListener('input',render);

const dialog=document.getElementById('store-settings');
document.getElementById('settings').addEventListener('click',()=>{const s=getSettings();document.getElementById('catalog-repo').value=s.repo||'';document.getElementById('catalog-branch').value=s.branch||'main';dialog.showModal();});
document.getElementById('save-settings').addEventListener('click',()=>saveSettings({repo:document.getElementById('catalog-repo').value.trim(),branch:document.getElementById('catalog-branch').value.trim()||'main'}));

async function githubApi(token,method,path,body){
  const response=await fetch('https://api.github.com'+path,{method,headers:{Authorization:'Bearer '+token,Accept:'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
  const text=await response.text();let data={};try{data=JSON.parse(text)}catch(e){data={message:text}}
  if(!response.ok)throw new Error(data.message||'GitHub API request failed');return data;
}

function base64File(file){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result.split(',')[1]);reader.onerror=reject;reader.readAsDataURL(file);});}

document.getElementById('developer-form').addEventListener('submit',async event=>{
  event.preventDefault();
  const status=document.getElementById('publish-status');
  const repo=document.getElementById('repo').value.trim();
  const token=document.getElementById('token').value.trim();
  const id=document.getElementById('app-id').value.trim();
  const version=document.getElementById('app-version').value.trim();
  const app={id,name:document.getElementById('app-name').value.trim(),version,category:document.getElementById('app-category').value,description:document.getElementById('app-description').value.trim(),icon_url:'',screenshots:[],download_url:'',package_type:''};
  const icon=document.getElementById('app-icon').files[0];
  const packageFile=document.getElementById('app-package').files[0];
  const screenshots=[...document.getElementById('app-screenshots').files];
  if(!repo||!token||!icon||!packageFile)return;
  app.package_type=packageFile.name.toLowerCase().endsWith('.apk')?'.apk':'.zos';
  saveSettings({repo,branch:getSettings().branch||'main'});localStorage.setItem(developerKey,JSON.stringify({repo}));
  try{
    status.textContent='Uploading icon...';
    const repoInfo=await githubApi(token,'GET','/repos/'+repo);const branch=getSettings().branch||repoInfo.default_branch||'main';
    const putAsset=async(path,file)=>{const content=await base64File(file);await githubApi(token,'PUT','/repos/'+repo+'/contents/'+encodeURI(path),{message:'Add ZAOD Store asset '+path,content,branch});return `https://raw.githubusercontent.com/${repo}/${branch}/${path}`};
    app.icon_url=await putAsset(`assets/${id}/icon.png`,icon);
    for(let i=0;i<screenshots.length;i++)app.screenshots.push(await putAsset(`assets/${id}/screen-${i+1}-${screenshots[i].name}`,screenshots[i]));

    status.textContent='Creating GitHub release...';
    const tag=`v${version}-${id}`;
    let release;
    try{release=await githubApi(token,'GET','/repos/'+repo+'/releases/tags/'+encodeURIComponent(tag));}
    catch(e){release=await githubApi(token,'POST','/repos/'+repo+'/releases',{tag_name:tag,name:`${app.name} ${version}`,body:`Published by ZAOD Studio`,draft:false,prerelease:false});}
    const uploadUrl=release.upload_url.split('{')[0];
    const binary=await base64File(packageFile);const binaryBytes=Uint8Array.from(atob(binary),c=>c.charCodeAt(0));
    const uploadResponse=await fetch(uploadUrl+'?name='+encodeURIComponent(packageFile.name),{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':packageFile.type||'application/octet-stream','X-GitHub-Api-Version':'2022-11-28'},body:binaryBytes});
    const asset=await uploadResponse.json();if(!uploadResponse.ok)throw new Error(asset.message||'Package upload failed');app.download_url=asset.browser_download_url;

    status.textContent='Updating catalog.json...';
    let catalogData={apps:[app]};let sha;
    try{const response=await githubApi(token,'GET','/repos/'+repo+'/contents/catalog.json?ref='+encodeURIComponent(branch));catalogData=JSON.parse(atob(response.content.replace(/\n/g,'')));sha=response.sha;if(!Array.isArray(catalogData.apps))catalogData.apps=[];}catch(e){catalogData={apps:[app]};}
    const index=catalogData.apps.findIndex(item=>item.id===id);if(index>=0)catalogData.apps[index]=app;else catalogData.apps.push(app);
    await githubApi(token,'PUT','/repos/'+repo+'/contents/catalog.json',{message:`Publish ${app.name} ${version} to ZAOD Store`,content:btoa(unescape(encodeURIComponent(JSON.stringify(catalogData,null,2)+'\n'))),branch,...(sha?{sha}: {})});
    saveSettings({repo,branch});catalog=catalogData;await loadInstalled();render();status.textContent=`Published ${app.name} ${version}`;
  }catch(error){status.textContent='Publish failed: '+error.message;}
});

(async()=>{const saved=getSettings();if(saved.repo)document.getElementById('catalog-repo').value=saved.repo;if(saved.branch)document.getElementById('catalog-branch').value=saved.branch;const dev=(()=>{try{return JSON.parse(localStorage.getItem(developerKey)||'{}')}catch(e){return {}}})();if(dev.repo)document.getElementById('repo').value=dev.repo;await loadInstalled();await loadCatalog();render();})();
EOF

cat > "${ROOTFS}/usr/local/bin/zaod-store" <<'EOF'
#!/bin/bash
set -e
SERVER_PID=""
cleanup() {
    [[ -n "${SERVER_PID}" ]] && kill "${SERVER_PID}" 2>/dev/null || true
}
trap cleanup EXIT
/usr/bin/python3 /opt/zaod-store/server.py >/tmp/zaod-store.log 2>&1 &
SERVER_PID=$!
for attempt in $(seq 1 30); do
    curl -fsS http://127.0.0.1:17631/ >/dev/null 2>&1 && break
    sleep 0.1
done
exec /usr/bin/chromium --app=http://127.0.0.1:17631/ --process-per-site --disable-gpu-shader-disk-cache --disk-cache-size=33554432 --enable-features=UseSkiaRenderer
EOF
chmod 0755 "${ROOTFS}/usr/local/bin/zaod-store"

cat > "${ROOTFS}/usr/share/applications/zaod-store.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZAOD Store
Comment=Browse, install, and manage ZAOD applications
Exec=/usr/local/bin/zaod-store
Icon=system-software-install
Terminal=false
Categories=Utility;
StartupNotify=true
EOF

printf '%s\n' "Cleaning apt caches and temporary files..."
chroot "${ROOTFS}" apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"* "${ROOTFS}/tmp/"*

cleanup_mounts
trap - EXIT

printf '\nPart 5 complete. ZAOD Store installed at /opt/zaod-store\n'
