// HTTP API. Handlers throw HttpError; srv_handle converts to the
// spec error body. Browser mutations require session + CSRF; Actions
// endpoints require OIDC/upload tokens; webhooks require HMAC when a
// secret is configured.
//
// OIDC note: tokens are parsed and claims checked against the
// registration payload and enrollment. Signature verification against
// GitHub's JWKS needs RS256, which the BAML stdlib does not expose
// yet; deploy behind a verifying proxy or add JWKS support before
// trusting this on the public internet.

class RegisterRequestBody {
    repository: string,
    pr_number: int,
    run_id: string,
    run_attempt: string,
    head_sha: string,
    base_sha: string?,
    merge_base: string?,
    pr_title: string?,
    pr_body: string?,
    pr_author_login: string?,
}

class EnrollmentBody {
    trusted_workflow: string?,
    allow_self_review: bool,
    enabled: bool,
}

class CommentRequest {
    path: string,
    side: string,
    line: int,
    body: string,
    diff_digest: string,
}

class SessionResponse {
    user_id: int,
    login: string,
    csrf: string,
}

class WorkloadItem {
    pr_id: string,
    repository: string,
    number: int,
    title: string?,
    head: string,
    state: ReviewState,
    pending_files: string[],
    version: int,
}

class WorkloadResponse {
    items: WorkloadItem[],
    next_cursor: string?,
}

class PrResponse {
    id: string,
    repository: string,
    number: int,
    title: string?,
    state: ReviewState,
    publication: PublicationState,
    version: int,
    current_evaluation_id: string?,
    objections: ObjectionRecord[],
}

class FileView {
    path: string,
    old_path: string?,
    status: root.ChangeStatus,
    digest: string,
    required: bool,
    requirements: root.Requirement[],
    satisfied: bool,
}

class FilesResponse {
    evaluation_id: string,
    version: int,
    files: FileView[],
}

class DiffResponse {
    path: string,
    digest: string,
    patch: string?,
    available: bool,
}

class ActivityResponse {
    events: AuditEvent[],
    comments: CommentRecord[],
}

class ServiceInfo {
    service: string,
    version: string,
}

class QueuedResponse {
    queued: bool,
}

function srv_header(req: baml.http.ServerRequest, name: string) -> string? {
    req.headers.get(name) ?? req.headers.get(name.to_lower_case())
}

function srv_bearer(req: baml.http.ServerRequest) -> string? {
    match (srv_header(req, "authorization")) {
        null => null,
        let value: string => {
            if (value.starts_with("Bearer ")) {
                value.slice("Bearer ".length(), value.length())
            } else {
                null
            }
        },
    }
}

function srv_json_response(status: int, body: string) -> baml.http.Response {
    baml.http.Response.new(status, { "content-type": "application/json" }, body.to_utf8())
}

function srv_json<T>(status: int, value: T) -> baml.http.Response {
    let body = baml.json.to_string(value) catch (e) {
        baml.json.SerializationError => {
            "{\"code\":\"internal_error\",\"message\":\"serialization failed\",\"request_id\":\"req_0\",\"retryable\":true,\"current_evaluation_id\":null,\"version\":null}"
        },
    };
    srv_json_response(status, body)
}

function srv_error_response(
    error: HttpError,
    current_evaluation_id: string?,
    version: int?,
) -> baml.http.Response {
    srv_json(
        error.status,
        SrvErrorBody {
            code: error.code,
            message: error.message,
            request_id: `req_${srv_random_hex(6)}`,
            retryable: error.retryable,
            current_evaluation_id: current_evaluation_id,
            version: version,
        },
    )
}

function srv_origin_form(url: string) -> string {
    match (url.index_of("://")) {
        null => url,
        let sep: int => {
            let rest = url.slice(sep + 3, url.length());
            match (rest.index_of("/")) {
                null => "/",
                let slash: int => rest.slice(slash, rest.length()),
            }
        },
    }
}

function srv_path_of(url: string) -> string {
    let origin = srv_origin_form(url);
    match (origin.index_of("?")) {
        null => origin,
        let idx: int => origin.slice(0, idx),
    }
}

function srv_query_of(url: string) -> string {
    let origin = srv_origin_form(url);
    match (origin.index_of("?")) {
        null => "",
        let idx: int => origin.slice(idx + 1, origin.length()),
    }
}

function srv_query_value(query: string, key: string) -> string? {
    let hit = query.split("&").find((pair: string) -> bool {
        pair.starts_with(`${key}=`)
    });
    match (hit) {
        null => null,
        let pair: string => pair.slice(key.length() + 1, pair.length()),
    }
}

function srv_path_segment(path: string, prefix: string, suffix: string) -> string? {
    if (!path.starts_with(prefix)) {
        return null;
    }
    let rest = path.slice(prefix.length(), path.length());
    if (suffix.is_empty()) {
        if (rest.is_empty() || rest.includes("/")) {
            null
        } else {
            rest
        }
    } else if (rest.ends_with(suffix) && rest.length() > suffix.length()) {
        let middle = rest.slice(0, rest.length() - suffix.length());
        if (middle.is_empty() || middle.includes("/")) {
            null
        } else {
            middle
        }
    } else {
        null
    }
}

