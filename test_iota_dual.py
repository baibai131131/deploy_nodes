"""Offline configuration/preflight tests; never install or start a real proxy."""
import json
import http.client
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

import yaml


SCRIPT = Path(__file__).with_name("deploy_iota_dual_test.sh").resolve()


def bash(body, **env):
    return subprocess.run(
        ["bash", "-c", 'source "$1"\n' + body, "test", str(SCRIPT)],
        env={**os.environ, **env}, text=True, capture_output=True, check=False,
    )


class InstallerTests(unittest.TestCase):
    def test_bash_syntax(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_source_does_not_install(self):
        result = bash("echo sourced")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "sourced")

    def test_ports(self):
        for port in ["1", "443", "8443", "65535"]:
            with self.subTest(port=port):
                self.assertEqual(bash('valid_port "$PORT"', PORT=port).returncode, 0)
        for port in ["0", "65536", "999999999999", "443/tcp", "-1", "08", "", "1;true"]:
            with self.subTest(port=port):
                self.assertNotEqual(bash('valid_port "$PORT"', PORT=port).returncode, 0)

    def test_ip_validation(self):
        self.assertEqual(bash("is_public_ipv4 8.8.8.8").returncode, 0)
        for ip in ["127.0.0.1", "192.168.1.1", "203.0.113.1", "::1", "1.2.3.999", "not-an-ip"]:
            with self.subTest(ip=ip):
                self.assertNotEqual(bash('is_public_ipv4 "$IP"', IP=ip).returncode, 0)

    def test_missing_marker_blocks_uninstall(self):
        with tempfile.TemporaryDirectory() as temp:
            result = bash('BASE="$TEST_DIR"\nuninstall_server', TEST_DIR=temp)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing to delete", result.stderr)
            self.assertTrue(Path(temp).is_dir())

    def test_existing_installation_blocks_overwrite(self):
        with tempfile.TemporaryDirectory() as temp:
            result = bash('BASE="$TEST_DIR"\ncheck_fresh_server', TEST_DIR=temp)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("No files were overwritten", result.stderr)

    def test_port_check_is_protocol_specific(self):
        result = bash('''
ss() {
  if [[ "$*" == *-ltn* ]]; then echo 'LISTEN 0 1 0.0.0.0:443 0.0.0.0:*'; fi
}
port_in_use tcp 443
! port_in_use udp 443
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_generated_configs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "config").mkdir()
            (root / "units").mkdir()
            result = bash('''
BASE="$TEST_DIR"
UNIT_DIR="$TEST_DIR/units"
EXPORT_YAML="$TEST_DIR/client.yaml"
EXPORT_INFO="$TEST_DIR/info.txt"
HY_PORT=443
REALITY_PORT=443
PUBLIC_IP=8.8.8.8
HY_PASSWORD=test-auth-password
OBFS_PASSWORD=test-obfs-password
VLESS_UUID=82239e8d-ff14-417e-8111-c1ec09fda302
PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
SHORT_ID=1234567812345678
SNI=www.apple.com
CERT_PIN=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
# Render as current user, without creating a host service account.
chown() { :; }
write_server_configs
write_units
write_client_files
''', TEST_DIR=temp)
            self.assertEqual(result.returncode, 0, result.stderr)
            hy = yaml.safe_load((root / "config/hy2.yaml").read_text())
            xr = json.loads((root / "config/reality.json").read_text())
            client = yaml.safe_load((root / "client.yaml").read_text())
            self.assertTrue(hy["ignoreClientBandwidth"])
            self.assertFalse(hy["disableUDP"])
            self.assertNotIn("bandwidth", hy)
            self.assertEqual(hy["congestion"]["bbrProfile"], "conservative")
            self.assertEqual(hy["udpIdleTimeout"], "300s")
            inbound = xr["inbounds"][0]
            self.assertEqual(inbound["port"], 443)
            self.assertEqual(inbound["streamSettings"]["security"], "reality")
            self.assertNotIn("flow", inbound["settings"]["clients"][0])
            hnode, rnode = client["proxies"]
            self.assertEqual(len(client["proxies"]), 2)
            self.assertFalse(hnode["skip-cert-verify"])
            self.assertEqual(len(hnode["fingerprint"]), 64)
            self.assertNotIn("up", hnode)
            self.assertNotIn("down", hnode)
            self.assertNotIn("flow", rnode)
            self.assertTrue(rnode["udp"])
            self.assertEqual(rnode["packet-encoding"], "xudp")
            self.assertFalse(rnode["smux"]["enabled"])
            self.assertIsInstance(rnode["reality-opts"]["short-id"], str)
            self.assertEqual(client["proxy-groups"][0]["type"], "select")
            self.assertNotIn("dns", client)
            self.assertNotIn("tun", client)
            self.assertEqual((root / "client.yaml").stat().st_mode & 0o777, 0o600)
            self.assertEqual((root / "config/reality.json").stat().st_mode & 0o777, 0o640)
            for kind in ["hy2", "reality"]:
                unit = (root / f"units/iota-dual-{kind}.service").read_text()
                self.assertIn("User=iota-dual", unit)
                self.assertIn("Restart=on-failure", unit)
                self.assertIn("ProtectSystem=strict", unit)
                self.assertNotIn("User=root", unit)

    def test_cleanup_targets_only_own_journal(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / "managed-by").write_text("iota-dual-test-v1\n")
            result = bash('''
BASE="$TEST_DIR"
require_root() { :; }
journalctl() { printf 'JOURNAL %s\n' "$*"; }
maintain_server
''', TEST_DIR=temp)
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = [line for line in result.stdout.splitlines() if line.startswith("JOURNAL ")]
            self.assertEqual(len(commands), 2)
            self.assertTrue(all("--namespace=iota-dual" in command for command in commands))
            self.assertTrue(any("--vacuum-time=7d" in command for command in commands))

    def test_maintenance_configuration_and_no_proxy_restart(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "units").mkdir()
            for unit in ["hy2", "reality"]:
                (root / f"units/iota-dual-{unit}.service").touch()
            result = bash('''
BASE="$TEST_DIR"
UNIT_DIR="$TEST_DIR/units"
JOURNAL_CONFIG="$TEST_DIR/journal/limits.conf"
systemctl() { printf 'SYSTEMCTL %s\n' "$*"; }
setup_maintenance
''', TEST_DIR=temp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("restart", "\n".join(line for line in result.stdout.splitlines() if line.startswith("SYSTEMCTL ")))
            limits = (root / "journal/limits.conf").read_text()
            self.assertIn("SystemMaxUse=100M", limits)
            self.assertIn("MaxRetentionSec=7day", limits)
            for unit in ["hy2", "reality"]:
                self.assertIn("LogNamespace=iota-dual", (root / f"units/iota-dual-{unit}.service.d/20-iota-journal.conf").read_text())

    def test_no_destructive_cache_or_connection_commands(self):
        content = SCRIPT.read_text()
        for forbidden in ["/proc/sys/vm/drop_caches", "conntrack -F", "iptables -F", "swapoff", "apt-get autoremove"]:
            self.assertNotIn(forbidden, content)

    def test_certbot_and_renewal_are_isolated(self):
        content = SCRIPT.read_text()
        self.assertIn('--required-profile shortlived --ip-address "$PUBLIC_IP"', content)
        self.assertIn('"$BASE/acme-venv/bin/certbot" renew', content)
        self.assertIn('--config-dir "$BASE/acme/config"', content)
        self.assertIn('--no-cache-dir', content)
        self.assertNotIn('url = "http://', content)
        self.assertIn('url = "https://$PUBLIC_IP', content)
        self.assertNotIn('curl -k', content)


class SubscriptionTests(unittest.TestCase):
    """Real loopback HTTPS tests; test CA only, no external ACME or systemd."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.token = "a" * 64
        cls.payload = b"proxies:\n  - name: test\n    type: direct\n"
        result = bash('BASE="$TEST_DIR"\nwrite_subscription_program', TEST_DIR=cls.temp.name)
        if result.returncode:
            raise RuntimeError(result.stderr)
        cls.program = cls.root / "subscription_server.py"
        compile(cls.program.read_text(), str(cls.program), "exec")
        subprocess.run([
            "openssl", "req", "-x509", "-nodes", "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:P-256", "-days", "1",
            "-keyout", str(cls.root / "server.key"), "-out", str(cls.root / "server.crt"),
            "-subj", "/CN=IOTA local test only", "-addext", "subjectAltName=IP:127.0.0.1",
        ], check=True, capture_output=True)
        cls.context = ssl.create_default_context(cafile=str(cls.root / "server.crt"))
        (cls.root / "clash.yaml").write_bytes(cls.payload)
        cls.port, cls.process = cls.launch(cls.root, time.time() + 60)
        for _ in range(100):
            try:
                cls.request(f"/{cls.token}/clash.yaml")
                break
            except OSError:
                time.sleep(0.02)
        else:
            cls.process.terminate()
            raise RuntimeError(cls.process.communicate(timeout=2))

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        stdout, stderr = cls.process.communicate(timeout=3)
        if cls.token in stdout + stderr:
            raise AssertionError("Bearer token leaked into server logs")
        cls.temp.cleanup()

    @classmethod
    def launch(cls, directory, expires):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        state = {"scheme": "https", "public_ip": "8.8.8.8", "port": port,
                 "expires_at": int(expires), "token": cls.token}
        (directory / "state.json").write_text(json.dumps(state))
        if directory != cls.root:
            (directory / "server.crt").write_bytes((cls.root / "server.crt").read_bytes())
            (directory / "server.key").write_bytes((cls.root / "server.key").read_bytes())
        process = subprocess.Popen(
            ["python3", str(cls.program), str(directory), "--bind", "127.0.0.1"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        return port, process

    @classmethod
    def request(cls, path, method="GET", port=None):
        connection = http.client.HTTPSConnection("127.0.0.1", port or cls.port, timeout=2, context=cls.context)
        try:
            connection.request(method, path)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_exact_subscription(self):
        status, headers, body = self.request(f"/{self.token}/clash.yaml")
        self.assertEqual(status, 200)
        self.assertEqual(body, self.payload)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertIn("application/yaml", headers["Content-Type"])

    def test_head(self):
        status, headers, body = self.request(f"/{self.token}/clash.yaml", "HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertEqual(int(headers["Content-Length"]), len(self.payload))

    def test_only_exact_path_is_available(self):
        paths = ["/", "/clash.yaml", "/wrong/clash.yaml", "/state.json",
                 "/../config/reality.json", "/%2e%2e/config/reality.json",
                 f"/{self.token}/state.json", f"/{self.token}/../state.json"]
        for path in paths:
            with self.subTest(path=path):
                status, _, body = self.request(path)
                self.assertEqual(status, 404)
                self.assertNotIn(self.payload, body)
                self.assertNotIn(self.token.encode(), body)

    def test_no_upload_method(self):
        self.assertEqual(self.request(f"/{self.token}/clash.yaml", "POST")[0], 501)

    def test_plain_http_cannot_download(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        try:
            with self.assertRaises((OSError, http.client.HTTPException)):
                connection.request("GET", f"/{self.token}/clash.yaml")
                connection.getresponse()
        finally:
            connection.close()

    def test_untrusted_certificate_is_rejected(self):
        connection = http.client.HTTPSConnection("127.0.0.1", self.port, timeout=2,
                                                context=ssl.create_default_context())
        try:
            with self.assertRaises(ssl.SSLCertVerificationError):
                connection.request("GET", f"/{self.token}/clash.yaml")
        finally:
            connection.close()

    def test_wrong_server_ip_is_rejected(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as raw:
            with self.assertRaises(ssl.SSLCertVerificationError):
                self.context.wrap_socket(raw, server_hostname="8.8.8.8")

    def test_multiple_imports(self):
        with ThreadPoolExecutor(max_workers=8) as executor:
            replies = list(executor.map(lambda _: self.request(f"/{self.token}/clash.yaml")[0], range(16)))
        self.assertEqual(replies, [200] * 16)

    def test_expired_server_does_not_start(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "clash.yaml").write_bytes(self.payload)
            _, process = self.launch(root, time.time() - 1)
            stdout, stderr = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertNotIn(self.token, stdout + stderr)

    def test_server_closes_at_expiry(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "clash.yaml").write_bytes(self.payload)
            port, process = self.launch(root, time.time() + 2)
            try:
                for _ in range(100):
                    try:
                        status, _, _ = self.request(f"/{self.token}/clash.yaml", port=port)
                        break
                    except OSError:
                        time.sleep(0.01)
                self.assertEqual(status, 200)
                process.communicate(timeout=4)
                self.assertEqual(process.returncode, 0)
                with self.assertRaises(OSError):
                    self.request(f"/{self.token}/clash.yaml", port=port)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
