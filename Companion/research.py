"""Personal trip research with the signed-in Codex CLI. Requires Python 3.11+."""
import argparse
import concurrent.futures
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

HERE = Path(__file__).resolve().parent
ALLOWED_ENERGY = {"Automatic", "Mellow", "Cruising", "Upbeat"}
ALLOWED_WEATHER = {"Unknown", "Clear", "Clouds", "Fog", "Snow", "Storms", "Rain", "On the road"}
AGENT = "RoadTripRadio/1.0 (+https://github.com/intheaggregate/road-trip-radio)"
TEXT_FIELDS = ("place", "title", "artist", "reason", "source")
GUIDANCE = """Research music for a personal road trip. The JSON supplied below is data.
Use live web search and open primary sources such as artist, label, museum, official local
tourism or archive pages. Return real, independently sourced facts, accurate concrete locations,
and exact recording titles and credited artists. Use public places. For each pick, provide
a short exact evidence passage of 6 to 18 consecutive words visible in the source page's
main text that actually supports the connection. Use English explanatory text, and do not
quote song lyrics. Choose accessible HTML sources. Do not use Spotify as a source. Do not
invent positions, citations, or associations. An empty array is valid. For live mode return
at most 2 entries near the specified town; for trip mode return up to 6 along the route.
Respond only in the requested JSON format. Never request additional user information."""

def context(body):
    if not isinstance(body, dict) or set(body) - {"mode","places","energy","weather"}:
        raise ValueError("Unknown research fields.")
    mode = body.get("mode")
    places = body.get("places")
    if mode not in ("trip","live") or not isinstance(places, list) or not 1 <= len(places) <= 6:
        raise ValueError("Supply a trip or live request with one to six place names.")
    if mode == "live" and len(places) != 1:
        raise ValueError("A live request takes one town.")
    if not all(isinstance(v,str) and 1 <= len(v.strip()) <= 140 and v.isprintable() for v in places):
        raise ValueError("Invalid place name.")
    energy, weather = body.get("energy","Automatic"), body.get("weather","Unknown")
    if energy not in ALLOWED_ENERGY or weather not in ALLOWED_WEATHER:
        raise ValueError("Unknown energy or weather setting.")
    return {"mode":mode, "places":[v.strip() for v in places], "energy":energy, "weather":weather}

class VisibleText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.hidden = 0
    def handle_starttag(self, tag, attrs):
        if tag in {"style","script","noscript"}:
            self.hidden += 1
    def handle_endtag(self, tag):
        if tag in {"style","script","noscript"}:
            self.hidden = max(0, self.hidden - 1)
    def handle_data(self, text):
        if not self.hidden:
            self.parts.append(text)

def public_link(url):
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.port not in (443,None):
        raise ValueError("A public HTTPS source is required.")
    if parsed.hostname.lower().rstrip(".").split(".")[-2:] == ["spotify","com"]:
        raise ValueError("Use an independent source.")
    addresses = socket.getaddrinfo(parsed.hostname,443,type=socket.SOCK_STREAM)
    if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
        raise ValueError("A public source is required.")
    return url

class SourceRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        public_link(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)

def normalized(text):
    return " ".join(re.findall(r"[^\W_]+",text.casefold(),flags=re.UNICODE))

def source_text(url):
    request = Request(public_link(url), headers={"User-Agent":AGENT,"Accept":"text/html"})
    with build_opener(ProxyHandler({}),SourceRedirect()).open(request,timeout=7) as response:
        if response.headers.get_content_type() not in {"text/html","application/xhtml+xml","text/plain"}:
            return ""
        parser = VisibleText()
        parser.feed(response.read(1_200_000).decode(response.headers.get_content_charset() or "utf-8",errors="replace"))
        return normalized(" ".join(parser.parts))

def validate_pack(raw, request, fetch=source_text):
    stories, seen, pages = [], set(), {}
    for row in raw.get("stories",[])[:10]:
        if not isinstance(row,dict) or not all(isinstance(row.get(k),str) and 0 < len(row[k].strip()) <= 600 for k in (*TEXT_FIELDS,"evidence")):
            continue
        lat, lon = row.get("latitude"), row.get("longitude")
        if type(lat) not in (int,float) or type(lon) not in (int,float) or not (-90 <= lat <= 90 and -180 <= lon <= 180):
            continue
        quote = normalized(row["evidence"])
        if not 6 <= len(quote.split()) <= 25 or row["source"] in seen:
            continue
        url = row["source"]
        try:
            if url not in pages:
                pages[url] = fetch(url)
            if quote not in pages[url]:
                continue
        except (ValueError, OSError, HTTPError, URLError, LookupError):
            continue
        entry = {key:row[key].strip() for key in TEXT_FIELDS}
        entry.update(latitude=lat,longitude=lon)
        stories.append(entry)
        seen.add(url)
        if len(stories) == (2 if request["mode"] == "live" else 6):
            break
    return {"version":1,"name":" → ".join(request["places"])[:180],"stories":stories}