function srv_session(store: StoreState, req: baml.http.ServerRequest) -> SessionRecord? {
    match (srv_header(req, "cookie")) {
        null => null,
        let cookie: string => {
            let token = cookie.split(";").find((part: string) -> bool {
                part.trim().starts_with("ct_session=")
            });
            match (token) {
                null => null,
                let part: string => {
                    let value = part.trim().slice("ct_session=".length(), part.trim().length());
                    let hash = srv_token_hash(value);
                    store.sessions.find((s: SessionRecord) -> bool {
                        s.token_hash == hash
                    })
                },
            }
        },
    }
}

function srv_require_session(
    store: StoreState,
    req: baml.http.ServerRequest,
) -> SessionRecord throws HttpError {
    match (srv_session(store, req)) {
        null => throw http_error(401, "unauthenticated", "sign in with GitHub first"),
        let session: SessionRecord => session,
    }
}

function srv_require_csrf(
    session: SessionRecord,
    req: baml.http.ServerRequest,
) -> null throws HttpError {
    if (srv_header(req, "x-csrf-token") != session.csrf) {
        throw http_error(403, "csrf_failed", "missing or invalid CSRF token");
    }
    null
}

function srv_decode<T>(body: string, what: string) -> T throws HttpError {
    baml.json.from_string<T>(body) catch (e) {
        baml.json.ParseError => throw http_error(422, "invalid_json", `${what} is not valid JSON`),
        baml.json.DecodeError => {
            throw http_error(422, "invalid_body", `${what} has an unexpected shape: ${e.message}`)
        },
    }
}

function srv_oidc_claims(token: string) -> baml.json.json throws HttpError {
    let parts = token.split(".");
    if (parts.length() != 3) {
        throw http_error(401, "identity_rejected", "OIDC token is not a JWT");
    }
    match (root.lib.base64.Base64Url.decode_text(parts[1])) {
        null => throw http_error(401, "identity_rejected", "OIDC payload cannot be decoded"),
        let payload: string => {
            baml.json.parse(payload) catch (e) {
                baml.json.ParseError => {
                    throw http_error(401, "identity_rejected", "OIDC payload is not JSON")
                },
            }
        },
    }
}

function srv_verify_oidc(
    store: StoreState,
    req: baml.http.ServerRequest,
    body: RegisterRequestBody,
) -> null throws HttpError {
    let token = match (srv_bearer(req)) {
        null => throw http_error(401, "identity_rejected", "missing Actions OIDC token"),
        let t: string => t,
    };
    let claims = srv_oidc_claims(token);
    let repository = baml.json.path_or(claims, ".repository", "");
    if (repository != body.repository) {
        throw http_error(401, "identity_rejected", "OIDC repository does not match the registration");
    }
    let run_id = baml.json.path_or(claims, ".run_id", "");
    if (!run_id.is_empty() && run_id != body.run_id) {
        throw http_error(401, "identity_rejected", "OIDC run does not match the registration");
    }
    let enrollment = match (srv_enrollment(store, body.repository)) {
        null => {
            throw http_error(403, "repository_not_enrolled", `repository ${body.repository} is not enrolled`)
        },
        let e: Enrollment => e,
    };
    if (!enrollment.enabled) {
        throw http_error(403, "repository_not_enrolled", `repository ${body.repository} enrollment is disabled`);
    }
    match (enrollment.trusted_workflow) {
        null => null,
        let trusted: string => {
            let workflow = baml.json.path_or(claims, ".job_workflow_ref", "");
            if (!workflow.starts_with(trusted)) {
                throw http_error(403, "untrusted_workflow", "workflow is not the enrolled trusted workflow");
            }
            null
        },
    }
}

function srv_allow_client_inputs() -> bool {
    root.lib.env.env_or_null("CODETURTLE_ALLOW_CLIENT_INPUTS") == "1"
}

function srv_register(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
) -> baml.http.Response throws HttpError {
    let body = srv_decode<RegisterRequestBody>(req.body, "registration");
    srv_verify_oidc(store, req, body);
    let pr = srv_get_or_create_pr(store, body.repository, body.pr_number);
    if (pr.closed) {
        throw http_error(410, "pull_request_closed", "pull request is closed");
    }
    let heads = srv_fetch_pr_heads(body.repository, body.pr_number);
    let base_sha = match (heads) {
        null => {
            if (srv_allow_client_inputs()) {
                body.base_sha ?? body.head_sha
            } else {
                null
            }
        },
        let h: GhPrHeads => h.base_sha,
    };
    let resolved_base = match (base_sha) {
        null => throw http_error(503, "input_unavailable", "cannot resolve PR inputs from GitHub"),
        let b: string => b,
    };
    let merge_base = srv_fetch_merge_base(body.repository, resolved_base, body.head_sha) ?? body.merge_base
        ?? resolved_base;
    match (heads) {
        null => {
            pr.title = body.pr_title ?? pr.title;
            pr.author_login = body.pr_author_login ?? pr.author_login;
        },
        let h: GhPrHeads => {
            pr.title = h.title;
            pr.author_login = h.author_login;
        },
    };
    let attempt_id = srv_next_id(store, "attempt");
    let evaluation_id = srv_next_id(store, "eval");
    let upload_token = srv_random_hex(32);
    store.attempts.push(
        AttemptRecord {
            id: attempt_id,
            evaluation_id: evaluation_id,
            pr_id: pr.id,
            repository: body.repository,
            pr_number: body.pr_number,
            run_id: body.run_id,
            run_attempt: body.run_attempt,
            head_sha: body.head_sha,
            base_sha: resolved_base,
            merge_base: merge_base,
            upload_token_hash: srv_token_hash(upload_token),
            report_digest: null,
            created_at: srv_now(),
        },
    );
    pr.state = "evaluating";
    pr.version = pr.version + 1;
    srv_audit(store, pr.id, "attempt_registered", attempt_id, body.repository);
    srv_save(store, db_path);
    srv_json(
        201,
        root.RegisterResponse {
            attempt_id: attempt_id,
            evaluation_id: evaluation_id,
            upload_token: upload_token,
            repository: body.repository,
            pr_number: body.pr_number,
            head_sha: body.head_sha,
            base_sha: resolved_base,
            merge_base: merge_base,
            pr_title: pr.title,
            pr_body: body.pr_body,
            pr_labels: null,
            pr_author_id: pr.author_login,
        },
    )
}

