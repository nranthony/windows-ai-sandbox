import http.server
import socketserver
import os

PORT = 80 # The port your HEALTHCHECK is looking for

class HealthCheckHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            # For any other path, return a 404
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not Found')

# Listen on all network interfaces
Handler = HealthCheckHandler
with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
    print(f"Serving at port {PORT}")
    httpd.serve_forever()