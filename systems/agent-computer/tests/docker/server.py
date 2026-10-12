from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        # Exercise both a workspace bind mount and a writable named volume.
        payload = Path("/fixture/message.txt").read_bytes()
        Path("/data/message.txt").write_bytes(payload)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(payload)


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