function srv_renew(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
    attempt_id: string,
) -> baml.http.Response throws HttpError {
    let attempt = match (srv_attempt(store, attempt_id)) {
        null => throw http_error(404, "attempt_not_found", "unknown evaluation attempt"),
        let a: AttemptRecord => a,
    };
    srv_verify_oidc(
        store,
        req,
        RegisterRequestBody {
            repository: attempt.repository,
            pr_number: attempt.pr_number,
            run_id: attempt.run_id,
            run_attempt: attempt.run_attempt,
            head_sha: attempt.head_sha,
            base_sha: null,
            merge_base: null,
            pr_title: null,
            pr_body: null,
            pr_author_login: null,
        },
    );
    let upload_token = srv_random_hex(32);
    attempt.upload_token_hash = srv_token_hash(upload_token);
    srv_save(store, db_path);
    srv_json(200, root.CredentialsResponse { upload_token: upload_token })
}

function srv_upload(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
    attempt_id: string,
) -> baml.http.Response throws HttpError {
    let attempt = match (srv_attempt(store, attempt_id)) {
        null => throw http_error(404, "attempt_not_found", "unknown evaluation attempt"),
        let a: AttemptRecord => a,
    };
    let token = match (srv_bearer(req)) {
        null => throw http_error(401, "identity_rejected", "missing upload token"),
        let t: string => t,
    };
    if (srv_token_hash(token) != attempt.upload_token_hash) {
        throw http_error(401, "identity_rejected", "upload token does not match this attempt");
    }
    let digest = root.lib.digest.Digest.sha256_hex(req.body);
    match (attempt.report_digest) {
        null => null,
        let existing: string => {
            if (existing == digest) {
                return srv_json(
                    200,
                    root.UploadResponse {
                        evaluation_id: attempt.evaluation_id,
                        review_url: srv_review_url(attempt.pr_id),
                    },
                );
            }
            throw http_error(409, "report_conflict", "different report bytes were already accepted for this attempt");
        },
    };
    let report = srv_decode<root.Report>(req.body, "report");
    if (report.mode != "hosted") {
        throw http_error(422, "report_rejected", "preview reports cannot be accepted as authoritative");
    }
    if (report.evaluation_id != attempt.evaluation_id) {
        throw http_error(422, "report_rejected", "report evaluation_id does not match the attempt");
    }
    if (
        report.inputs.head != attempt.head_sha
            || report.inputs.base != attempt.base_sha
            || report.inputs.merge_base != attempt.merge_base
    ) {
        throw http_error(422, "report_rejected", "report inputs do not match the issued inputs");
    }
    if (report.succeeded && report.errors.length() > 0) {
        throw http_error(422, "report_rejected", "a successful report must have zero errors");
    }
    let pr = match (srv_pr(store, attempt.pr_id)) {
        null => throw http_error(404, "pull_request_not_found", "unknown pull request"),
        let p: PrRecord => p,
    };
    attempt.report_digest = digest;
    let record = EvaluationRecord {
        id: attempt.evaluation_id,
        pr_id: pr.id,
        inputs: report.inputs,
        succeeded: report.succeeded,
        files: report.files,
        requirements: report.requirements,
        rule_evaluations: report.rule_evaluations,
        errors: report.errors,
        current: false,
        created_at: srv_now(),
    };
    store.evaluations.push(record);
    if (pr.closed) {
        srv_save(store, db_path);
        throw http_error(410, "pull_request_closed", "report stored as history; pull request is closed");
    }
    let current = srv_current_evaluation(store, pr);
    let stale = match (current) {
        null => false,
        let e: EvaluationRecord => {
            e.id != record.id
                && e.inputs.head != report.inputs.head
                && e.created_at > attempt.created_at
        },
    };
    if (stale) {
        srv_save(store, db_path);
        throw http_error(409, "stale_evaluation", "a newer evaluation is already current");
    }
    for (let other in store.evaluations) {
        if (other.pr_id == pr.id && other.id != record.id) {
            other.current = false;
        }
    }
    record.current = true;
    pr.current_evaluation_id = record.id;
    srv_audit(store, pr.id, "report_accepted", record.id, null);
    srv_refresh_state(store, pr, {});
    srv_save(store, db_path);
    srv_publish(store, pr);
    srv_json(200, root.UploadResponse { evaluation_id: record.id, review_url: srv_review_url(pr.id) })
}

function srv_review_url(pr_id: string) -> string? {
    match (root.lib.env.env_or_null("CODETURTLE_PUBLIC_URL")) {
        null => null,
        let base: string => `${base}/pr/${pr_id}`,
    }
}

