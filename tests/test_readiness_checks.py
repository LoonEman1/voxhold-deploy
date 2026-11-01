from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReadinessChecksTests(unittest.TestCase):
    def test_watchdog_probes_readyz_and_tls_expiry(self):
        text = (ROOT / 'watchdog.sh').read_text(encoding='utf-8')
        self.assertIn('/readyz', text)
        self.assertIn('TLS certificate expires', text)
        self.assertIn('RestartCount', text)

    def test_updater_requires_readyz_after_healthy(self):
        text = (ROOT / 'update.sh').read_text(encoding='utf-8')
        self.assertIn('http://127.0.0.1:8080/readyz', text)
        self.assertLess(text.index('did not report healthy'), text.index('/readyz'))


if __name__ == '__main__':
    unittest.main()
