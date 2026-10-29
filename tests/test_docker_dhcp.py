"""Regression tests for real HA functions; FTL HTTP boundary uses a local fixture."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


def function(path, name):
    lines = path.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line == name + '() {')
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == '}')
    return '\n'.join(lines[start:end + 1])


class DockerDhcpTests(unittest.TestCase):
    def invoke(self, platform='docker', active='true', patch_status=200):
        events = []

        class Fixture(http.server.BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def handle_request(self):
                size = int(self.headers.get('Content-Length', 0))
                body = json.loads(self.rfile.read(size)) if size else None
                events.append((self.command, self.path, body, self.headers.get('sid')))
                code = patch_status if self.command == 'PATCH' else 200
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'session': {'valid': True, 'sid': 'fixture-session'}}).encode())

            do_POST = do_PATCH = do_DELETE = handle_request

        server = http.server.HTTPServer(('127.0.0.1', 0), Fixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        password = 'fixture-quote"-backslash\\-password'
        try:
            with tempfile.TemporaryDirectory(prefix='ha-dhcp-test-') as temp:
                trace = Path(temp) / 'cli'
                script = 'set -uo pipefail\npihole-FTL() { printf "%s\\n" "$*" >> "$TRACE"; }\n'
                script += function(ROOT / 'pihole-ha-platform', 'platform_set_dhcp')
                script += '\nplatform_set_dhcp "$ACTIVE"\n'
                env = dict(os.environ, PIHOLE_HA_PLATFORM=platform,
                           PIHOLE_WEB_PORT=str(server.server_port), PIHOLE_PASSWORD=password,
                           ACTIVE=active, TRACE=str(trace))
                result = subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)
                cli = trace.read_text() if trace.exists() else ''
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        return result, events, cli, password

    def assert_api_activation(self, active):
        result, events, cli, password = self.invoke(active=active)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(cli, '', 'Docker must not only write the disk config through CLI')
        self.assertEqual([(e[0], e[1]) for e in events],
                         [('POST', '/api/auth'), ('PATCH', '/api/config'), ('DELETE', '/api/auth')])
        self.assertEqual(events[0][2], {'password': password})
        self.assertEqual(events[1][2], {'config': {'dhcp': {'active': active == 'true'}}})
        self.assertEqual(events[1][3], 'fixture-session')
        self.assertEqual(events[2][3], 'fixture-session')

    def test_docker_enable_changes_running_ftl_via_api(self):
        self.assert_api_activation('true')

    def test_docker_disable_changes_running_ftl_via_api(self):
        self.assert_api_activation('false')

    def test_patch_failure_is_reported_and_session_closed(self):
        result, events, _, _ = self.invoke(patch_status=500)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events[-1][0:2], ('DELETE', '/api/auth'))

    def test_systemd_keeps_original_cli_path(self):
        result, events, cli, _ = self.invoke(platform='systemd')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, [])
        self.assertEqual(cli.strip(), '--config dhcp.active true')

    def options(self, enabled):
        script = 'set -uo pipefail\n' + function(ROOT / 'pihole-ha', 'build_dns_option')
        script += '\nVIP_ENABLED="$ENABLED"; VIP=192.0.2.9; NODES=(192.0.2.5 192.0.2.6); build_dns_option\n'
        return subprocess.check_output(['bash', '-c', script],
                                       env=dict(os.environ, ENABLED=enabled), text=True).strip()

    def test_vip_is_dns_only_without_forging_server_identifier(self):
        self.assertEqual(self.options('true'), 'dhcp-option=6,192.0.2.9')

    def test_without_vip_advertises_both_dns_servers(self):
        self.assertEqual(self.options('false'), 'dhcp-option=6,192.0.2.5,192.0.2.6')


if __name__ == '__main__':
    unittest.main()