function srv_is_admin(store: StoreState, req: baml.http.ServerRequest, repository: string) -> bool {
    let admin_token = root.lib.env.env_or_null("CODETURTLE_ADMIN_TOKEN");
    if (admin_token != null && srv_bearer(req) == admin_token) {
        return true;
    }
    match (srv_session(store, req)) {
        null => false,
        let session: SessionRecord => {
            let result = srv_github(
                "GET",
                `/repos/${repository}/collaborators/${session.login}/permission`,
                session.github_token,
                "",
            );
            srv_json_string(result.body, "permission") == "admin"
        },
    }
}

function srv_get_enrollment(
    store: StoreState,
    req: baml.http.ServerRequest,
    repository: string,
) -> baml.http.Response throws HttpError {
    srv_require_session(store, req);
    match (srv_enrollment(store, repository)) {
        null => throw http_error(404, "repository_not_enrolled", "repository is not enrolled"),
        let e: Enrollment => srv_json(200, e),
    }
}

function srv_put_enrollment(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
    repository: string,
) -> baml.http.Response throws HttpError {
    if (!srv_is_admin(store, req, repository)) {
        throw http_error(403, "not_administrator", "repository administrator access is required");
    }
    match (srv_session(store, req)) {
        null => null,
        let session: SessionRecord => srv_require_csrf(session, req),
    };
    let body = srv_decode<EnrollmentBody>(req.body, "enrollment");
    let updated = Enrollment {
        repository: repository,
        trusted_workflow: body.trusted_workflow,
        allow_self_review: body.allow_self_review,
        enabled: body.enabled,
    };
    match (srv_enrollment(store, repository)) {
        null => store.enrollments.push(updated),
        let existing: Enrollment => {
            existing.trusted_workflow = updated.trusted_workflow;
            existing.allow_self_review = updated.allow_self_review;
            existing.enabled = updated.enabled;
        },
    };
    srv_save(store, db_path);
    srv_json(200, updated)
}

function srv_memberships_for(
    store: StoreState,
    evaluation: EvaluationRecord,
    session: SessionRecord,
) -> map<string, bool> {
    srv_team_memberships(evaluation, session.login, session.github_token)
}

function srv_workload(
    store: StoreState,
    req: baml.http.ServerRequest,
) -> baml.http.Response throws HttpError {
    let session = srv_require_session(store, req);
    let query = srv_query_of(req.url);
    let offset = root.lib.text.Text.parse_int_or_null(srv_query_value(query, "cursor") ?? "0") ?? 0;
    let items: WorkloadItem[] = [];
    for (let pr in store.prs) {
        let evaluation = srv_current_evaluation(store, pr);
        match (evaluation) {
            null => null,
            let e: EvaluationRecord => {
                if (e.succeeded && !pr.closed) {
                    let memberships = srv_memberships_for(store, e, session);
                    let allow_self = srv_allow_self_review(store, pr);
                    let latest = srv_latest_decisions(store, e.id);
                    let pending: string[] = [];
                    for (let file in e.files) {
                        if (!file.required) {
                            continue;
                        }
                        let mine = latest.find((d: DecisionRecord) -> bool {
                            d.path == file.path
                                && d.actor_id == session.user_id
                                && d.action == "approve"
                        });
                        if (
                            mine == null
                                && srv_actor_eligible_for_file(
                                    e,
                                    file.path,
                                    session.login,
                                    memberships,
                                    pr.author_login,
                                    allow_self,
                                )
                        ) {
                            pending.push(file.path);
                        }
                    }
                    if (pending.length() > 0) {
                        items.push(
                            WorkloadItem {
                                pr_id: pr.id,
                                repository: pr.repository,
                                number: pr.number,
                                title: pr.title,
                                head: e.inputs.head,
                                state: pr.state,
                                pending_files: pending,
                                version: pr.version,
                            },
                        );
                    }
                }
                null
            },
        };
    }
    let page_size = 20;
    let page = items.slice(offset, offset + page_size);
    let next = if (offset + page_size < items.length()) {
        string.from(offset + page_size)
    } else {
        null
    };
    srv_json(200, WorkloadResponse { items: page, next_cursor: next })
}

function srv_pr_response(store: StoreState, pr: PrRecord) -> PrResponse {
    PrResponse {
        id: pr.id,
        repository: pr.repository,
        number: pr.number,
        title: pr.title,
        state: pr.state,
        publication: pr.publication,
        version: pr.version,
        current_evaluation_id: pr.current_evaluation_id,
        objections: srv_open_objections(store, pr.id, null),
    }
}

function srv_get_pr(
    store: StoreState,
    req: baml.http.ServerRequest,
    pr_id: string,
) -> baml.http.Response throws HttpError {
    srv_require_session(store, req);
    match (srv_pr(store, pr_id)) {
        null => throw http_error(404, "pull_request_not_found", "unknown pull request"),
        let pr: PrRecord => srv_json(200, srv_pr_response(store, pr)),
    }
}

