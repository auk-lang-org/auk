"""A stand-in for an rpm registry (rpm.auk-lang.org), for the raft tests: the three calls raft
makes, kept in memory. Prints `port <n>` once it is listening on 127.0.0.1.

  GET  /api/v1/packages/<name>                     the package's versions
  GET  /api/v1/packages/<name>/<version>/download  one version's files, base64
  POST /api/v1/packages                            publish (Authorization: Bearer rpm_test)
"""
import base64, hashlib, json, re
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = "rpm_test"
packages = {}  # name -> [{"version", "checksum", "yanked", "files"}], oldest first


def checksum(files):
    h = hashlib.sha256()
    for f in sorted(files, key=lambda f: f["path"]):
        data = base64.b64decode(f["base64"])
        h.update(f["path"].encode() + b"\0" + len(data).to_bytes(8, "big") + data)
    return "sha256:" + h.hexdigest()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if parts[:3] != ["api", "v1", "packages"] or len(parts) not in (4, 6):
            return self.reply(404, {"error": "no such endpoint"})
        versions = packages.get(parts[3])
        if versions is None:
            return self.reply(404, {"error": "no package `%s`" % parts[3]})
        if len(parts) == 4:
            listed = [{k: v[k] for k in ("version", "checksum", "yanked")} for v in reversed(versions)]
            return self.reply(200, {"name": parts[3], "versions": listed})
        for v in versions:
            if v["version"] == parts[4] and parts[5] == "download":
                return self.reply(200, {"checksum": v["checksum"], "files": v["files"]})
        self.reply(404, {"error": "no such version"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/yank":  # test control: {"name", "version"}
            want = json.loads(body)
            for v in packages[want["name"]]:
                if v["version"] == want["version"]:
                    v["yanked"] = True
            return self.reply(200, {})
        if self.path != "/api/v1/packages":
            return self.reply(404, {"error": "no such endpoint"})
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.reply(401, {"error": "publishing needs an API token"})
        files = json.loads(body)["files"]
        manifest = next(base64.b64decode(f["base64"]).decode() for f in files if f["path"] == "raft.toml")
        name = re.search(r'^name = "(.*)"', manifest, re.M).group(1)
        version = re.search(r'^version = "(.*)"', manifest, re.M).group(1)
        versions = packages.setdefault(name, [])
        if any(v["version"] == version for v in versions):
            return self.reply(422, {"error": "%s %s is already published" % (name, version)})
        entry = {"version": version, "checksum": checksum(files), "yanked": False, "files": files}
        versions.append(entry)
        self.reply(201 if len(versions) == 1 else 200, {"name": name, "version": version, "checksum": entry["checksum"]})


server = HTTPServer(("127.0.0.1", 0), Handler)
print("port %d" % server.server_address[1], flush=True)
server.serve_forever()
