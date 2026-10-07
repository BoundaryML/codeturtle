import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import reporting
import git_input


class ReportingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        event = {'repository': {'id': 42, 'full_name': 'acme/repo'}, 'pull_request': {'number': 7, 'head': {'sha': 'a'*40}, 'base': {'sha': 'b'*40, 'repo': {'id': 42}}}}
        path = Path(self.tmp.name)/'event.json'
        path.write_text(json.dumps(event))
        self.env = {'GITHUB_ACTIONS':'true','GITHUB_EVENT_NAME':'pull_request_target','GITHUB_EVENT_PATH':str(path),'GITHUB_REPOSITORY':'acme/repo','GITHUB_REPOSITORY_ID':'42','GITHUB_RUN_ID':'123','GITHUB_RUN_ATTEMPT':'1','CODETURTLE_API_URL':'https://turtle.example','ACTIONS_ID_TOKEN_REQUEST_URL':'https://x.actions.githubusercontent.com/token','ACTIONS_ID_TOKEN_REQUEST_TOKEN':'secret'}
        self.reporter = reporting.Reporter(self.env)
        self.grant = {'identity': self.reporter.identity, 'run_id':'12345678-1234-1234-1234-123456789abc','token':'t'*64,'expires_at':int(time.time())+900,'merge_base':'c'*40,'title':'PR'}

    def test_context(self):
        self.assertEqual(self.reporter.identity['base'],'b'*40)
        for key, value in [('GITHUB_EVENT_NAME','pull_request'),('GITHUB_REPOSITORY_ID','43'),('GITHUB_RUN_ATTEMPT','0')]:
            with self.subTest(key=key), self.assertRaises(reporting.ReportingError):
                reporting.ci_context(dict(self.env, **{key:value}))

    def test_origins(self):
        for url in ['http://example.com','https://user:pass@example.com','https://example.com#frag','http://localhost']:
            with self.assertRaises(reporting.ReportingError): reporting.checked_url(url,True)
        self.assertEqual(reporting.checked_url('http://127.0.0.1:123',True),'http://127.0.0.1:123')

    def test_register_and_renew_immutable(self):
        with patch.object(self.reporter,'request',side_effect=[{'value':'jwt'},self.grant]):
            self.assertEqual(self.reporter.register(),self.grant)
        with patch.object(self.reporter,'request',side_effect=[{'value':'jwt'},dict(self.grant,title='changed')]),self.assertRaises(reporting.ReportingError): self.reporter.register()

    def test_stable_upload(self):
        self.reporter.grant=self.grant
        bodies=[]
        def request(url, method, token, body, expected):
            bodies.append(body)
            return {'run_id':self.grant['run_id'],'digest':hashlib.sha256(body).hexdigest(),'status_url':url.removesuffix('/report'),'accepted_at':'now'}
        with patch.object(self.reporter,'request',side_effect=request):
            self.reporter.upload(report={'evaluation_complete':False})
            self.reporter.upload(report={'evaluation_complete':False})
            with self.assertRaises(reporting.ReportingError): self.reporter.upload(report={'evaluation_complete':True})
        self.assertEqual(bodies[0],bodies[1])

    def test_bad_receipt(self):
        self.reporter.grant=self.grant
        with patch.object(self.reporter,'request',return_value={}),self.assertRaises(reporting.ReportingError): self.reporter.upload(setup_failure='fail')

    def test_expired_grant_renews(self):
        self.reporter.grant=dict(self.grant,expires_at=0)
        def register(): self.reporter.grant=self.grant
        with patch.object(self.reporter,'register',side_effect=register) as renew,patch.object(self.reporter,'request',return_value={}):
            with self.assertRaises(reporting.ReportingError): self.reporter.upload(setup_failure='fail')
            renew.assert_called_once()

    def test_forbidden_overrides(self):
        with patch('sys.argv',['codeturtle','check','--report','--base','main']),contextlib.redirect_stderr(io.StringIO()): self.assertEqual(git_input.main(),3)

    def test_credentials_removed(self):
        with patch.dict(os.environ,{'ACTIONS_ID_TOKEN_REQUEST_TOKEN':'secret','GITHUB_TOKEN':'secret','GH_TOKEN':'secret','OPENAI_API_KEY':'model'}),patch('subprocess.run',return_value=subprocess.CompletedProcess([],0,'{}','')) as run:
            git_input.run_baml([])
        env=run.call_args.kwargs['env']
        self.assertFalse(any(k.startswith(('ACTIONS_','GITHUB_','GH_')) for k in env))
        self.assertEqual(env['OPENAI_API_KEY'],'model')

    def test_redirect_not_followed(self):
        self.assertIsNone(reporting.NoRedirect().redirect_request(None,None,302,'',{},'https://evil.test'))

    def test_transient_retries_same_bytes(self):
        response = unittest.mock.MagicMock()
        response.__enter__.return_value=response
        response.status=202
        response.read.return_value=b'{}'
        opener=unittest.mock.Mock()
        opener.open.side_effect=[reporting.urllib.error.URLError('secret'),response]
        with patch('urllib.request.build_opener',return_value=opener),patch('time.sleep'):
            reporting.request_json('https://turtle.example','PUT','secret',b'payload',(202,))
        self.assertEqual([call.args[0].data for call in opener.open.call_args_list],[b'payload',b'payload'])

if __name__=='__main__': unittest.main()