function srv_files(
    store: StoreState,
    req: baml.http.ServerRequest,
    evaluation_id: string,
) -> baml.http.Response throws HttpError {
    let session = srv_require_session(store, req);
    let evaluation = match (srv_evaluation(store, evaluation_id)) {
        null => throw http_error(404, "evaluation_not_found", "unknown evaluation"),
        let e: EvaluationRecord => e,
    };
    let pr = match (srv_pr(store, evaluation.pr_id)) {
        null => throw http_error(404, "pull_request_not_found", "unknown pull request"),
        let p: PrRecord => p,
    };
    let show_all = srv_query_value(srv_query_of(req.url), "all") == "1";
    let memberships = srv_memberships_for(store, evaluation, session);
    let allow_self = srv_allow_self_review(store, pr);
    let latest = srv_latest_decisions(store, evaluation.id);
    let views: FileView[] = [];
    for (let file in evaluation.files) {
        let reqs = evaluation.requirements.filter((r: root.Requirement) -> bool {
            r.path == file.path
        });
        let eligible = srv_actor_eligible_for_file(evaluation, file.path, session.login, memberships, pr.author_login, allow_self);
        if (!show_all && !eligible && reqs.length() > 0) {
            continue;
        }
        let satisfied = reqs.every((r: root.Requirement) -> bool {
            srv_requirement_satisfied(r, latest, memberships, pr.author_login, allow_self)
        });
        views.push(
            FileView {
                path: file.path,
                old_path: file.old_path,
                status: file.status,
                digest: file.digest,
                required: file.required,
                requirements: reqs,
                satisfied: satisfied,
            },
        );
    }
    srv_json(200, FilesResponse { evaluation_id: evaluation.id, version: pr.version, files: views })
}

function srv_diff(
    store: StoreState,
    req: baml.http.ServerRequest,
    evaluation_id: string,
    file_id: string,
) -> baml.http.Response throws HttpError {
    srv_require_session(store, req);
    let evaluation = match (srv_evaluation(store, evaluation_id)) {
        null => throw http_error(404, "evaluation_not_found", "unknown evaluation"),
        let e: EvaluationRecord => e,
    };
    let file = evaluation.files.find((f: root.FileOutcome) -> bool {
        root.lib.digest.Digest.sha256_hex(f.path).slice(0, 16) == file_id || f.path == file_id
    });
    match (file) {
        null => throw http_error(404, "file_not_found", "unknown file in this evaluation"),
        let f: root.FileOutcome => {
            srv_json(200, DiffResponse { path: f.path, digest: f.digest, patch: null, available: false })
        },
    }
}

function srv_decide(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
    evaluation_id: string,
) -> baml.http.Response throws HttpError {
    let session = srv_require_session(store, req);
    srv_require_csrf(session, req);
    let evaluation = match (srv_evaluation(store, evaluation_id)) {
        null => throw http_error(404, "evaluation_not_found", "unknown evaluation"),
        let e: EvaluationRecord => e,
    };
    let pr = match (srv_pr(store, evaluation.pr_id)) {
        null => throw http_error(404, "pull_request_not_found", "unknown pull request"),
        let p: PrRecord => p,
    };
    let body = srv_decode<DecisionRequest>(req.body, "decision");
    if (body.idempotency_key.is_empty()) {
        let key = srv_header(req, "idempotency-key") ?? "";
        if (key.is_empty()) {
            throw http_error(422, "idempotency_key_required", "decisions require an idempotency key");
        }
        body.idempotency_key = key;
    }
    let memberships = srv_memberships_for(store, evaluation, session);
    let record = srv_apply_decision(store, evaluation, pr, session.user_id, session.login, body, memberships);
    srv_save(store, db_path);
    srv_publish(store, pr);
    srv_json(201, record)
}

function srv_resolve_objection(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
    objection_id: string,
) -> baml.http.Response throws HttpError {
    let session = srv_require_session(store, req);
    srv_require_csrf(session, req);
    let objection = match (
        store.objections.find((o: ObjectionRecord) -> bool {
            o.id == objection_id
        })
    ) {
        null => throw http_error(404, "objection_not_found", "unknown objection"),
        let o: ObjectionRecord => o,
    };
    if (objection.actor_id != session.user_id) {
        throw http_error(403, "not_objection_author", "only the objection author can resolve it");
    }
    objection.open = false;
    objection.resolved_at = srv_now();
    let pr = srv_pr(store, objection.pr_id);
    match (pr) {
        null => null,
        let p: PrRecord => {
            srv_audit(store, p.id, "objection_resolved", objection.path, session.login);
            srv_refresh_state(store, p, {});
            srv_save(store, db_path);
            srv_publish(store, p);
        },
    };
    srv_json(200, objection)
}

function srv_comment(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
    evaluation_id: string,
) -> baml.http.Response throws HttpError {
    let session = srv_require_session(store, req);
    srv_require_csrf(session, req);
    let evaluation = match (srv_evaluation(store, evaluation_id)) {
        null => throw http_error(404, "evaluation_not_found", "unknown evaluation"),
        let e: EvaluationRecord => e,
    };
    let body = srv_decode<CommentRequest>(req.body, "comment");
    let record = CommentRecord {
        id: srv_next_id(store, "cmt"),
        evaluation_id: evaluation.id,
        pr_id: evaluation.pr_id,
        path: body.path,
        side: body.side,
        line: body.line,
        body: body.body,
        author_login: session.login,
        diff_digest: body.diff_digest,
        at: srv_now(),
    };
    store.comments.push(record);
    srv_audit(store, evaluation.pr_id, "comment", body.path, session.login);
    srv_save(store, db_path);
    srv_json(201, record)
}