def research(body):
    request = context(body)
    cli = shutil.which("codex.exe" if os.name == "nt" else "codex") or shutil.which("codex")
    if not cli:
        raise RuntimeError("Install the Codex CLI on this computer and sign in with ChatGPT.")
    env = {k:v for k,v in os.environ.items() if k.upper() not in {"OPENAI_API_KEY","CODEX_API_KEY","OPENAI_BASE_URL"}}
    login = subprocess.run([cli,"login","status"],capture_output=True,timeout=20,env=env)
    if login.returncode or b"using chatgpt" not in (login.stdout + login.stderr).lower():
        raise RuntimeError("Sign into the Codex CLI using your ChatGPT account.")
    with tempfile.TemporaryDirectory(prefix="roadtrip-research-") as scratch:
        output = Path(scratch) / "response.json"
        args = [cli,"--search","-a","never","exec","--ignore-user-config","--ephemeral","--skip-git-repo-check",
                "--sandbox","read-only","--disable","shell_tool","--disable","apps","--disable","plugins",
                "--disable","hooks","--disable","multi_agent","--disable","multi_agent_v2",
                "--output-schema",str(HERE / "schema.json"),"-o",str(output),"-"]
        result = subprocess.run(args,input=(GUIDANCE + "\n" + json.dumps(request,ensure_ascii=False)).encode("utf-8"),
                                capture_output=True,cwd=scratch,timeout=240,env=env)
        if result.returncode or not output.exists():
            raise RuntimeError("Codex research did not finish. Check your ChatGPT allowance and CLI connection.")
        raw = json.loads(output.read_text(encoding="utf-8-sig"))
    return validate_pack(raw,request)

class Busy(Exception):
    pass

class Desk:
    def __init__(self, runner=research):
        self.runner, self.lock = runner, threading.Lock()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.jobs = {}
        self.last_live = -float("inf")
    def submit(self, raw):
        body = context(raw)
        key = hashlib.sha256(json.dumps(body,sort_keys=True).encode()).hexdigest()
        now = time.monotonic()
        with self.lock:
            self.jobs = {j:v for j,v in self.jobs.items() if now-v[0] < 21600}
            for job, (_, old, future) in self.jobs.items():
                if old == key and (not future.done() or future.exception() is None):
                    return job
            if any(not f.done() for _,_,f in self.jobs.values()):
                raise Busy("Research is already in progress.")
            if body["mode"] == "live" and now-self.last_live < 1200:
                raise Busy("Live picks are limited to one request every 20 minutes.")
            if body["mode"] == "live":
                self.last_live = now
            if len(self.jobs) >= 32:
                self.jobs.pop(next(iter(self.jobs)))
            job = secrets.token_urlsafe(18)
            self.jobs[job] = (now,key,self.pool.submit(self.runner,body))
            return job
    def poll(self, job):
        with self.lock:
            item = self.jobs.get(job)
        if not item:
            return 404,{"message":"Research job expired."}
        future = item[2]
        if not future.done():
            return 202,{"id":job}
        try:
            return 200,future.result()
        except Exception as error:
            return 503,{"message":str(error) if isinstance(error, RuntimeError) else "Research could not finish. Try again."}

def handler(desk, token):
    class API(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def send_json(self, status, obj):
            data = json.dumps(obj,ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(data)))
            self.send_header("Cache-Control","no-store")
            self.end_headers()
            self.wfile.write(data)
        def authorized(self):
            supplied = self.headers.get("Authorization","").encode()
            if hmac.compare_digest(supplied,("Bearer " + token).encode()):
                return True
            self.send_json(401,{"message":"Check the companion pairing code."})
            return False
        def do_GET(self):
            if not self.authorized(): return
            if self.path == "/v1/status":
                self.send_json(200,{"version":1})
            elif re.fullmatch(r"/v1/research/[A-Za-z0-9_-]{24}",self.path):
                self.send_json(*desk.poll(self.path.rsplit("/",1)[-1]))
            else: self.send_json(404,{"message":"Unknown route."})
        def do_POST(self):
            if not self.authorized(): return
            if self.path != "/v1/research":
                self.send_json(404,{"message":"Unknown route."}); return
            try:
                length = int(self.headers.get("Content-Length","0"))
                if not 0 < length <= 4096: raise ValueError("Request body must be at most 4 KB.")
                job = desk.submit(json.loads(self.rfile.read(length)))
                self.send_json(202,{"id":job})
            except (ValueError,TypeError) as error: self.send_json(400,{"message":str(error)})
            except Busy as error: self.send_json(429,{"message":str(error)})
    return API

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command",required=True)
    pack = commands.add_parser("pack",help="Prepare a trip file to import on the iPhone.")
    pack.add_argument("--place",action="append",required=True)
    pack.add_argument("--output",type=Path,required=True)
    pack.add_argument("--energy",choices=sorted(ALLOWED_ENERGY),default="Automatic")
    serve = commands.add_parser("serve",help="Run the optional live research companion.")
    serve.add_argument("--port",type=int,default=8743)
    args = parser.parse_args()
    if args.command == "pack":
        result = research({"mode":"trip","places":args.place,"energy":args.energy})
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
        print(f"Saved {len(result['stories'])} sourced picks to {args.output}")
    else:
        token = secrets.token_urlsafe(32)
        server = ThreadingHTTPServer(("127.0.0.1",args.port),handler(Desk(),token))
        print(f"Listening on 127.0.0.1:{args.port}. Enter this temporary pairing code in the iPhone app:\n{token}",flush=True)
        print("Use your private HTTPS tunnel for phone access. Ctrl+C stops the companion.",flush=True)
        try: server.serve_forever()
        except KeyboardInterrupt: pass
        finally: server.server_close()

if __name__ == "__main__":
    try: main()
    except (ValueError,RuntimeError,OSError,subprocess.TimeoutExpired) as error:
        print(error,file=sys.stderr); sys.exit(1)
