"""Disposable local UI/benchmark fixture. No production credentials or live GitHub writes.
Run after frontend build, with CODETURTLE_TEST_SQL and CODETURTLE_TEST_REVIEW_SQL.
"""
import base64
import copy
import json
import os
from pathlib import Path
import signal
import time
from test_service import ServiceTests

class Harness(ServiceTests):
    @classmethod
    def provider(cls,data):
        if '/contents/' in data['url'] and '.github/workflows' not in data['url']:
            before=data['url'].endswith(cls.base)
            lines=int(os.environ.get('CODETURTLE_FIXTURE_LINES','2000'))
            text=''.join(f'const value_{i} = {i if before or i % 20 else i+1};\n' for i in range(lines))
            cls.provider_calls.append((data['method'],data['url']))
            return {'sha':'d'*40,'encoding':'base64','size':len(text),'content':base64.b64encode(text.encode()).decode()}
        return super().provider(data)

if __name__=='__main__':
    Harness.setUpClass()
    try:
        test=Harness('runTest');test.setUp()
        grant,headers,actor,body=test.workspace_fixture()
        snapshot=test.rpc('ct_workspace_snapshot',{'id':grant['run_id'],'actor':actor})
        files=[]
        for index in range(int(os.environ.get('CODETURTLE_FIXTURE_FILES','50'))):
            file=copy.deepcopy(snapshot[0]);file['id']=f'file-{index:03}.ts';file['change']['filename']=file['id'];file['change']['additions']=100;file['change']['deletions']=100
            for rule in file['requirements']:rule['path']=file['id']
            files.append(file)
        data=json.dumps(files).replace("'","''")
        test.sql("UPDATE codeturtle_private.review_snapshots SET files='"+data+"'::jsonb WHERE run_id='"+grant['run_id']+"'")
        for i in range(int(os.environ.get('CODETURTLE_FIXTURE_COMMENTS','200'))):
            comment={'id':f'fixture-{i}','file':files[0]['id'],'user':'one','revision':files[0]['revision'],'line':i+1,'side':'RIGHT','body':f'Fixture comment {i}','replyTo':None}
            literal=json.dumps(comment).replace("'","''")
            test.sql("INSERT INTO codeturtle_private.review_events(run_id,user_id,github_user_id,kind,data) VALUES('"+grant['run_id']+"','reviewer','1','comment','"+literal+"'::jsonb)")
        Harness.stop_service()
        fixture=Harness.project/'baml_src/fixture.baml'
        source=fixture.read_text()
        cookie=headers['Cookie']+'; Secure; HttpOnly; SameSite=Lax; Path=/'
        route='if (req.url == "/__fixture/login") {redirect("/?run='+grant['run_id']+'&performance=1",set_cookie='+json.dumps(cookie)+')} else {app.handle(req)}'
        source=source.replace('.serve((req) -> {app.handle(req)},','.serve((req) -> {'+route+'},')
        fixture.write_text(source);Harness.start_service()
        output={'url':Harness.origin+'/__fixture/login','run':grant['run_id'],'files':len(files),'lines':int(os.environ.get('CODETURTLE_FIXTURE_LINES','2000'))}
        Path('/tmp/codeturtle-harness.json').write_text(json.dumps(output))
        print(json.dumps(output),flush=True)
        signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        while True:time.sleep(1)
    except KeyboardInterrupt:pass
    finally:Harness.doClassCleanups()