function srv_activity(
    store: StoreState,
    req: baml.http.ServerRequest,
    pr_id: string,
) -> baml.http.Response throws HttpError {
    srv_require_session(store, req);
    match (srv_pr(store, pr_id)) {
        null => throw http_error(404, "pull_request_not_found", "unknown pull request"),
        let pr: PrRecord => {
            srv_json(
                200,
                ActivityResponse {
                    events: store.audit.filter((e: AuditEvent) -> bool {
                        e.pr_id == pr.id
                    }),
                    comments: store.comments.filter((c: CommentRecord) -> bool {
                        c.pr_id == pr.id
                    }),
                },
            )
        },
    }
}

function srv_reevaluate(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
    pr_id: string,
) -> baml.http.Response throws HttpError {
    let session = srv_require_session(store, req);
    srv_require_csrf(session, req);
    let pr = match (srv_pr(store, pr_id)) {
        null => throw http_error(404, "pull_request_not_found", "unknown pull request"),
        let p: PrRecord => p,
    };
    pr.state = "evaluating";
    pr.version = pr.version + 1;
    srv_audit(store, pr.id, "reevaluation_queued", "", session.login);
    srv_save(store, db_path);
    srv_publish(store, pr);
    srv_json(202, QueuedResponse { queued: true })
}

class TokenExchangePayload {
    client_id: string,
    client_secret: string,
    code: string,
    code_verifier: string,
    redirect_uri: string,
}

class AccessTokenResponse {
    access_token: string?,
    error: string?,
}

function srv_redirect(location: string, set_cookie: string?) -> baml.http.Response {
    let headers: map<string, string> = { "location": location };
    if (set_cookie != null) {
        headers["set-cookie"] = set_cookie ?? "";
    }
    baml.http.Response.new(302, headers, "".to_utf8())
}

function srv_safe_redirect(value: string?) -> string {
    match (value) {
        null => "/",
        let v: string => {
            if (v.starts_with("/") && !v.starts_with("//")) {
                v
            } else {
                "/"
            }
        },
    }
}

function srv_public_url(req: baml.http.ServerRequest) -> string {
    root.lib.env.env_or_null("CODETURTLE_PUBLIC_URL")
        ?? `http://${srv_header(req, "host") ?? "127.0.0.1:8787"}`
}

function srv_login(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
) -> baml.http.Response throws HttpError {
    let client_id = root.lib.env.env_or_null("GITHUB_CLIENT_ID");
    if (client_id == null || root.lib.env.env_or_null("GITHUB_CLIENT_SECRET") == null) {
        throw http_error(503, "oauth_not_configured", "GitHub OAuth is not configured on this backend");
    }
    let state = srv_random_hex(16);
    let verifier = srv_random_hex(32);
    let challenge_bytes = {
        let h = baml.crypto.Sha256.new();
        h.update(verifier.to_utf8());
        root.lib.base64.Base64Url.encode(h.finish())
    };
    let redirect = srv_safe_redirect(srv_query_value(srv_query_of(req.url), "next"));
    store.oauth_txs.push(
        OAuthTxRecord { state: state, code_verifier: verifier, redirect: redirect },
    );
    srv_save(store, db_path);
    let redirect_uri = `${srv_public_url(req)}/v1/auth/github/callback`;
    srv_redirect(
        `https://github.com/login/oauth/authorize?client_id=${client_id ?? ""}&state=${state}&code_challenge=${challenge_bytes}&code_challenge_method=S256&redirect_uri=${redirect_uri}`,
        null,
    )
}

function srv_callback(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
) -> baml.http.Response throws HttpError {
    let query = srv_query_of(req.url);
    let code = srv_query_value(query, "code") ?? "";
    let state = srv_query_value(query, "state") ?? "";
    let tx_index = store.oauth_txs.find_index((t: OAuthTxRecord) -> bool {
        t.state == state
    });
    let tx = match (tx_index) {
        null => {
            throw http_error(400, "invalid_oauth_state", "OAuth state is missing, used, or expired")
        },
        let i: int => {
            store.oauth_txs.remove_at(i)
                ?? OAuthTxRecord { state: "", code_verifier: "", redirect: "/" }
        },
    };
    if (code.is_empty() || tx.state.is_empty()) {
        throw http_error(400, "invalid_oauth_state", "OAuth state is missing, used, or expired");
    }
    let payload = baml.json.to_string(
        TokenExchangePayload {
            client_id: root.lib.env.env_or_null("GITHUB_CLIENT_ID") ?? "",
            client_secret: root.lib.env.env_or_null("GITHUB_CLIENT_SECRET") ?? "",
            code: code,
            code_verifier: tx.code_verifier,
            redirect_uri: `${srv_public_url(req)}/v1/auth/github/callback`,
        },
    ) catch (e) {
        baml.json.SerializationError => "",
    };
    let exchange = baml.http.send(
        baml.http.Request {
            method: "POST",
            url: "https://github.com/login/oauth/access_token",
            headers: { "accept": "application/json", "content-type": "application/json" },
            body: payload,
            timeout: baml.time.Duration.from_seconds(root.lib.limits.Limits.http_timeout_seconds()),
            connect_timeout: baml.time.Duration.from_seconds(root.lib.limits.Limits.http_timeout_seconds()),
        },
    ) catch (e) {
        baml.errors.Io => null,
        baml.errors.Timeout => null,
        baml.errors.InvalidArgument => null,
    };
    let exchange_body = match (exchange) {
        null => "",
        let r: baml.http.Response => {
            r.text() catch (e) {
                baml.errors.Io => "",
                baml.errors.Timeout => "",
            }
        },
    };
    let access = baml.json.from_string<AccessTokenResponse>(exchange_body) catch (e) {
        baml.json.ParseError => AccessTokenResponse { access_token: null, error: "parse" },
        baml.json.DecodeError => AccessTokenResponse { access_token: null, error: "decode" },
    };
    let github_token = match (access.access_token) {
        null => throw http_error(401, "oauth_failed", "GitHub token exchange failed"),
        let t: string => t,
    };
    let user = srv_github("GET", "/user", github_token, "");
    let user_id = root.lib.text.Text.parse_int_or_null(srv_json_id(user.body, "id") ?? "") ?? 0;
    let login = srv_json_string(user.body, "login") ?? "";
    if (user_id == 0 || login.is_empty()) {
        throw http_error(401, "oauth_failed", "cannot read GitHub user identity");
    }
    let token = srv_random_hex(32);
    let session = SessionRecord {
        token_hash: srv_token_hash(token),
        csrf: srv_random_hex(16),
        user_id: user_id,
        login: login,
        github_token: github_token,
        created_at: srv_now(),
    };
    store.sessions.push(session);
    srv_save(store, db_path);
    let secure = if (root.lib.env.env_or_null("CODETURTLE_COOKIE_SECURE") == "1") {
        "; Secure"
    } else {
        ""
    };
    srv_redirect(tx.redirect, `ct_session=${token}; HttpOnly; SameSite=Lax; Path=/${secure}`)
}

