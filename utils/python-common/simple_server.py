import os
import sys
import time
import argparse
import threading
import webbrowser
import http.server
import socketserver

def open_browser(url):
    time.sleep(0.5)
    webbrowser.open(url)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Serve HTML files with Python\'s built-in HTTP server')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--file', '-f', type=str, help='HTML file path to serve directly')
    group.add_argument('--directory', '-d', type=str, help='Directory to serve files from')
    parser.add_argument('--port', '-p', type=int, default=8000, help='Port number (default: 8000)')
    parser.add_argument('--bind', '-b', type=str, default='127.0.0.1', help='Bind address (default: 127.0.0.1)')
    args = parser.parse_args()
    
    # Handle file path or directory
    if args.file:
        html_file_path = os.path.abspath(args.file)
        os.chdir(os.path.dirname(html_file_path))
        filename = os.path.basename(html_file_path)
        threading.Thread(target=open_browser, args=(f"http://{args.bind}:{args.port}/{filename}",), daemon=True).start()
    elif args.directory:
        os.chdir(args.directory)
    
    # Start server
    print(f"Serving at http://{args.bind}:{args.port}")
    print(f"Directory: {os.getcwd()}")
    print("Press Ctrl+C to stop")
    
    handler = http.server.SimpleHTTPRequestHandler
    with socketserver.TCPServer((args.bind, args.port), handler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nServer stopped")
            sys.exit(0) 