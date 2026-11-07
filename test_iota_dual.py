"""Offline configuration/preflight tests; never install or start a real proxy."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