function srv_session_info(
    store: StoreState,
    req: baml.http.ServerRequest,
) -> baml.http.Response throws HttpError {
    let session = srv_require_session(store, req);
    srv_json(200, SessionResponse { user_id: session.user_id, login: session.login, csrf: session.csrf })
}

function srv_logout(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
) -> baml.http.Response throws HttpError {
    let session = srv_require_session(store, req);
    srv_require_csrf(session, req);
    let idx = store.sessions.find_index((s: SessionRecord) -> bool {
        s.token_hash == session.token_hash
    });
    match (idx) {
        null => null,
        let i: int => store.sessions.remove_at(i),
    };
    srv_save(store, db_path);
    srv_redirect("/", "ct_session=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0")
}

function srv_webhook(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
) -> baml.http.Response throws HttpError {
    match (root.lib.env.env_or_null("CODETURTLE_WEBHOOK_SECRET")) {
        null => null,
        let secret: string => {
            let signature = srv_header(req, "x-hub-signature-256") ?? "";
            let expected = `sha256=${root.lib.hmac.Hmac.sha256_hex(secret, req.body)}`;
            if (signature != expected) {
                throw http_error(401, "invalid_webhook_signature", "webhook signature verification failed");
            }
            null
        },
    };
    let event = srv_header(req, "x-github-event") ?? "";
    if (event == "pull_request") {
        let parsed = baml.json.parse(req.body) catch (e) {
            baml.json.ParseError => null,
        };
        match (parsed) {
            null => null,
            let j: baml.json.json => {
                let action = baml.json.path_or(j, ".action", "");
                let repository = baml.json.path_or(j, ".repository.full_name", "");
                let number = baml.json.path_or(j, ".pull_request.number", 0);
                if (!repository.is_empty() && number > 0) {
                    let pr = srv_get_or_create_pr(store, repository, number);
                    pr.title = srv_json_string(req.body, "pull_request.title") ?? pr.title;
                    pr.author_login
                        = srv_json_string(req.body, "pull_request.user.login") ?? pr.author_login;
                    match (action) {
                        "closed" => {
                            pr.closed = true;
                            pr.state = "closed";
                        },
                        "reopened" => {
                            pr.closed = false;
                            pr.state = "evaluating";
                        },
                        "synchronize" => {
                            pr.state = "evaluating";
                            null
                        },
                        "opened" => {
                            pr.state = "evaluating";
                            null
                        },
                        "edited" => {
                            pr.state = "evaluating";
                            null
                        },
                        _ => null,
                    };
                    pr.version = pr.version + 1;
                    srv_audit(store, pr.id, `webhook_${action}`, "", null);
                    srv_save(store, db_path);
                    srv_publish(store, pr);
                }
                null
            },
        };
    }
    srv_json(202, QueuedResponse { queued: true })
}

