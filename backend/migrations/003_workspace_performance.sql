-- Apply after the existing setup and review-signoffs SQL, before deploying this release.
-- Rerunnable. No review/audit rows are removed. RPC access remains service-role-only.
BEGIN;
CREATE INDEX IF NOT EXISTS ct_runs_pr_created ON codeturtle_private.runs(repository_id,pr,created_at);
CREATE INDEX IF NOT EXISTS ct_events_run_seq ON codeturtle_private.review_events(run_id,seq);
CREATE INDEX IF NOT EXISTS ct_drafts_user_run ON codeturtle_private.review_drafts(user_id,run_id);
CREATE TABLE IF NOT EXISTS codeturtle_private.draft_versions(run_id uuid REFERENCES codeturtle_private.runs ON DELETE CASCADE,user_id text,version bigint NOT NULL DEFAULT 0,PRIMARY KEY(run_id,user_id));
CREATE TABLE IF NOT EXISTS codeturtle_private.draft_receipts(run_id uuid REFERENCES codeturtle_private.runs ON DELETE CASCADE,user_id text,operation_id uuid,payload jsonb NOT NULL,result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(run_id,user_id,operation_id));
ALTER TABLE codeturtle_private.draft_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE codeturtle_private.draft_receipts ENABLE ROW LEVEL SECURITY;
CREATE OR REPLACE FUNCTION codeturtle_private.bump_draft_version() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,codeturtle_private AS $$
BEGIN
 IF TG_OP='DELETE' THEN
  INSERT INTO draft_versions VALUES(OLD.run_id,OLD.user_id,1) ON CONFLICT(run_id,user_id) DO UPDATE SET version=draft_versions.version+1;
 ELSE
  INSERT INTO draft_versions VALUES(NEW.run_id,NEW.user_id,1) ON CONFLICT(run_id,user_id) DO UPDATE SET version=draft_versions.version+1;
 END IF;
 RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS ct_draft_version ON codeturtle_private.review_drafts;
CREATE TRIGGER ct_draft_version AFTER INSERT OR UPDATE OR DELETE ON codeturtle_private.review_drafts FOR EACH ROW EXECUTE FUNCTION codeturtle_private.bump_draft_version();

