// Backend domain records. Persisted as one JSON state file; every
// mutation rewrites it atomically. IDs are opaque sequential strings.

type ReviewState = "evaluating"
    | "awaiting_review"
    | "blocked"
    | "evaluation_error"
    | "approved"
    | "closed";

type PublicationState = "pending" | "synced" | "error";

type DecisionAction = "approve" | "reject" | "withdraw";

class Enrollment {
    repository: string,
    trusted_workflow: string?,
    allow_self_review: bool,
    enabled: bool,
}

class PrRecord {
    id: string,
    repository: string,
    number: int,
    title: string?,
    author_login: string?,
    closed: bool,
    current_evaluation_id: string?,
    version: int,
    state: ReviewState,
    publication: PublicationState,
    check_run_id: string?,
    summary_comment_id: string?,
    bot_review_id: string?,
}

class AttemptRecord {
    id: string,
    evaluation_id: string,
    pr_id: string,
    repository: string,
    pr_number: int,
    run_id: string,
    run_attempt: string,
    head_sha: string,
    base_sha: string,
    merge_base: string,
    upload_token_hash: string,
    report_digest: string?,
    created_at: string,
}

class EvaluationRecord {
    id: string,
    pr_id: string,
    inputs: root.ReportInputs,
    succeeded: bool,
    files: root.FileOutcome[],
    requirements: root.Requirement[],
    rule_evaluations: root.RuleEvaluation[],
    errors: root.Diagnostic[],
    current: bool,
    created_at: string,
}

class DecisionRecord {
    id: string,
    evaluation_id: string,
    pr_id: string,
    path: string,
    actor_id: int,
    actor_login: string,
    action: DecisionAction,
    explanation: string?,
    diff_digest: string,
    idempotency_key: string,
    at: string,
}

class ObjectionRecord {
    id: string,
    evaluation_id: string,
    pr_id: string,
    path: string,
    actor_id: int,
    actor_login: string,
    explanation: string,
    open: bool,
    created_at: string,
    resolved_at: string?,
}

class CommentRecord {
    id: string,
    evaluation_id: string,
    pr_id: string,
    path: string,
    side: string,
    line: int,
    body: string,
    author_login: string,
    diff_digest: string,
    at: string,
}

class SessionRecord {
    token_hash: string,
    csrf: string,
    user_id: int,
    login: string,
    github_token: string,
    created_at: string,
}

class OAuthTxRecord {
    state: string,
    code_verifier: string,
    redirect: string,
}

class AuditEvent {
    id: string,
    pr_id: string,
    kind: string,
    detail: string,
    actor: string?,
    at: string,
}

class StoreState {
    next_id: int,
    enrollments: Enrollment[],
    prs: PrRecord[],
    attempts: AttemptRecord[],
    evaluations: EvaluationRecord[],
    decisions: DecisionRecord[],
    objections: ObjectionRecord[],
    comments: CommentRecord[],
    sessions: SessionRecord[],
    oauth_txs: OAuthTxRecord[],
    audit: AuditEvent[],
}

class HttpError {
    status: int,
    code: string,
    message: string,
    retryable: bool,
}

function http_error(status: int, code: string, message: string) -> HttpError {
    HttpError { status: status, code: code, message: message, retryable: status >= 500 }
}

class SrvErrorBody {
    code: string,
    message: string,
    request_id: string,
    retryable: bool,
    current_evaluation_id: string?,
    version: int?,
}

function srv_now() -> string {
    string.from(baml.time.Instant.now())
}

function srv_random_hex(byte_count: int) -> string {
    baml.random.SystemRandom.get().random(byte_count).to_hex()
}

function srv_pr_id(repository: string, number: int) -> string {
    `${repository}#${number}`
}