function srv_route(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
) -> baml.http.Response throws HttpError {
    let path = srv_path_of(req.url);
    let method = req.method;
    if (method == "GET" && path == "/") {
        return srv_json(200, ServiceInfo { service: "codeturtle-backend", version: root.Versions.evaluator() });
    }
    if (method == "GET" && path == "/v1/auth/github/login") {
        return srv_login(store, db_path, req);
    }
    if (method == "GET" && path == "/v1/auth/github/callback") {
        return srv_callback(store, db_path, req);
    }
    if (method == "GET" && path == "/v1/auth/session") {
        return srv_session_info(store, req);
    }
    if (method == "POST" && path == "/v1/auth/logout") {
        return srv_logout(store, db_path, req);
    }
    if (method == "POST" && path == "/v1/webhooks/github") {
        return srv_webhook(store, db_path, req);
    }
    if (method == "POST" && path == "/v1/evaluation-attempts") {
        return srv_register(store, db_path, req);
    }
    if (method == "GET" && path == "/v1/me/workload") {
        return srv_workload(store, req);
    }
    if (
        (method == "GET" || method == "PUT")
            && path.starts_with("/v1/repositories/")
            && path.ends_with("/enrollment")
    ) {
        let repository = path.slice("/v1/repositories/".length(), path.length() - "/enrollment".length());
        if (method == "GET") {
            return srv_get_enrollment(store, req, repository);
        }
        return srv_put_enrollment(store, db_path, req, repository);
    }
    match (srv_path_segment(path, "/v1/evaluation-attempts/", "/report")) {
        null => null,
        let attempt_id: string => {
            if (method == "PUT") {
                return srv_upload(store, db_path, req, attempt_id);
            }
            null
        },
    };
    match (srv_path_segment(path, "/v1/evaluation-attempts/", "/credentials")) {
        null => null,
        let attempt_id: string => {
            if (method == "POST") {
                return srv_renew(store, db_path, req, attempt_id);
            }
            null
        },
    };
    match (srv_path_segment(path, "/v1/evaluations/", "/files")) {
        null => null,
        let evaluation_id: string => {
            if (method == "GET") {
                return srv_files(store, req, evaluation_id);
            }
            null
        },
    };
    if (path.starts_with("/v1/evaluations/") && path.includes("/files/") && path.ends_with("/diff")) {
        let rest = path.slice("/v1/evaluations/".length(), path.length() - "/diff".length());
        let parts = rest.split("/files/");
        if (method == "GET" && parts.length() == 2) {
            return srv_diff(store, req, parts[0], parts[1]);
        }
    }
    match (srv_path_segment(path, "/v1/evaluations/", "/decisions")) {
        null => null,
        let evaluation_id: string => {
            if (method == "POST") {
                return srv_decide(store, db_path, req, evaluation_id);
            }
            null
        },
    };
    match (srv_path_segment(path, "/v1/evaluations/", "/comments")) {
        null => null,
        let evaluation_id: string => {
            if (method == "POST") {
                return srv_comment(store, db_path, req, evaluation_id);
            }
            null
        },
    };
    match (srv_path_segment(path, "/v1/objections/", "/resolutions")) {
        null => null,
        let objection_id: string => {
            if (method == "POST") {
                return srv_resolve_objection(store, db_path, req, objection_id);
            }
            null
        },
    };
    match (srv_path_segment(path, "/v1/pull-requests/", "/activity")) {
        null => null,
        let pr_id: string => {
            if (method == "GET") {
                return srv_activity(store, req, pr_id);
            }
            null
        },
    };
    match (srv_path_segment(path, "/v1/pull-requests/", "/reevaluations")) {
        null => null,
        let pr_id: string => {
            if (method == "POST") {
                return srv_reevaluate(store, db_path, req, pr_id);
            }
            null
        },
    };
    match (srv_path_segment(path, "/v1/pull-requests/", "")) {
        null => null,
        let pr_id: string => {
            if (method == "GET") {
                return srv_get_pr(store, req, pr_id);
            }
            null
        },
    };
    throw http_error(404, "not_found", `no route for ${method} ${path}`)
}

function srv_handle(
    store: StoreState,
    db_path: string,
    req: baml.http.ServerRequest,
) -> baml.http.Response {
    srv_route(store, db_path, req) catch (e) {
        HttpError => srv_error_response(e, null, null),
    }
}

function srv_read_bytes(path: string) -> uint8array? {
    let file = baml.fs.open(path, "r") catch (e) {
        baml.errors.Io => null,
        baml.errors.InvalidArgument => null,
    };
    match (file) {
        null => null,
        let f: baml.fs.File => {
            f.bytes() catch (e) {
                baml.errors.Io => null,
            }
        },
    }
}

function serve() -> null {
    let db_path = srv_db_path();
    let store = srv_load(db_path);
    let bind = root.lib.env.env_or_null("CODETURTLE_BIND")
        ?? `127.0.0.1:${root.lib.env.env_or_null("PORT") ?? "8787"}`;
    let server = baml.http.Server.bind(bind) catch (e) {
        baml.errors.Io => {
            baml.io.eprintln(`codeturtle backend: cannot bind ${bind}: ${e.message}`);
            baml.sys.exit(2)
        },
    };
    baml.io.println(`codeturtle backend listening on ${server.addr} (db: ${db_path})`);
    let handler = (req: baml.http.ServerRequest) -> baml.http.Response {
        srv_handle(store, db_path, req)
    };
    let cert_path = root.lib.env.env_or_null("CODETURTLE_TLS_CERT");
    let key_path = root.lib.env.env_or_null("CODETURTLE_TLS_KEY");
    if (cert_path != null && key_path != null) {
        let cert = srv_read_bytes(cert_path ?? "");
        let key = srv_read_bytes(key_path ?? "");
        match (cert) {
            null => baml.sys.exit(2),
            let cert_bytes: uint8array => match (key) {
                null => baml.sys.exit(2),
                let key_bytes: uint8array => {
                    let tls = baml.http.TlsConfig.new(cert_bytes, key_bytes) catch (e) {
                        baml.errors.Io => baml.sys.exit(2),
                    };
                    server.serve(handler, tls_config = tls) catch (e) {
                        baml.errors.Io => baml.sys.exit(2),
                    }
                },
            },
        }
    } else {
        server.serve(handler) catch (e) {
            baml.errors.Io => baml.sys.exit(2),
        }
    }
}
