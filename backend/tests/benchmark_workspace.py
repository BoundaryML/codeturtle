"""Repeatable isolated HTTP/SQL/RSS benchmark; no production traffic.
Uses the same CODETURTLE_TEST_SQL/REVIEW_SQL inputs as test_service.py.
"""
import concurrent.futures
import json
import math
import os
import subprocess
import time
from pathlib import Path
from test_service import ServiceTests


def distribution(values):
    ordered=sorted(values)
    return {'samples':len(values),'p50_ms':round(ordered[len(ordered)//2],1),'p95_ms':round(ordered[math.ceil(len(ordered)*.95)-1],1),'max_ms':round(max(values),1)}


def rss():
    # The BAML launcher may exec or retain a child; count the complete process tree.
    rows=subprocess.check_output(['ps','-axo','pid=,ppid=,rss='],text=True).splitlines()
    processes=[tuple(map(int,row.split())) for row in rows]
    ids={ServiceTests.process.pid}
    while True:
        children={pid for pid,parent,_ in processes if parent in ids}
        if children<=ids:break
        ids|=children
    return sum(memory for pid,_,memory in processes if pid in ids)


if __name__=='__main__':
    ServiceTests.setUpClass()
    try:
        test=ServiceTests('runTest');test.setUp()
        grant,headers,actor,body=test.operation_fixture()
        paths={'bootstrap':'/api/workspace?run='+grant['run_id'],'content':'/api/workspace/content?run='+grant['run_id']+'&file=a.txt','comments':'/api/workspace/comments?run='+grant['run_id']+'&file=a.txt'}
        result={'environment':'isolated PostgreSQL + real BAML HTTP + loopback provider; warm session; one-file API fixture','read_latency':{},'rss_kib':[]}
        def read(path):
            start=time.perf_counter();status,data=test.request(path,headers=headers)
            assert status==200,(status,data)
            return (time.perf_counter()-start)*1000
        for path in paths.values():read(path)
        result['rss_kib'].append(rss())
        for concurrency in (1,5,20):
            for name,path in paths.items():
                with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
                    values=list(pool.map(lambda _:read(path),range(30)))
                result['read_latency'][f'{name}/{concurrency}_concurrent']=distribution(values)
            result['rss_kib'].append(rss())
        saves=[]
        for version in range(30):
            operation=dict(body,expected_version=version,operation_id=__import__('uuid').uuid4().hex)
            # Public endpoint requires a UUID with hyphens.
            operation['operation_id']=str(__import__('uuid').UUID(operation['operation_id']))
            start=time.perf_counter();status,data=test.request('/api/workspace',headers=headers,body=operation)
            assert status==200,(status,data)
            saves.append((time.perf_counter()-start)*1000)
        result['draft_latency']=distribution(saves)
        for _ in range(int(os.environ.get("CODETURTLE_SOAK_ROUNDS","3"))):
            with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:list(pool.map(lambda _:read(paths['content']),range(100)))
            result['rss_kib'].append(rss())
        Path('/tmp/codeturtle-performance-results.json').write_text(json.dumps(result,indent=2))
        run=grant['run_id']
        # Seed unrelated runs to make index selectivity realistic, then inspect plans.
        test.sql("INSERT INTO codeturtle_private.runs SELECT (jsonb_populate_record(NULL::codeturtle_private.runs,to_jsonb(r)||jsonb_build_object('id',gen_random_uuid(),'pr',10000+n,'run_id',10000+n))).* FROM codeturtle_private.runs r CROSS JOIN generate_series(1,10000) n WHERE r.id='"+run+"'; ANALYZE codeturtle_private.runs;")
        result['run_lookup_plan']=test.sql("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT id FROM codeturtle_private.runs WHERE repository_id='42' AND pr=7 ORDER BY created_at DESC")
        Path('/tmp/codeturtle-performance-results.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result,indent=2))
    finally:ServiceTests.doClassCleanups()
