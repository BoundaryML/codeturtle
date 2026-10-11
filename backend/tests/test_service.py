"""Disposable PostgreSQL + real BAML HTTP service; provider traffic stays on loopback.
Run with CODETURTLE_TEST_SQL pointing to the operator handoff (.md or .sql).
Requires PostgreSQL 17 tools, BAML and the pinned crypto requirements.
"""
import concurrent.futures
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

ROOT=Path(__file__).resolve().parents[2]

class ServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sql_path=os.environ.get('CODETURTLE_TEST_SQL')
        if not sql_path: raise RuntimeError('Set CODETURTLE_TEST_SQL to the separate operator SQL handoff')
        cls.temp=tempfile.TemporaryDirectory(prefix='codeturtle_test_');cls.addClassCleanup(cls.temp.cleanup)
        cls.path=Path(cls.temp.name);cls.pg=cls.path/'pg';cls.sock=cls.path/'socket';cls.sock.mkdir()
        cls.pg_bin=os.environ.get('PG_BIN','/opt/homebrew/opt/postgresql@17/bin')
        cls.command([cls.pg_bin+'/initdb','-D',str(cls.pg),'-A','trust','--no-locale'])
        cls.command([cls.pg_bin+'/pg_ctl','-D',str(cls.pg),'-l',str(cls.path/'postgres.log'),'-o',f'-k {cls.sock} -h ""','-w','start'])
        cls.addClassCleanup(lambda: cls.command([cls.pg_bin+'/pg_ctl','-D',str(cls.pg),'-m','immediate','-w','stop']))
        cls.db='codeturtle_test_'+uuid.uuid4().hex
        cls.sql('CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;',database='postgres')
        cls.sql('CREATE DATABASE '+cls.db,database='postgres')
        sql=Path(sql_path).read_text();sql=sql.split('```sql\n')[1].split('```')[0] if '```sql' in sql else sql
        cls.sql(sql);cls.sql(sql) # setup is rerunnable
        review_sql_path=os.environ.get('CODETURTLE_TEST_REVIEW_SQL')
        if not review_sql_path: raise RuntimeError('Set CODETURTLE_TEST_REVIEW_SQL to the reviewer SQL update')
        update=Path(review_sql_path).read_text().split('```sql\n')[1].split('```')[0]
        cls.sql(update);cls.sql(update)
        refresh_sql_path=os.environ.get('CODETURTLE_TEST_REFRESH_SQL')
        if refresh_sql_path:
            refresh=Path(refresh_sql_path).read_text().split('```sql\n')[1].split('```')[0]
            cls.sql(refresh);cls.sql(refresh)
        performance=(ROOT/"backend/migrations/003_workspace_performance.sql").read_text()
        cls.sql(performance);cls.sql(performance)
        cls.key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        cls.pem=cls.key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()
        cls.jwk=json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(cls.key.public_key()));cls.jwk['kid']='test'
        (cls.path/'key.pem').write_text(cls.pem)
        cls.repo=cls.path/'repo';cls.repo.mkdir()
        cls.command(['git','init','-b','main',str(cls.repo)])
        policy=cls.repo/'.github/codeturtle';policy.mkdir(parents=True);(policy/'OWNERS').write_text('* @one\n')
        (cls.repo/'a.txt').write_text('before\n');cls.git('add','.');cls.git('commit','-m','Base');cls.base=cls.git('rev-parse','HEAD').strip()
        (cls.repo/'a.txt').write_text('after\n');cls.git('add','.');cls.git('commit','-m','Head');cls.head=cls.git('rev-parse','HEAD').strip()
        cls.identity={'repository_id':'42','repository':'acme/repo','pr':7,'run_id':'123','run_attempt':1,'head':cls.head,'base':cls.base,'policy':cls.base}
        cls.comments=[];cls.posts=0;cls.fail_post=False;cls.provider_down=False;cls.live_head=cls.head
        outer=cls
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                if self.path.startswith('/oidc'):
                    claims=outer.claims();self.send_json(200,{'value':jwt.encode(claims,outer.pem,algorithm='RS256',headers={'kid':'test'})})
                else:self.send_json(404,{})
            def do_POST(self):
                raw=self.rfile.read(int(self.headers.get('Content-Length','0')))
                data=json.loads(raw)
                try:
                    if self.path.startswith('/rest/v1/rpc/ct_'):
                        name=self.path.rsplit('/',1)[1]
                        if not name.replace('_','').isalnum():raise ValueError()
                        result=outer.rpc(name,data['p']);self.send_json(200,result)
                    elif self.path=='/provider':self.send_json(200,outer.provider(data))
                    else:self.send_json(404,{})
                except Exception as error:
                    if isinstance(error,subprocess.CalledProcessError): print(error.stderr,flush=True)
                    self.send_json(503,{'error':'fixture_failure'})
            def send_json(self,status,data):
                body=json.dumps(data).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        cls.mock=ThreadingHTTPServer(('127.0.0.1',0),Handler);cls.addClassCleanup(cls.mock.server_close);cls.addClassCleanup(cls.mock.shutdown)
        threading.Thread(target=cls.mock.serve_forever,daemon=True).start();cls.mock_url=f'http://127.0.0.1:{cls.mock.server_port}'
        sock=socket.socket();sock.bind(('127.0.0.1',0));cls.port=sock.getsockname()[1];sock.close();cls.origin=f'http://127.0.0.1:{cls.port}'
        cls.enrollment={'repository_id':'42','repository':'acme/repo','tenant_id':'tenant','installation_id':9,'workflow_ref':'acme/repo/.github/workflows/codeturtle.yml@refs/heads/main','workflow_blob':'c'*40,'active':True,'slack':None}
        cls.project=cls.path/'backend';shutil.copytree(ROOT/'backend/baml_src',cls.project/'baml_src');shutil.copy(ROOT/'backend/baml.toml',cls.project/'baml.toml')
        fixture='''class FixtureTransport { url: string, implements Transport { function send(self, method: string, url: string, token: string, payload: json) -> json { let r = baml.http.send(baml.http.Request.from_url(self.url + "/provider").set_method("POST").set_body(baml.json.stringify({"method": method, "url": url, "token": token, "payload": payload}))); require(r.status_code == 200, 503, "fixture_provider_unavailable"); baml.json.parse(r.text()) } } }
function test_main(addr: string, fixture_url: string, python: string, crypto_path: string, models_path: string, key_path: string, origin: string) -> never {
 let http = FixtureTransport {url: fixture_url}; let crypto = CryptoHelper {python: python, path: crypto_path};
 let app = ReportService {store: SupabaseStore {url: fixture_url, key: "fixture"}, github: GitHubClient {http: http, crypto: crypto, app_id: "test", private_key: baml.fs.read(key_path), bot_id: 999, tokens: bounded_cache(262144), contents: bounded_cache(16777216)}, oidc: GitHubOIDC {http: http, crypto: crypto, audience: origin}, parser: report_parser(models_path), origin: origin, slack: SlackClient {http: http, secrets: SecretBox {key: uint8array.zeroes(32)}}, browser: BrowserAuth {store: SupabaseStore {url: fixture_url, key: "fixture"}, http: http, origin: origin, client_id: "test", client_secret: "test", organization_id: "tenant", secrets: SecretBox {key: uint8array.zeroes(32)}}, onboarding: null};
 baml.http.Server.bind(addr).serve((req) -> {app.handle(req)}, max_body_size = 4194304)
}
function test_delivery(fixture_url: string, python: string, crypto_path: string, models_path: string, key_path: string, origin: string) -> void {
 let http = FixtureTransport {url: fixture_url}; let crypto = CryptoHelper {python: python, path: crypto_path};
 let app = ReportService {store: SupabaseStore {url: fixture_url, key: "fixture"}, github: GitHubClient {http: http, crypto: crypto, app_id: "test", private_key: baml.fs.read(key_path), bot_id: 999, tokens: bounded_cache(262144), contents: bounded_cache(16777216)}, oidc: GitHubOIDC {http: http, crypto: crypto, audience: origin}, parser: report_parser(models_path), origin: origin, slack: SlackClient {http: http, secrets: SecretBox {key: uint8array.zeroes(32)}}, browser: BrowserAuth {store: SupabaseStore {url: fixture_url, key: "fixture"}, http: http, origin: origin, client_id: "test", client_secret: "test", organization_id: "tenant", secrets: SecretBox {key: uint8array.zeroes(32)}}, onboarding: null}; app.deliver_once()
}'''
        (cls.project/'baml_src/fixture.baml').write_text(fixture)
        cls.env=dict(os.environ,BAML_VERSION='0.20.2-nightly.20261004.a',CODETURTLE_FRONTEND_DIR=str(ROOT/'frontend/dist'),CODETURTLE_GITHUB_CLIENT_ID='test',CODETURTLE_GITHUB_CLIENT_SECRET='test')
        cls.args=['--fixture_url',cls.mock_url,'--python',str(ROOT/'backend/.venv/bin/python'),'--crypto_path',str(ROOT/'backend/crypto.py'),'--models_path',str(ROOT/'cli/baml_src/models.baml'),'--key_path',str(cls.path/'key.pem'),'--origin',cls.origin]
        cls.log=open(cls.path/'service.log','w+');cls.addClassCleanup(cls.log.close)
        cls.start_service();cls.addClassCleanup(cls.stop_service)
    @classmethod
    def command(cls,args,**kwargs):
        return subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,**kwargs).stdout
    @classmethod
    def sql(cls,query,database=None):
        return cls.command([cls.pg_bin+'/psql','-X','-A','-t','-v','ON_ERROR_STOP=1','-h',str(cls.sock),'-d',database or cls.db],input=query).strip()
    @classmethod
    def rpc(cls,name,p):
        literal=json.dumps(p).replace("'","''")
        return json.loads(cls.sql("SELECT public."+name+"('"+literal+"'::jsonb)") or "null")
    @classmethod
    def git(cls,*args):
        return cls.command(['git','-C',str(cls.repo),'-c','user.name=Test','-c','user.email=test@example.test','-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null',*args])
    @classmethod
    def start_service(cls):
        cls.process=subprocess.Popen(['baml','--agent-skill-check','off','run','--project',str(cls.project),'test_main','--','--addr',f'127.0.0.1:{cls.port}',*cls.args],env=cls.env,stdout=cls.log,stderr=cls.log)
        for _ in range(100):
            if cls.process.poll() is not None:
                cls.log.seek(0);raise RuntimeError(cls.log.read())
            try:
                urllib.request.urlopen(cls.origin+'/healthz',timeout=.2).close();return
            except (OSError,urllib.error.URLError):time.sleep(.1)
        raise RuntimeError('BAML service did not start')
    @classmethod
    def stop_service(cls):
        if cls.process.poll() is None:
            cls.process.terminate()
            try:cls.process.wait(timeout=5)
            except subprocess.TimeoutExpired:cls.process.kill();cls.process.wait()
    @classmethod
    def claims(cls):
        return {'iss':'https://token.actions.githubusercontent.com','aud':cls.origin,'sub':'repo:acme/repo:ref:refs/heads/main','iat':int(time.time())-1,'exp':int(time.time())+120,'repository_id':'42','repository':'acme/repo','run_id':'123','run_attempt':'1','event_name':'pull_request_target','runner_environment':'github-hosted','sha':cls.base,'workflow_sha':cls.base,'workflow_ref':cls.enrollment['workflow_ref'],'ref':'refs/heads/main'}
    @classmethod
    def provider(cls,data):
        if cls.provider_down:raise ValueError()
        url=data['url'];method=data['method']
        cls.provider_calls.append((method,url))
        if url == 'https://api.workos.com/user_management/authenticate':
            result = {'user':{'id':'workos-user','email_verified':data['payload']['code']!='unverified'},'organization_id':'tenant'}
            if data['payload']['code']=='missing-org': result.pop('organization_id')
            if data['payload']['code']=='null-org': result['organization_id']=None
            if data['payload']['code']=='wrong-org': result['organization_id']='other-tenant'
            return result
        if url == 'https://api.github.com/user':return {'id':1,'login':'one'}
        if url == 'https://github.com/login/oauth/access_token':
            if data['payload'].get('grant_type')=='refresh_token':
                cls.refresh_calls+=1
                if cls.refresh_calls>1: raise ValueError('single use token replayed')
                return {'access_token':'renewed','refresh_token':'next-refresh','expires_in':28800,'refresh_token_expires_in':15897600}
            return {'access_token':'reader'}
        if '/user/installations/' in url:return {'repositories':[{'id':42,'full_name':'acme/repo','permissions':{'admin':False,'pull':True},'default_branch':'main'}]}
        if '/compare/' in url and '?' in url:return {'files':[{'filename':'a.txt','sha':'d'*40,'status':'modified','additions':1,'deletions':1,'patch':'@@ -1 +1 @@\n-before\n+after'}]}
        if url.endswith('/.well-known/jwks'):return {'keys':[cls.jwk]}
        if url.endswith('/access_tokens'):return {'token':'installation'}
        if url.endswith('/repos/acme/repo'):return {'id':42,'permissions':{'admin':True,'pull':True},'default_branch':'main'}
        if '/contents/' in url:return {'sha':'c'*40,'encoding':'base64','size':6,'content':__import__('base64').b64encode(('before\n' if url.endswith(cls.base) else 'after\n').encode()).decode()}
        if '/actions/runs/' in url:return {'id':123,'run_attempt':1,'event':'pull_request_target','head_sha':cls.run_head,'path':'.github/workflows/codeturtle.yml','status':'in_progress','pull_requests':[{'number':7,'base':{'repo':{'id':42}}}]}
        if url.endswith('/pulls/7'):return {'state':'open','head':{'sha':cls.live_head},'base':{'sha':cls.base,'ref':'main','repo':{'id':42}},'title':'Test PR','draft':False,'user':{'login':'author'}}
        if '/requested_reviewers' in url:
            if method=='POST': cls.requested_users.extend(data['payload']['reviewers']);cls.native_requests+=1
            return {'users':[{'login':u} for u in cls.requested_users],'teams':[]}
        if '/reviews?' in url:return []
        if '/compare/' in url:return {'merge_base_commit':{'sha':cls.base}}
        if '/comments?' in url:return cls.comments
        if '/comments' in url:
            if method=='POST':
                cls.posts+=1;comment={'id':cls.posts,'user':{'id':999},'body':data['payload']['body']};cls.comments.append(comment)
                if cls.fail_post:cls.fail_post=False;raise ValueError()
                return comment
            if method=='PATCH':cls.comments[0]['body']=data['payload']['body'];return cls.comments[0]
        raise ValueError(url)
    def setUp(self):
        self.sql('TRUNCATE codeturtle_private.deliveries,codeturtle_private.runs,codeturtle_private.enrollments,codeturtle_private.memberships,codeturtle_private.setups CASCADE')
        literal=json.dumps(self.enrollment).replace("'","''");self.sql("INSERT INTO codeturtle_private.enrollments VALUES('42','"+literal+"')")
        type(self).refresh_calls=0;type(self).requested_users=[];type(self).native_requests=0;type(self).provider_calls=[];type(self).comments=[];type(self).posts=0;type(self).fail_post=False;type(self).provider_down=False;type(self).live_head=self.head;type(self).run_head=self.head
    def request(self,path,token='',body=None,method=None,headers=None):
        raw=body if isinstance(body,bytes) else json.dumps(body).encode() if body is not None else None
        req=urllib.request.Request(self.origin+path,data=raw,method=method,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json',**(headers or {})})
        try:
            with urllib.request.urlopen(req,timeout=20) as r:return r.status,json.load(r)
        except urllib.error.HTTPError as e:return e.code,json.load(e)
    def test_run_metadata_uses_pr_head_while_oidc_uses_trusted_base(self):
        status,body=self.request('/v1/runs',jwt.encode(self.claims(),self.pem,algorithm='RS256',headers={'kid':'test'}),self.identity)
        self.assertEqual(status,200,body)
        type(self).run_head=self.base
        status,body=self.request('/v1/runs',jwt.encode(self.claims(),self.pem,algorithm='RS256',headers={'kid':'test'}),self.identity)
        self.assertEqual(status,403,body)
        self.assertEqual(body['error'],'run_mismatch')

    def register(self,claims=None):
        token=jwt.encode(claims or self.claims(),self.pem,algorithm='RS256',headers={'kid':'test'})
        status,data=self.request('/v1/runs',token,self.identity)
        self.assertEqual(status,200,data);return data
    def envelope(self,grant):
        return {'schema_version':1,'cli_version':'0.1.0','run_id':grant['run_id'],'identity':self.identity,'report':{'context':{'base_revision':self.base,'head_revision':self.head,'policy_revision':self.base,'merge_base':self.base,'policy_source':'base_revision'},'requirements':[],'evaluations':[],'errors':[],'unowned_files':[],'evaluation_complete':True},'setup_failure':None}
    def upload(self,grant,body):return self.request('/v1/runs/'+grant['run_id']+'/report',grant['token'],body,'PUT')
    def test_identity_and_signature(self):
        for change in [{'aud':'wrong'},{'repository_id':'99'},{'event_name':'pull_request'},{'runner_environment':'self-hosted'},{'exp':0}]:
            token=jwt.encode(dict(self.claims(),**change),self.pem,algorithm='RS256',headers={'kid':'test'})
            status,_=self.request('/v1/runs',token,self.identity);self.assertIn(status,[401,403])
    def test_upload_and_duplicate_conflict(self):
        g=self.register();e=self.envelope(g);a=self.upload(g,e);b=self.upload(g,e);self.assertEqual(a,b);self.assertEqual(a[0],202,a)
        e['cli_version']='changed';self.assertEqual(self.upload(g,e)[0],409)
        self.assertEqual(self.sql('SELECT count(*) FROM codeturtle_private.deliveries'),'1')
    def test_concurrent_upload(self):
        g=self.register();e=self.envelope(g)
        with concurrent.futures.ThreadPoolExecutor(4) as pool:results=list(pool.map(lambda _:self.upload(g,e),range(4)))
        self.assertTrue(all(r==results[0] for r in results));self.assertEqual(results[0][0],202,results)
    def test_rotation_and_expiry(self):
        old=self.register();new=self.register();self.assertEqual(old['run_id'],new['run_id']);self.assertEqual(self.upload(old,self.envelope(old))[0],401)
        self.sql('UPDATE codeturtle_private.runs SET expires_at=0');self.assertEqual(self.upload(new,self.envelope(new))[0],401)
    def test_stale_head(self):
        g=self.register();type(self).live_head='d'*40;self.assertEqual(self.upload(g,self.envelope(g))[0],409)
    def test_invalid_report(self):
        g=self.register();e=self.envelope(g);e['report']['context']['policy_source']='local_preview';self.assertEqual(self.upload(g,e)[0],400)
        e=self.envelope(g);e['report']['unowned_files']=['a.txt'];self.assertEqual(self.upload(g,e)[0],400)
    def test_setup_failure(self):
        g=self.register();e=self.envelope(g);e['report']=None;e['setup_failure']={'code':'evaluation_setup_failed','message':'failed'};self.assertEqual(self.upload(g,e)[0],202)
    def test_revoke(self):
        g=self.register();self.sql("UPDATE codeturtle_private.enrollments SET config=jsonb_set(config,'{active}','false')");self.assertEqual(self.upload(g,self.envelope(g))[0],403)
    def test_database_permissions(self):
        for role in ['anon','authenticated']:
            with self.assertRaises(subprocess.CalledProcessError):self.sql('SET ROLE '+role+"; SELECT public.ct_ready('{}');")
        self.assertEqual(json.loads(self.sql("SET ROLE service_role; SELECT public.ct_ready('{}');").splitlines()[-1]),{'ready':True})
    def test_restart_preserves_receipt(self):
        g=self.register();e=self.envelope(g);first=self.upload(g,e);self.stop_service();self.start_service();self.assertEqual(first,self.upload(g,e))
    def test_cli_real_evaluation(self):
        event={'repository':{'id':42,'full_name':'acme/repo'},'pull_request':{'number':7,'head':{'sha':self.head},'base':{'sha':self.base,'repo':{'id':42}}}}
        event_path=self.path/'event.json';event_path.write_text(json.dumps(event))
        env=dict(self.env,GITHUB_ACTIONS='true',GITHUB_EVENT_NAME='pull_request_target',GITHUB_EVENT_PATH=str(event_path),GITHUB_REPOSITORY='acme/repo',GITHUB_REPOSITORY_ID='42',GITHUB_RUN_ID='123',GITHUB_RUN_ATTEMPT='1',ACTIONS_ID_TOKEN_REQUEST_URL=self.mock_url+'/oidc',ACTIONS_ID_TOKEN_REQUEST_TOKEN='fixture',CODETURTLE_API_URL=self.origin,CODETURTLE_TEST_LOOPBACK='1')
        r=subprocess.run(['python3',str(ROOT/'cli/git_input.py'),'check','--report','--repo',str(self.repo),'--mode','json'],env=env,capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertTrue(json.loads(r.stdout)['evaluation_complete']);self.assertIn('accepted report',r.stderr)
    def delivery(self):self.command(['baml','--agent-skill-check','off','run','--project',str(self.project),'test_delivery','--',*self.args],env=self.env)
    def test_lost_provider_response_reconciles(self):
        g=self.register();self.assertEqual(self.upload(g,self.envelope(g))[0],202)
        type(self).fail_post=True;self.delivery();self.assertEqual(self.posts,1)
        self.sql("UPDATE codeturtle_private.deliveries SET next_at=now()")
        self.delivery();self.assertEqual(self.posts,1);self.assertEqual(self.sql('SELECT status FROM codeturtle_private.deliveries'),'delivered')
    def test_lease_recovery(self):
        g=self.register();self.upload(g,self.envelope(g));lease=self.rpc('ct_lease',{});self.assertIsNotNone(lease)
        self.assertIsNone(self.rpc('ct_lease',{}));self.sql("UPDATE codeturtle_private.deliveries SET lease_until=now()-interval '1 second'")
        self.delivery();self.assertEqual(self.posts,1)

    def test_supersession_preserves_live_lease(self):
        g=self.register();self.upload(g,self.envelope(g));lease=self.rpc('ct_lease',{})
        identity=dict(self.identity,run_attempt=2)
        authorized={'identity':identity,'enrollment':self.enrollment,'merge_base':self.base,'title':'Test PR'}
        newer=self.rpc('ct_register',{'authorized':authorized,'token_hash':'new','expires_at':int(time.time())+900})
        envelope=self.envelope(g);envelope['identity']=identity;envelope['run_id']=newer['id']
        self.rpc('ct_accept',{'id':newer['id'],'token_hash':'new','digest':'new-digest','envelope':envelope})
        self.assertIsNone(self.rpc('ct_lease',{}))
        self.rpc('ct_delivery_done',{'id':g['run_id'],'destination':'github','lease':lease['lease'],'reference':{'id':1}})
        next_lease=self.rpc('ct_lease',{});self.assertEqual(next_lease['run']['id'],newer['id'])

    def test_transaction_rolls_back_outbox_failure(self):
        g=self.register()
        self.sql("CREATE FUNCTION codeturtle_private.test_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test rollback'; END $$; CREATE TRIGGER test_fail BEFORE INSERT ON codeturtle_private.deliveries FOR EACH ROW EXECUTE FUNCTION codeturtle_private.test_fail();")
        try:
            self.assertEqual(self.upload(g,self.envelope(g))[0],503)
            self.assertEqual(self.sql('SELECT count(*) FROM codeturtle_private.runs WHERE digest IS NOT NULL'),'0')
        finally:self.sql('DROP TRIGGER test_fail ON codeturtle_private.deliveries; DROP FUNCTION codeturtle_private.test_fail();')

    def test_tenant_isolation_and_oauth_replay(self):
        g=self.register();self.upload(g,self.envelope(g))
        self.sql("INSERT INTO codeturtle_private.memberships(user_id,tenant_id,repository_id,github_user_id,can_setup) VALUES('user','tenant','42','1',true)")
        good={'user_id':'user','tenant_id':'tenant'}
        view=self.rpc('ct_review',{'actor':good,'id':g['run_id']});self.assertEqual(view['identity'],self.identity)
        self.assertNotIn('token_hash',json.dumps(view));self.assertNotIn('enrollment',view)
        for actor in [{'user_id':'other','tenant_id':'tenant'},{'user_id':'user','tenant_id':'other'}]:
            self.assertEqual(self.rpc('ct_review',{'actor':actor,'id':g['run_id']})['status'],403)
        self.rpc('ct_oauth_put',{'hash':'state','purpose':'workos','data':{'test':True},'expires_at':int(time.time())+60})
        self.assertEqual(self.rpc('ct_oauth_take',{'hash':'state','purpose':'workos'}),{'test':True})
        self.assertEqual(self.rpc('ct_oauth_take',{'hash':'state','purpose':'workos'})['status'],403)

    def test_expired_unreported_run_is_visible(self):
        self.register();self.sql("UPDATE codeturtle_private.runs SET created_at=now()-interval '3 hours'")
        self.rpc('ct_lease',{})
        self.assertEqual(self.sql('SELECT superseded FROM codeturtle_private.runs'),'t')


    def test_browser_access_and_csrf(self):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCMSIV
        import hashlib
        g=self.register();self.upload(g,self.envelope(g))
        token='a'*64;actor={'user_id':'user','tenant_id':'tenant'}
        self.rpc('ct_session_put',{'token_hash':hashlib.sha256(token.encode()).hexdigest(),'actor':actor,'csrf':'csrf','expires_at':int(time.time())+60})
        sealed='00'*12+':'+AESGCMSIV(bytes(32)).encrypt(bytes(12),b'github-user-token',b'github-user:user:42').hex()
        self.sql("INSERT INTO codeturtle_private.memberships VALUES('user','tenant','42','1',true,'"+sealed+"')")
        cookie={'Cookie':'__Host-ct_session='+token}
        self.assertEqual(self.request('/api/review?run='+g['run_id'])[0],401)
        status,view=self.request('/api/review?run='+g['run_id'],headers=cookie);self.assertEqual(status,200,view);self.assertEqual(view['review']['identity'],self.identity)
        self.assertNotIn('encrypted_token',json.dumps(view))
        status,_=self.request('/api/slack/mapping',body={'repository_id':'42','owner':'@one','user_id':'U123','channel':'C123'},headers=cookie)
        self.assertEqual(status,403)
        self.sql("DELETE FROM codeturtle_private.memberships")
        self.assertEqual(self.request('/api/review?run='+g['run_id'],headers=cookie)[0],403)


    def auth_request(self,path,cookie=None):
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self,*args,**kwargs):return None
        request=urllib.request.Request(self.origin+path,headers={'Cookie':cookie} if cookie else {})
        try:
            response=urllib.request.build_opener(NoRedirect).open(request,timeout=10)
        except urllib.error.HTTPError as error:
            response=error
        with response:return response.status,dict(response.headers),response.read()

    def test_workos_callback_creates_secure_session_and_rejects_replay(self):
        import urllib.parse
        status,headers,_=self.auth_request('/auth/login')
        self.assertEqual(status,302)
        location=urllib.parse.urlsplit(headers['location'])
        self.assertEqual(location.netloc,'api.workos.com')
        query=urllib.parse.parse_qs(location.query)
        self.assertEqual(query['redirect_uri'],[self.origin+'/auth/callback'])
        state=query['state'][0]
        cookie=headers['set-cookie'].split(';')[0]
        callback='/auth/callback?state='+state+'&code=valid'
        self.assertEqual(self.auth_request(callback)[0],403)
        status,headers,_=self.auth_request(callback,cookie)
        self.assertEqual(status,302)
        for flag in ['Secure','HttpOnly','SameSite=Lax','Path=/']:
            self.assertIn(flag,headers['set-cookie'])
        session_cookie=headers['set-cookie'].split(';')[0]
        status,session=self.request('/api/session',headers={'Cookie':session_cookie})
        self.assertEqual(status,200,session)
        self.assertEqual(len(session['csrf']),64)
        self.assertEqual(self.auth_request(callback,cookie)[0],403)

    def test_workos_requires_organization_context(self):
        import urllib.parse
        for code in ['missing-org','null-org','wrong-org']:
            with self.subTest(code=code):
                _,headers,_=self.auth_request('/auth/login')
                query=urllib.parse.parse_qs(urllib.parse.urlsplit(headers['location']).query)
                self.assertEqual(query.get('organization_id'),['tenant'])
                cookie=headers['set-cookie'].split(';')[0]
                status,headers,body=self.auth_request('/auth/callback?state='+query['state'][0]+'&code='+code,cookie)
                self.assertEqual(status,403)
                self.assertEqual(json.loads(body)['error'],'organization_required' if code!='wrong-org' else 'organization_mismatch')
                self.assertNotIn('set-cookie',headers)

    def test_workos_rejects_unverified_email(self):
        import urllib.parse
        _,headers,_=self.auth_request('/auth/login')
        state=urllib.parse.parse_qs(urllib.parse.urlsplit(headers['location']).query)['state'][0]
        cookie=headers['set-cookie'].split(';')[0]
        self.assertEqual(self.auth_request('/auth/callback?state='+state+'&code=unverified',cookie)[0],403)

    def reviewer_session(self, user='reviewer', github_id='1', tenant='tenant'):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCMSIV
        import hashlib
        token=hashlib.sha256((user+uuid.uuid4().hex).encode()).hexdigest()
        actor={'user_id':user,'tenant_id':tenant}
        self.rpc('ct_session_put',{'token_hash':hashlib.sha256(token.encode()).hexdigest(),'actor':actor,'csrf':'csrf','expires_at':int(time.time())+3600})
        sealed='00'*12+':'+AESGCMSIV(bytes(32)).encrypt(bytes(12),b'github-user-token',('github-user:'+user+':42').encode()).hex()
        self.sql("INSERT INTO codeturtle_private.memberships VALUES('"+user+"','"+tenant+"','42','"+github_id+"',false,'"+sealed+"')")
        return {'Cookie':'__Host-ct_session='+token,'Origin':self.origin,'X-CSRF-Token':'csrf'},actor

    def review_fixture(self):
        g=self.register();e=self.envelope(g)
        requirement={'path':'a.txt','owners':['@one','@two'],'approval':'All','evaluation':{'rule_line':1,'condition':None,'result':{'path':'a.txt','verdict':'Applies','reason':'Changed file','evidence':[]}}}
        e['report']['requirements']=[requirement]
        self.assertEqual(self.upload(g,e)[0],202)
        headers,actor=self.reviewer_session()
        body={'run_id':g['run_id'],'head':self.head,'indices':[0],'reviewed':True}
        return g,headers,actor,body

    def workspace_fixture(self):
        g,headers,actor,body=self.review_fixture()
        status,page=self.request('/api/workspace?run='+g['run_id'],headers=headers)
        self.assertEqual(status,200,page)
        decision={'id':str(uuid.uuid4()),'file':'a.txt','user':'one','revision':page['files'][0]['revision'],'kind':'approve','body':''}
        body={'run_id':g['run_id'],'head':self.head,'action':'draft','draft':{'decisions':[decision],'comments':[]}}
        return g,headers,actor,body

    def test_private_drafts_atomic_submit_and_comment_update(self):
        g,headers,actor,body=self.workspace_fixture()
        self.delivery();self.assertIn('| Reviewer | Parts | Progress | Review |',self.comments[0]['body'])
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],200)
        self.assertEqual(self.sql('SELECT count(*) FROM codeturtle_private.review_events'),'0')
        other,other_actor=self.reviewer_session('other')
        status,view=self.request('/api/workspace?run='+g['run_id'],headers=other)
        self.assertEqual(view['state']['draft']['decisions'],[])
        status,data=self.request('/api/workspace',body=dict(body,action='submit'),headers=headers)
        self.assertEqual(status,200,data)
        self.assertEqual(len(data['events']),1);self.assertEqual(data['draft']['decisions'],[])
        self.assertEqual(self.request('/api/workspace',body=dict(body,action='submit'),headers=headers)[0],400)
        self.delivery();self.assertEqual(self.posts,1);self.assertIn('1/1 reviewed',self.comments[0]['body'])
        self.stop_service();self.start_service()
        _,page=self.request('/api/review?run='+g['run_id'],headers=headers)
        self.assertEqual(page['completed_requirements'],0) # All still requires @two.
        status,data=self.request('/api/workspace/content?run='+g['run_id']+'&file=a.txt',headers=headers)
        self.assertEqual(status,200,data);self.assertEqual(data,{'original':'before\n','modified':'after\n'})

    def test_workspace_mutation_requires_identity_csrf_current_revision(self):
        g,headers,actor,body=self.workspace_fixture()
        self.assertEqual(self.request('/api/workspace',body=body)[0],401)
        self.assertEqual(self.request('/api/workspace',body=body,headers={'Cookie':headers['Cookie']})[0],403)
        self.assertEqual(self.request('/api/workspace',body=dict(body,head='f'*40),headers=headers)[0],409)
        other,_=self.reviewer_session('other','2')
        self.assertEqual(self.request('/api/workspace',body=body,headers=other)[0],403)
        alien,_=self.reviewer_session('alien','1','different-tenant')
        self.assertEqual(self.request('/api/workspace',body=body,headers=alien)[0],403)
        type(self).live_head='f'*40
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],409)
        type(self).live_head=self.head
        self.sql('UPDATE codeturtle_private.runs SET superseded=true')
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],409)

    def test_signoff_during_comment_delivery_is_not_lost(self):
        g,headers,actor,body=self.workspace_fixture()
        lease=self.rpc('ct_lease',{})
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],200)
        self.assertEqual(self.request('/api/workspace',body=dict(body,action='submit'),headers=headers)[0],200)
        self.assertIsNone(self.rpc('ct_lease',{}))
        self.rpc('ct_delivery_done',{'id':g['run_id'],'destination':'github','lease':lease['lease'],'reference':{'id':1}})
        self.assertIsNotNone(self.rpc('ct_lease',{}))

    def test_workspace_rejects_spoofed_decisions_and_empty_rejections(self):
        g,headers,actor,body=self.workspace_fixture()
        decision=body['draft']['decisions'][0]
        for field,value,status in [('file','not-owned',403),('user','two',403),('revision','wrong',403),('kind','changes',400),('kind','invalid',400)]:
            invalid=json.loads(json.dumps(body));invalid['draft']['decisions'][0][field]=value
            self.assertEqual(self.request('/api/workspace',body=invalid,headers=headers)[0],status,(field,value))
        self.assertEqual(self.sql('SELECT count(*) FROM codeturtle_private.review_events'),'0')
        self.assertEqual(self.request('/api/review/decision',body=body,headers=headers)[0],410)

    def test_rejection_and_admin_override_never_grant_approval(self):
        g,headers,actor,body=self.workspace_fixture()
        decision=body['draft']['decisions'][0];decision.update(kind='changes',body='Please fix the timeout')
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],200)
        self.assertEqual(self.request('/api/workspace',body=dict(body,action='submit'),headers=headers)[0],200)
        published=self.rpc('ct_workspace',{'id':g['run_id'],'actor':actor})['events'][0]['data']['id']
        override=dict(body,action='override',block=published,reason='Accepted as a follow-up fix')
        self.assertEqual(self.request('/api/workspace',body=override,headers=headers)[0],403)
        self.sql("UPDATE codeturtle_private.memberships SET can_setup=true")
        status,data=self.request('/api/workspace',body=override,headers=headers)
        self.assertEqual(status,200,data);self.assertEqual(data['events'][-1]['kind'],'override')
        self.assertEqual(self.rpc('ct_review_decisions',{'id':g['run_id']}),[])
        self.delivery();self.assertIn('overrode',self.comments[0]['body'])

    def test_every_file_requires_explicit_decision_and_submit_is_atomic(self):
        g,headers,actor,body=self.workspace_fixture()
        snapshot=self.rpc('ct_workspace_snapshot',{'id':g['run_id'],'actor':actor})
        second=dict(snapshot[0],id='second.txt');snapshot.append(second)
        self.sql("UPDATE codeturtle_private.review_snapshots SET files='"+json.dumps(snapshot).replace("'","''")+"'")
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],200)
        status,data=self.request('/api/workspace',body=dict(body,action='submit'),headers=headers)
        self.assertEqual(status,409,data);self.assertEqual(self.sql('SELECT count(*) FROM codeturtle_private.review_events'),'0')
        body['draft']['decisions'].append(dict(body['draft']['decisions'][0],id=str(uuid.uuid4()),file='second.txt'))
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],200)
        self.assertEqual(self.request('/api/workspace',body=dict(body,action='submit'),headers=headers)[0],200)
        self.assertEqual(self.sql('SELECT count(*) FROM codeturtle_private.review_events'),'2')

    def test_file_revisions_carry_approval_and_preserve_blocks_across_runs(self):
        g,headers,actor,body=self.workspace_fixture()
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],200)
        self.assertEqual(self.request('/api/workspace',body=dict(body,action='submit'),headers=headers)[0],200)
        next_id=str(uuid.uuid4())
        self.sql("INSERT INTO codeturtle_private.runs(id,repository_id,pr,run_id,attempt,authorized,token_hash,expires_at,digest,envelope,accepted_at) SELECT '"+next_id+"',repository_id,pr,456,attempt,authorized,token_hash,expires_at,digest,envelope,accepted_at FROM codeturtle_private.runs")
        self.sql("INSERT INTO codeturtle_private.review_snapshots SELECT '"+next_id+"',files FROM codeturtle_private.review_snapshots WHERE run_id='"+g['run_id']+"'")
        self.assertEqual(len(self.rpc('ct_review_decisions',{'id':next_id})),1)
        self.sql("UPDATE codeturtle_private.review_snapshots SET files=jsonb_set(files,'{0,revision}','\"changed-file\"') WHERE run_id='"+next_id+"'")
        self.assertEqual(self.rpc('ct_review_decisions',{'id':next_id}),[])
        self.sql("UPDATE codeturtle_private.review_events SET data=jsonb_set(data,'{kind}','\"changes\"')")
        events=self.rpc('ct_workspace',{'id':next_id,'actor':actor})['events']
        self.assertEqual(events[0]['data']['kind'],'changes')

    def test_frontend_serves_original_editor_worker_and_font_bytes(self):
        assets=ROOT/'frontend/dist/assets'
        for path in [ROOT/'frontend/dist/index.html',next(assets.glob('editor.worker-*.js')),next(assets.glob('*.woff2'))]:
            route='/' if path.name=='index.html' else '/assets/'+path.name
            with urllib.request.urlopen(self.origin+route) as response:
                self.assertEqual(response.read(),path.read_bytes())
                self.assertEqual(response.headers['x-content-type-options'],'nosniff')
                self.assertIn("script-src 'self'",response.headers['content-security-policy'])

    def test_outdated_comments_remain_private_and_must_be_discarded(self):
        g,headers,actor,body=self.workspace_fixture()
        decision=body['draft']['decisions'][0]
        comment={**decision,'line':1,'side':'RIGHT','body':'Private note','replyTo':None};comment.pop('kind')
        body['draft']['comments']=[comment]
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],200)
        self.sql("UPDATE codeturtle_private.review_snapshots SET files=jsonb_set(files,'{0,revision}','\"changed-file\"')")
        _,page=self.request('/api/workspace?run='+g['run_id'],headers=headers)
        self.assertEqual(page['state']['draft']['decisions'],[])
        self.assertEqual(len(page['state']['draft']['comments']),1)
        decision['revision']='changed-file'
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],200)
        self.assertEqual(self.request('/api/workspace',body=dict(body,action='submit'),headers=headers)[0],409)
        body['draft']['comments']=[]
        self.assertEqual(self.request('/api/workspace',body=body,headers=headers)[0],200)
        self.assertEqual(self.request('/api/workspace',body=dict(body,action='submit'),headers=headers)[0],200)

    def test_reviewer_link_cannot_rebind_installation(self):
        g=self.register();self.upload(g,self.envelope(g))
        p={'actor':{'user_id':'new','tenant_id':'tenant'},'repository_id':'42','installation_id':'9','github_user_id':'7','encrypted_token':'cipher'}
        self.assertEqual(self.rpc('ct_link_reviewer',dict(p,installation_id='10'))['status'],403)
        self.assertEqual(self.rpc('ct_link_reviewer',dict(p,actor={'user_id':'new','tenant_id':'other'}))['status'],403)
        self.assertEqual(self.rpc('ct_link_reviewer',p),{})
        self.assertEqual(self.sql("SELECT can_setup FROM codeturtle_private.memberships WHERE user_id='new'"),'f')
        for role in ['anon','authenticated']:
            with self.assertRaises(subprocess.CalledProcessError):self.sql('SET ROLE '+role+"; SELECT public.ct_review_decisions('{}');")

    def test_read_only_reviewer_oauth_and_immutable_diff(self):
        import urllib.parse
        g,headers,actor,body=self.review_fixture()
        self.sql("DELETE FROM codeturtle_private.memberships WHERE user_id='reviewer'")
        destination='/?run='+g['run_id']+'&reviewer=%40one'
        start='/auth/github/start?run='+g['run_id']+'&next='+urllib.parse.quote(destination,safe='')
        status,oauth,_=self.auth_request(start,headers['Cookie']);self.assertEqual(status,302)
        state=urllib.parse.parse_qs(urllib.parse.urlsplit(oauth['location']).query)['state'][0]
        cookies=headers['Cookie']+'; '+oauth['set-cookie'].split(';')[0]
        callback='/auth/github/callback?state='+state+'&code=reader'
        status,result,raw=self.auth_request(callback,cookies);self.assertEqual(status,302,raw)
        self.assertEqual(result['location'],destination)
        self.assertEqual(self.sql("SELECT can_setup FROM codeturtle_private.memberships WHERE user_id='reviewer'"),'f')
        self.assertEqual(self.auth_request(callback,cookies)[0],403)
        status,data=self.request('/api/review/diff?run='+g['run_id']+'&index=0',headers=headers)
        self.assertEqual(status,200,data);self.assertIn('+after',data['patch'])

    def test_workos_preserves_personal_review_link(self):
        import urllib.parse
        target='/?run=00000000-0000-0000-0000-000000000001&reviewer=%40one'
        _,headers,_=self.auth_request('/auth/login?next='+urllib.parse.quote(target,safe=''))
        state=urllib.parse.parse_qs(urllib.parse.urlsplit(headers['location']).query)['state'][0]
        cookie=headers['set-cookie'].split(';')[0]
        status,headers,_=self.auth_request('/auth/callback?state='+state+'&code=valid',cookie)
        self.assertEqual(status,302);self.assertEqual(headers['location'],target)



    def operation_fixture(self):
        g,h,a,b=self.workspace_fixture()
        d=b['draft']['decisions'][0]
        item={'id':str(uuid.uuid4()),'file':'a.txt','user':'one','revision':d['revision'],'side':'RIGHT','line':1,'body':'hello','replyTo':None}
        return g,h,a,dict(b,action='operation',operation_id=str(uuid.uuid4()),expected_version=0,operation={'kind':'upsert_comment','item':item})

    def test_operation_retry_conflict_and_private_pagination(self):
        g,h,a,b=self.operation_fixture()
        first=self.request('/api/workspace',body=b,headers=h)
        self.assertEqual(first[0],200,first);self.assertEqual(first[1]['version'],1)
        self.assertEqual(self.request('/api/workspace',body=b,headers=h),first)
        altered=dict(b,operation=dict(b['operation'],item=dict(b['operation']['item'],body='changed')))
        self.assertEqual(self.request('/api/workspace',body=altered,headers=h)[0],409)
        other=dict(b,operation_id=str(uuid.uuid4()))
        self.assertEqual(self.request('/api/workspace',body=other,headers=h)[0],409)
        state=self.request('/api/workspace/state?run='+g['run_id'],headers=h)[1]
        self.assertEqual(len(state['draft']['comments']),1)
        comments=self.request('/api/workspace/comments?run='+g['run_id']+'&file=a.txt',headers=h)[1]
        self.assertEqual(comments['events'],[])
        other_h,_=self.reviewer_session('other')
        self.assertEqual(self.request('/api/workspace/state?run='+g['run_id'],headers=other_h)[1]['draft']['comments'],[])

    def test_operations_validate_assignment_csrf_and_submission_head(self):
        g,h,a,b=self.operation_fixture()
        self.assertEqual(self.request('/api/workspace',body=b)[0],401)
        self.assertEqual(self.request('/api/workspace',body=b,headers={'Cookie':h['Cookie']})[0],403)
        bad=dict(b,operation=dict(b['operation'],item=dict(b['operation']['item'],user='spoof')))
        self.assertEqual(self.request('/api/workspace',body=bad,headers=h)[0],403)
        type(self).live_head='f'*40
        self.assertEqual(self.request('/api/workspace',body=b,headers=h)[0],200)
        self.assertEqual(self.request('/api/workspace',body=dict(b,action='submit'),headers=h)[0],409)
        self.sql("UPDATE codeturtle_private.enrollments SET config=jsonb_set(config,'{active}','false')")
        self.assertEqual(self.request('/api/workspace',body=b,headers=h)[0],403)

    def test_legacy_writer_invalidates_operation_version(self):
        g,h,a,b=self.operation_fixture()
        draft={'decisions':[],'comments':[b['operation']['item']]}
        self.assertEqual(self.request('/api/workspace',body=dict(b,action='draft',draft=draft),headers=h)[0],200)
        self.assertEqual(self.request('/api/workspace',body=b,headers=h)[0],409)

    def test_submit_detects_intervening_tab_write(self):
        g,h,a,b=self.operation_fixture()
        decision=dict(b,operation={'kind':'upsert_decision','item':b['draft']['decisions'][0]})
        self.assertEqual(self.request('/api/workspace',body=decision,headers=h)[0],200)
        comment=dict(b,operation_id=str(uuid.uuid4()),expected_version=1)
        self.assertEqual(self.request('/api/workspace',body=comment,headers=h)[0],200)
        stale=dict(b,action='submit',expected_version=1)
        self.assertEqual(self.request('/api/workspace',body=stale,headers=h)[0],409)
        self.assertEqual(self.sql("SELECT count(*) FROM codeturtle_private.review_events"),'0')
        self.assertEqual(self.request('/api/workspace',body=dict(stale,expected_version=2),headers=h)[0],200)

    def test_warm_workspace_and_draft_call_budgets(self):
        g,h,a,b=self.operation_fixture()
        type(self).provider_calls=[]
        req=urllib.request.Request(self.origin+'/api/workspace?run='+g['run_id'],headers=h)
        with urllib.request.urlopen(req) as response:
            self.assertEqual(response.status,200)
            self.assertRegex(response.headers['server-timing'],r'db;dur=\d+;desc="2 calls"')
            json.load(response)
        self.assertEqual(len(self.provider_calls),3,self.provider_calls)
        type(self).provider_calls=[]
        self.assertEqual(self.request('/api/workspace',body=b,headers=h)[0],200)
        self.assertEqual(len(self.provider_calls),2,self.provider_calls)
        self.assertFalse(any('/pulls/' in url or '/access_tokens' in url for _,url in self.provider_calls))

    def test_cached_content_still_checks_access(self):
        g,h,a,b=self.workspace_fixture()
        path='/api/workspace/content?run='+g['run_id']+'&file=a.txt'
        self.assertEqual(self.request(path,headers=h)[0],200)
        type(self).provider_calls=[]
        self.assertEqual(self.request(path,headers=h)[0],200)
        self.assertFalse(any('/contents/' in u or '/access_tokens' in u for _,u in self.provider_calls))
        self.assertTrue(any('/repos/acme/repo' == u.removeprefix('https://api.github.com') for _,u in self.provider_calls))
        self.sql("UPDATE codeturtle_private.enrollments SET config=jsonb_set(config,'{active}','false')")
        self.assertEqual(self.request(path,headers=h)[0],403)

    def test_comments_cursor_and_compact_bootstrap(self):
        g,h,a,b=self.workspace_fixture()
        literal=json.dumps({'id':'comment','file':'a.txt','user':'one','revision':'revision','line':1,'side':'RIGHT','body':'published','replyTo':None}).replace("'","''")
        self.sql("INSERT INTO codeturtle_private.review_events(run_id,user_id,github_user_id,kind,data) SELECT '"+g['run_id']+"','reviewer','1','comment','"+literal+"'::jsonb FROM generate_series(1,55)")
        page=self.request('/api/workspace?run='+g['run_id'],headers=h)[1]
        self.assertEqual(page['csrf'],'csrf');self.assertEqual(page['state']['events'],[])
        path='/api/workspace/comments?run='+g['run_id']+'&file=a.txt'
        first=self.request(path,headers=h)[1];self.assertEqual(len(first['events']),50);self.assertTrue(first['more'])
        second=self.request(path+'&after='+str(first['cursor']),headers=h)[1];self.assertEqual(len(second['events']),5);self.assertFalse(second['more'])
        self.assertLess(first['events'][-1]['seq'],second['events'][0]['seq'])

    @unittest.skipUnless(os.environ.get('CODETURTLE_TEST_REFRESH_SQL'), 'private refresh handoff required')
    def test_refresh_claim_serializes_and_cannot_overwrite_reconnect(self):
        headers,actor=self.reviewer_session()
        encrypted=self.sql("SELECT encrypted_token FROM codeturtle_private.memberships")
        p={'actor':actor,'repository_id':'42','encrypted_token':encrypted}
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda _:self.rpc('ct_github_refresh_claim',p),range(2)))
        self.assertEqual(sum(r.get('state')=='claimed' for r in results),1)
        self.assertEqual(sum(r.get('status')==503 for r in results),1)
        claim=next(r['claim'] for r in results if r.get('state')=='claimed')
        # A GitHub reconnect wins over an in-flight refresh commit.
        self.sql("UPDATE codeturtle_private.memberships SET encrypted_token='reconnected'")
        self.assertEqual(self.rpc('ct_github_refresh_commit',{**p,'claim':claim,'replacement':'obsolete'})['status'],409)
        self.assertEqual(self.rpc('ct_github_refresh_claim',p),{'state':'updated','encrypted_token':'reconnected'})
        self.assertEqual(self.sql("SELECT encrypted_token FROM codeturtle_private.memberships"),'reconnected')

    @unittest.skipUnless(os.environ.get('CODETURTLE_TEST_REFRESH_SQL'), 'private refresh handoff required')
    def test_refresh_timeout_requires_reconnect_and_enforces_tenant(self):
        _,actor=self.reviewer_session()
        encrypted=self.sql("SELECT encrypted_token FROM codeturtle_private.memberships")
        p={'actor':actor,'repository_id':'42','encrypted_token':encrypted}
        self.assertEqual(self.rpc('ct_github_refresh_claim',{**p,'actor':{**actor,'tenant_id':'other'}})['status'],403)
        self.rpc('ct_github_refresh_claim',p)
        self.sql("UPDATE codeturtle_private.memberships SET refresh_started=now()-interval '1 minute'")
        self.assertEqual(self.rpc('ct_github_refresh_claim',p)['error'],'github_reconnect_required')
        for role in ('anon','authenticated'):
            with self.assertRaises(subprocess.CalledProcessError):self.sql('SET ROLE '+role+"; SELECT public.ct_github_refresh_claim('{}');")

    @unittest.skipUnless(os.environ.get('CODETURTLE_TEST_REFRESH_SQL'), 'private refresh handoff required')
    def test_expired_github_token_refreshes_once_through_http_workspace(self):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCMSIV
        g,h,actor,_=self.workspace_fixture()
        bundle={'access_token':'expired','refresh_token':'first-refresh','expires_at':int(time.time())-1,'refresh_expires_at':int(time.time())+3600}
        sealed='00'*12+':'+AESGCMSIV(bytes(32)).encrypt(bytes(12),json.dumps(bundle).encode(),b'github-user:reviewer:42').hex()
        self.sql("UPDATE codeturtle_private.memberships SET encrypted_token='"+sealed+"'")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            responses=list(pool.map(lambda _:self.request('/api/workspace?run='+g['run_id'],headers=h),range(2)))
        for status,view in responses:
            self.assertEqual(status,200,view)
            self.assertNotIn('next-refresh',json.dumps(view))
        self.assertEqual(self.refresh_calls,1)
        encrypted=self.sql("SELECT encrypted_token FROM codeturtle_private.memberships WHERE user_id='reviewer'")
        nonce,cipher=encrypted.split(':')
        saved=json.loads(AESGCMSIV(bytes(32)).decrypt(bytes.fromhex(nonce),bytes.fromhex(cipher),b'github-user:reviewer:42'))
        self.assertEqual(saved['access_token'],'renewed')
        self.assertEqual(saved['refresh_token'],'next-refresh')

    def test_native_review_requests_are_reconciled_on_delivery_retry(self):
        g,h,actor,body=self.review_fixture()
        type(self).fail_post=True
        self.delivery()
        self.assertEqual(self.requested_users,['one','two'])
        self.assertEqual(self.native_requests,1)
        self.sql("UPDATE codeturtle_private.deliveries SET next_at=now()")
        self.delivery()
        self.assertEqual(self.native_requests,1)
        self.assertEqual(self.sql('SELECT status FROM codeturtle_private.deliveries'),'delivered')

if __name__=='__main__':unittest.main()
