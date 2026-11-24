#!/usr/bin/python3
import json
import os
import subprocess
import tempfile
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT='/opt/aura-desktop'
PORT=17632
COMMANDS={
 'browser':['chromium','--process-per-site','--disable-gpu-shader-disk-cache','--disk-cache-size=33554432'],
 'files':['thunar'],
 'terminal':['xfce4-terminal'],
 'camera':['guvcview'],
 'notes':['mousepad'],
 'settings':['xfce4-settings-manager'],
 'store':['/usr/local/bin/zaod-store'],
 'usb':['pkexec','/usr/local/bin/zaod-usb-tool'],
 'gallery':['ristretto'],
 'studio':['/usr/local/bin/zaod-studio'],
 'logout':['xfce4-session-logout','--logout','--fast'],
}

class Handler(BaseHTTPRequestHandler):
 def end_headers(self):
  self.send_header('Cache-Control','no-store')
  super().end_headers()
 def send_json(self,status,payload):
  body=json.dumps(payload).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def do_GET(self):
  path=urllib.parse.urlparse(self.path).path
  if path=='/api/status':
   onboarded=os.path.exists('/var/lib/zaod/.onboarding_complete')
   self.send_json(200,{'onboarded':onboarded});return
  if path=='/' or path=='/index.html':
   path='/index.html'
  file_path=ROOT+path
  if not os.path.isfile(file_path):self.send_error(404);return
  mime='text/html' if file_path.endswith('.html') else 'application/octet-stream'
  data=open(file_path,'rb').read();self.send_response(200);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_POST(self):
  length=int(self.headers.get('Content-Length','0'));payload=json.loads(self.rfile.read(length) or b'{}')
  path=urllib.parse.urlparse(self.path).path
  if path=='/api/launch':
   name=payload.get('app','')
   command=COMMANDS.get(name)
   if not command:self.send_json(400,{'ok':False,'error':'Unknown app'});return
   try:
    subprocess.Popen(command,start_new_session=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    self.send_json(200,{'ok':True})
   except Exception as error:self.send_json(500,{'ok':False,'error':str(error)})
   return
  if path=='/api/onboard':
   full_name=str(payload.get('fullName','')).strip();username=str(payload.get('username','')).strip();password=str(payload.get('password',''))
   import re
   if len(full_name)<2 or len(full_name)>80 or '\n' in full_name:self.send_json(400,{'ok':False,'error':'Enter a valid full name.'});return
   if not re.fullmatch(r'[a-z][a-z0-9-]{0,31}',username):self.send_json(400,{'ok':False,'error':'Enter a valid lowercase username.'});return
   if len(password)<8 or ':' in password or '\n' in password:self.send_json(400,{'ok':False,'error':'Password must contain at least 8 characters.'});return
   fd,path=tempfile.mkstemp(prefix='zaod-account-',dir='/tmp');os.fchmod(fd,0o600)
   with os.fdopen(fd,'w') as stream:json.dump({'username':username,'full_name':full_name,'password':password},stream)
   try:
    result=subprocess.run(['pkexec','/usr/local/libexec/zaod-provision-user',path],capture_output=True,text=True,timeout=180)
    if result.returncode:self.send_json(500,{'ok':False,'error':result.stderr.strip() or 'Account setup failed.'})
    else:self.send_json(200,{'ok':True})
   finally:
    try:os.unlink(path)
    except OSError:pass
   return
  self.send_json(404,{'ok':False,'error':'Unknown API endpoint'})

if __name__=='__main__':ThreadingHTTPServer(('127.0.0.1',PORT),Handler).serve_forever()