-- One server-only context lookup replaces session/run/membership/enrollment round trips.
CREATE OR REPLACE FUNCTION public.ct_workspace_context(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,codeturtle_private AS $$
DECLARE s jsonb; r runs; m memberships; e enrollments;
BEGIN
 s:=public.ct_session_get(p); IF s?'error' THEN RETURN s; END IF;
 SELECT * INTO r FROM runs WHERE id=(p->>'id')::uuid;
 IF NOT FOUND THEN RETURN codeturtle_private.error('not_found',404); END IF;
 SELECT * INTO e FROM enrollments WHERE repository_id=r.repository_id;
 SELECT * INTO m FROM memberships WHERE repository_id=r.repository_id AND user_id=s->'actor'->>'user_id' AND tenant_id=s->'actor'->>'tenant_id';
 IF NOT FOUND OR e.config->>'active' IS DISTINCT FROM 'true' OR e.config->>'tenant_id' IS DISTINCT FROM m.tenant_id THEN RETURN codeturtle_private.error('repository_forbidden',403); END IF;
 RETURN jsonb_build_object('actor',s->'actor','csrf',s->'csrf','run',codeturtle_private.view_run(r),'enrollment',e.config,'encrypted_token',m.encrypted_token,'can_setup',m.can_setup,'github_user_id',m.github_user_id,'files',(SELECT files FROM review_snapshots WHERE run_id=r.id));
END $$;

-- Current decision projection, not the entire comment/audit history. Historical overrides
-- stay available to match persistent blocks. Full audit data remains in review_events.
CREATE OR REPLACE FUNCTION public.ct_workspace_view(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,codeturtle_private AS $$
DECLARE r runs; allowed jsonb; events jsonb; draft jsonb; v bigint;
BEGIN
 allowed:=public.ct_review_run(p); IF allowed?'error' THEN RETURN allowed; END IF;
 SELECT * INTO r FROM runs WHERE id=(p->>'id')::uuid;
 WITH latest AS (
  SELECT DISTINCT ON (e.github_user_id,e.data->>'file') e.* FROM review_events e JOIN runs old ON old.id=e.run_id
  WHERE old.repository_id=r.repository_id AND old.pr=r.pr AND old.created_at<=r.created_at AND e.kind='decision'
  ORDER BY e.github_user_id,e.data->>'file',e.seq DESC
 ), overrides AS (
  SELECT DISTINCT ON (e.data->>'block') e.* FROM review_events e JOIN runs old ON old.id=e.run_id
  WHERE old.repository_id=r.repository_id AND old.pr=r.pr AND old.created_at<=r.created_at AND e.kind='override'
  ORDER BY e.data->>'block',e.seq DESC
 ) SELECT coalesce(jsonb_agg(jsonb_build_object('kind',e.kind,'data',e.data,'at',e.created_at) ORDER BY e.seq),'[]') INTO events FROM (SELECT * FROM latest UNION ALL SELECT * FROM overrides) e;
 SELECT dd.data INTO draft FROM review_drafts dd JOIN runs old ON old.id=dd.run_id WHERE old.repository_id=r.repository_id AND old.pr=r.pr AND old.created_at<=r.created_at AND dd.user_id=p->'actor'->>'user_id' ORDER BY old.created_at DESC LIMIT 1;
 IF draft IS NOT NULL THEN draft:=jsonb_set(draft,'{decisions}',coalesce((SELECT jsonb_agg(d.value) FROM jsonb_array_elements(draft->'decisions') d JOIN review_snapshots sn ON sn.run_id=r.id CROSS JOIN LATERAL jsonb_array_elements(sn.files) f WHERE d.value->>'file'=f.value->>'id' AND d.value->>'revision'=f.value->>'revision'),'[]')); END IF;
 SELECT version INTO v FROM draft_versions WHERE run_id=r.id AND user_id=p->'actor'->>'user_id';
 RETURN jsonb_build_object('events',events,'version',coalesce(v,0),'draft',coalesce(draft,'{"decisions":[],"comments":[]}'));
END $$;

CREATE OR REPLACE FUNCTION public.ct_workspace_comments(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,codeturtle_private AS $$
DECLARE r runs; allowed jsonb; items jsonb; cursor_value bigint;
BEGIN
 allowed:=public.ct_review_run(p); IF allowed?'error' THEN RETURN allowed; END IF;
 SELECT * INTO r FROM runs WHERE id=(p->>'id')::uuid;
 SELECT coalesce(jsonb_agg(jsonb_build_object('seq',e.seq,'kind',e.kind,'data',e.data,'at',e.created_at) ORDER BY e.seq),'[]'),max(e.seq) INTO items,cursor_value FROM (
  SELECT e.* FROM review_events e JOIN runs old ON old.id=e.run_id WHERE old.repository_id=r.repository_id AND old.pr=r.pr AND old.created_at<=r.created_at AND e.kind='comment' AND e.data->>'file'=p->>'file' AND e.seq>coalesce((p->>'after')::bigint,0) ORDER BY e.seq LIMIT 50
 ) e;
 RETURN jsonb_build_object('events',items,'cursor',coalesce(cursor_value,coalesce((p->>'after')::bigint,0)),'more',jsonb_array_length(items)=50);
END $$;

-- UUID-based operations serialize with the legacy writer through the enrollment/run locks.
-- Retries replay their receipt; expected_version detects concurrent tabs and legacy clients.
CREATE OR REPLACE FUNCTION public.ct_draft_operation(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,codeturtle_private AS $$
DECLARE r runs; a jsonb:=p->'actor'; allowed jsonb; draft jsonb; v bigint; receipt draft_receipts; op jsonb:=p->'operation'; item jsonb; f jsonb; bucket text; result jsonb; source_run uuid;
BEGIN
 SELECT * INTO r FROM runs WHERE id=(p->>'id')::uuid;
 IF NOT FOUND THEN RETURN codeturtle_private.error('not_found',404); END IF;
 PERFORM 1 FROM enrollments WHERE repository_id=r.repository_id FOR UPDATE;
 SELECT * INTO r FROM runs WHERE id=r.id FOR UPDATE;
 allowed:=public.ct_authorize(jsonb_build_object('actor',a,'repository_id',r.repository_id,'setup',false));
 IF allowed?'error' THEN RETURN allowed; END IF;
 IF r.superseded OR r.digest IS NULL OR r.authorized->'identity'->>'head' IS DISTINCT FROM p->>'head' THEN RETURN codeturtle_private.error('stale_review',409); END IF;
 IF NOT EXISTS(SELECT 1 FROM memberships WHERE user_id=a->>'user_id' AND repository_id=r.repository_id AND github_user_id=p->>'github_user_id') THEN RETURN codeturtle_private.error('github_identity_mismatch',403); END IF;
 SELECT * INTO receipt FROM draft_receipts WHERE run_id=r.id AND user_id=a->>'user_id' AND operation_id=(p->>'operation_id')::uuid;
 IF FOUND THEN
  IF receipt.payload IS DISTINCT FROM op THEN RETURN codeturtle_private.error('operation_conflict',409); END IF;
  RETURN receipt.result;
 END IF;
 SELECT coalesce(version,0) INTO v FROM draft_versions WHERE run_id=r.id AND user_id=a->>'user_id'; v:=coalesce(v,0);
 IF v IS DISTINCT FROM (p->>'expected_version')::bigint THEN RETURN codeturtle_private.error('draft_conflict',409); END IF;
 SELECT dd.data,dd.run_id INTO draft,source_run FROM review_drafts dd JOIN runs old ON old.id=dd.run_id WHERE old.repository_id=r.repository_id AND old.pr=r.pr AND old.created_at<=r.created_at AND dd.user_id=a->>'user_id' ORDER BY old.created_at DESC LIMIT 1;
 draft:=coalesce(draft,'{"decisions":[],"comments":[]}');
 -- Carry only decisions matching the target snapshot, as the read projection does.
 draft:=jsonb_set(draft,'{decisions}',coalesce((SELECT jsonb_agg(d.value) FROM jsonb_array_elements(draft->'decisions') d WHERE EXISTS(SELECT 1 FROM review_snapshots sn CROSS JOIN LATERAL jsonb_array_elements(sn.files) file_row WHERE sn.run_id=r.id AND file_row.value->>'id'=d.value->>'file' AND file_row.value->>'revision'=d.value->>'revision')),'[]'));
 bucket:=CASE WHEN op->>'kind' IN ('upsert_comment','delete_comment') THEN 'comments' WHEN op->>'kind' IN ('upsert_decision','delete_decision') THEN 'decisions' ELSE NULL END;
 IF bucket IS NULL THEN RETURN codeturtle_private.error('invalid_operation',400); END IF;
 IF op->>'kind' LIKE 'upsert_%' THEN
  item:=op->'item';
  SELECT value INTO f FROM review_snapshots sn CROSS JOIN LATERAL jsonb_array_elements(sn.files) WHERE sn.run_id=r.id AND value->>'id'=item->>'file';
  IF item->>'user' IS DISTINCT FROM p->>'github_login' OR f IS NULL OR item->>'revision' IS DISTINCT FROM f->>'revision' OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(f->'owners') o WHERE ('@'||o)=ANY(ARRAY(SELECT jsonb_array_elements_text(p->'eligible_owners')))) THEN RETURN codeturtle_private.error('invalid_draft_assignment',403); END IF;
  IF jsonb_typeof(item->'id') IS DISTINCT FROM 'string' OR length(item->>'id') NOT BETWEEN 1 AND 80 OR jsonb_typeof(item->'body') IS DISTINCT FROM 'string' OR length(item->>'body')>20000 THEN RETURN codeturtle_private.error('invalid_draft',400); END IF;
  IF bucket='comments' AND (item->>'side' IS NULL OR item->>'side' NOT IN ('LEFT','RIGHT') OR coalesce((item->>'line')::int,0)<1 OR length(trim(item->>'body'))=0) THEN RETURN codeturtle_private.error('invalid_comment',400); END IF;
  IF bucket='decisions' AND (item->>'kind' IS NULL OR item->>'kind' NOT IN ('approve','changes') OR (item->>'kind'='changes' AND length(trim(item->>'body'))=0)) THEN RETURN codeturtle_private.error('rejection_reason_required',400); END IF;
  SELECT coalesce(jsonb_agg(d),'[]') INTO result FROM jsonb_array_elements(draft->bucket) d WHERE CASE WHEN bucket='comments' THEN d->>'id'<>item->>'id' ELSE d->>'file'<>item->>'file' END;
  result:=result||jsonb_build_array(item);
 ELSE
  IF jsonb_typeof(op->'id') IS DISTINCT FROM 'string' THEN RETURN codeturtle_private.error('invalid_operation',400); END IF;
  SELECT coalesce(jsonb_agg(d),'[]') INTO result FROM jsonb_array_elements(draft->bucket) d WHERE d->>'id'<>op->>'id';
 END IF;
 IF jsonb_array_length(result)>1000 THEN RETURN codeturtle_private.error('invalid_draft',400); END IF;
 draft:=jsonb_set(draft,ARRAY[bucket],result);
 INSERT INTO review_drafts VALUES(r.id,a->>'user_id',draft) ON CONFLICT(run_id,user_id) DO UPDATE SET data=excluded.data;
 SELECT version INTO v FROM draft_versions WHERE run_id=r.id AND user_id=a->>'user_id';
 result:=jsonb_build_object('version',v,'operation_id',p->>'operation_id');
 INSERT INTO draft_receipts VALUES(r.id,a->>'user_id',(p->>'operation_id')::uuid,op,result,now());
 RETURN result;
END $$;
-- Publish exactly the draft version acknowledged by this browser, under the same
-- locks as draft operations. Another tab cannot insert a write between check/submit.
CREATE OR REPLACE FUNCTION public.ct_workspace_submit(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,codeturtle_private AS $$
DECLARE r runs; allowed jsonb; v bigint;
BEGIN
 allowed:=public.ct_review_run(p); IF allowed?'error' THEN RETURN allowed; END IF;
 SELECT * INTO r FROM runs WHERE id=(p->>'id')::uuid;
 PERFORM 1 FROM enrollments WHERE repository_id=r.repository_id FOR UPDATE;
 PERFORM 1 FROM runs WHERE id=r.id FOR UPDATE;
 SELECT version INTO v FROM draft_versions WHERE run_id=r.id AND user_id=p->'actor'->>'user_id';
 IF (p->>'expected_version')::bigint IS DISTINCT FROM coalesce(v,0) THEN RETURN codeturtle_private.error('draft_conflict',409); END IF;
 RETURN public.ct_workspace_write(p||jsonb_build_object('action','submit'));
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA codeturtle_private FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION codeturtle_private.bump_draft_version() FROM PUBLIC,anon,authenticated;
DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT oid::regprocedure AS signature FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('ct_workspace_context','ct_workspace_view','ct_workspace_comments','ct_draft_operation','ct_workspace_submit') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f.signature);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',f.signature);
 END LOOP;
END $$;
COMMIT;
