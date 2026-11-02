import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from support import audit, report, process

WEBHOOK = 'https://open.feishu.cn/open-apis/bot/v2/hook/test-token'


class Response:
    def __init__(self, status=200, body=b'{"code":0}'):
        self.status, self.body = status, body

    def read(self, _limit):
        return self.body


class Connection:
    response = Response()
    sent = []

    def __init__(self, *_args, **_kwargs):
        pass

    def request(self, _method, _path, body, _headers):
        self.sent.append(json.loads(body.decode()))

    def getresponse(self):
        return self.response

    def close(self):
        pass


class AlertTests(unittest.TestCase):
    def setUp(self):
        Connection.response, Connection.sent = Response(), []

    def test_sign_matches_official_empty_message_hmac(self):
        # Fixed golden vector from OpenSSL, not from the function under test.
        self.assertEqual(audit.signature('example-secret', '1600000000'),
                         'G9OzrXYoaWqzD4aN573Y4rQrWGp+3qVKNRjgZJPwc5s=')

    def test_unsigned_and_signed_robot_payload(self):
        for secret in (None, 'test-secret'):
            with patch.object(audit.http.client, 'HTTPSConnection', Connection), \
                    patch.object(audit.time, 'time', return_value=1600000000):
                result = audit.send_alert(report('VULNERABLE'), WEBHOOK, secret)
            self.assertEqual(result['status'], 'SENT')
            payload = Connection.sent[-1]
            self.assertEqual('sign' in payload, secret is not None)
            if secret:
                self.assertEqual(payload['timestamp'], '1600000000')

    def test_or_condition_and_unknown_opt_in(self):
        o = audit.parser().parse_args([])
        self.assertTrue(audit.should_alert(report('VULNERABLE'), o))
        r = report('FIXED')
        r['mptcp_processes'] = [process()]
        self.assertTrue(audit.should_alert(r, o))
        self.assertFalse(audit.should_alert(report('UNKNOWN'), o))
        o.alert_unknown = True
        self.assertTrue(audit.should_alert(report('UNKNOWN'), o))
        r = report()
        r['socket_detection_before']['status'] = 'DETECTION_UNAVAILABLE'
        self.assertTrue(audit.should_alert(r, o))
        o.alert_mode = 'none'
        self.assertFalse(audit.should_alert(report('VULNERABLE'), o))

    def test_always_green_only_when_evidence_is_clear(self):
        self.assertEqual(audit.alert_card(report())['card']['header']['template'], 'green')
        self.assertEqual(audit.alert_card(report('UNKNOWN'))['card']['header']['template'], 'orange')
        self.assertEqual(audit.alert_card(report('VULNERABLE'))['card']['header']['template'], 'red')

    def test_card_shows_only_ten_processes_and_no_cmdline(self):
        r = report()
        r['mptcp_processes'] = [process(i) for i in range(13)]
        r['mptcp_processes'][0]['cmdline_redacted'] = '--secret never-send-me'
        card = json.dumps(audit.alert_card(r), ensure_ascii=False)
        self.assertEqual(card.count('PID='), 10)
        self.assertIn('另有 3', card)
        self.assertNotIn('never-send-me', card)

    def test_retry_http_500_business_error_and_no_redirect(self):
        for response, attempts in ((Response(500), 3), (Response(302), 1),
                (Response(200, b'{"code":19021,"msg":"test-token"}'), 1),
                (Response(200, b'not json'), 3), (Response(200, b'{}'), 1)):
            Connection.response = response
            with patch.object(audit.http.client, 'HTTPSConnection', Connection), patch.object(audit.time, 'sleep'):
                result = audit.send_alert(report('VULNERABLE'), WEBHOOK, None)
            self.assertEqual(result['status'], 'FAILED')
            self.assertEqual(result['attempts'], attempts)
            self.assertNotIn('test-token', json.dumps(result))

    def test_send_failure_does_not_mask_local_risk_exit_code(self):
        r = report('VULNERABLE')
        with patch.object(audit.http.client, 'HTTPSConnection', side_effect=OSError('test-token')), \
                patch.object(audit.time, 'sleep'):
            r['alert'] = audit.send_alert(r, WEBHOOK, 'secret')
        self.assertEqual(audit.exit_code(r), 1)
        self.assertEqual(r['alert']['status'], 'FAILED')
        self.assertNotIn('test-token', json.dumps(r))

    def test_https_allowlist_rejects_ssrf_and_query(self):
        for url in ('http://open.feishu.cn/open-apis/bot/v2/hook/a',
                    'https://127.0.0.1/open-apis/bot/v2/hook/a',
                    WEBHOOK + '?token=x', WEBHOOK.replace('open.feishu.cn', 'open.feishu.cn.evil.org'),
                    WEBHOOK.replace('open.feishu.cn', 'user@open.feishu.cn')):
            with self.assertRaises(ValueError):
                audit.webhook_target(url)

    def test_protected_credential_file(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'secret'
            path.write_text('a-private-secret\n')
            os.chmod(str(path), 0o600)
            self.assertEqual(audit.protected_secret(str(path)), 'a-private-secret')
            os.chmod(str(path), 0o644)
            with self.assertRaises(ValueError):
                audit.protected_secret(str(path))
            link = Path(temp) / 'link'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                audit.protected_secret(str(link))

    def test_conflicting_arguments_fail(self):
        with patch('sys.stderr'):
            for flags in (['--check-only', '--disable-mptcp'], ['--no-remediation', '--disable-mptcp'],
                          ['--no-alert', '--alert-mode', 'always']):
                with self.assertRaises(SystemExit) as error:
                    audit.parser().parse_args(flags)
                self.assertEqual(error.exception.code, 2)


if __name__ == '__main__':
    unittest.main()
