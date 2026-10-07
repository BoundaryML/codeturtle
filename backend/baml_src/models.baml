class ApiError {
    status: int,
    code: string,
}

class RunIdentity {
    repository_id: string,
    repository: string,
    pr: int,
    run_id: string,
    run_attempt: int,
    head: string,
    base: string,
    policy: string,
}

class Enrollment {
    repository_id: string,
    repository: string,
    tenant_id: string,
    installation_id: int,
    workflow_ref: string,
    workflow_blob: string,
    active: bool,
    slack: SlackInstallation?,
}

class AuthorizedRun {
    identity: RunIdentity,
    enrollment: Enrollment,
    merge_base: string,
    title: string,
}

class RunGrant {
    run_id: string,
    token: string,
    expires_at: int,
    identity: RunIdentity,
    merge_base: string,
    title: string,
}

class SetupFailure {
    code: "evaluation_setup_failed",
    message: string,
}

class ReportEnvelope {
    schema_version: int,
    cli_version: string,
    run_id: string,
    identity: RunIdentity,
    report: json,
    setup_failure: SetupFailure?,
}

class Receipt {
    run_id: string,
    digest: string,
    accepted_at: string,
    status_url: string,
}

class StoredRun {
    id: string,
    authorized: AuthorizedRun,
    expires_at: int,
    digest: string?,
    accepted_at: string?,
    envelope: ReportEnvelope?,
    deliveries: json,
}

class SlackRef {
    workspace_id: string,
    channel: string,
    ts: string,
}

class SlackInstallation {
    workspace_id: string,
    channel: string,
    encrypted_token: string,
    owners: map<string, string>,
}

class MentionResult {
    mentions: string[],
    unmapped: string[],
}

class CommentRef {
    id: int,
}

class Actor {
    user_id: string,
    tenant_id: string,
}

type ReportParser = (string) -> json throws unknown;

function require(ok: bool, status: int, code: string) -> void {
    if (!ok) {
        throw ApiError { status: status, code: code };
    }
}

function sha256(text: string) -> string {
    let h = baml.crypto.Sha256.new();
    h.update(text.to_utf8());
    h.finish().to_hex()
}

function now() -> int {
    baml.Int.parse(baml.time.Instant.now().to_timestamp_seconds().to_string())
}

function secret() -> string {
    baml.random.SystemRandom.get().random(32).to_hex()
}

function field(value: json, name: string) -> json {
    baml.json.field(value, name)
}

function str(value: json, name: string) -> string {
    baml.json.to<string>(field(value, name))
}

function num(value: json, name: string) -> int {
    baml.json.to<int>(field(value, name))
}

function matches(value: string, pattern: string) -> bool {
    baml.regex.new(pattern).has_match(value)
}

function validate_identity(i: RunIdentity) -> void {
    require(
        matches(i.repository_id, "^[1-9][0-9]*$")
            && matches(i.run_id, "^[1-9][0-9]*$")
            && i.pr > 0
            && i.run_attempt > 0,
        400,
        "invalid_identity",
    );
    require(
        matches(i.repository, "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
            && [i.head, i.base, i.policy].every((s) -> {
                matches(s, "^[0-9a-f]{40}$")
            })
            && i.base == i.policy,
        400,
        "invalid_revisions",
    );
}

function report_parser(models_path: string) -> ReportParser {
    // Only installed trusted declarations are compiled; no customer sources.
    let p = reflect.Package.compile(
        {
            "models.baml": baml.fs.read(models_path),
            "parser.baml": `function parse_report(raw: string) -> json { baml.json.from(baml.json.from_string<Report>(raw)) }`,
        },
    );
    p.get_function<ReportParser>("root.parse_report") ?? throw "Missing report parser"
}

function validate_envelope(e: ReportEnvelope, run: StoredRun, parser: ReportParser) -> void {
    require(
        e.schema_version == 1
            && e.cli_version.length() < 80
            && e.run_id == run.id
            && e.identity == run.authorized.identity,
        400,
        "invalid_envelope",
    );
    require((e.report == null) != (e.setup_failure == null), 400, "exclusive_payload_required");
    if (e.report != null) {
        let report = parser(baml.json.stringify(e.report)) catch_all (_) {
            _ => throw ApiError {status: 400, code: "invalid_report"}
        };
        let context = field(report, "context");
        let i = e.identity;
        require(
            str(context, "base_revision") == i.base
                && str(context, "head_revision") == i.head
                && str(context, "policy_revision") == i.policy
                && str(context, "merge_base") == run.authorized.merge_base
                && str(context, "policy_source") == "base_revision",
            400,
            "report_revision_mismatch",
        );
        let errors = baml.json.to<json[]>(field(report, "errors"));
        let unowned = baml.json.to<string[]>(field(report, "unowned_files"));
        require(
            baml.json.to<bool>(field(report, "evaluation_complete"))
                == (errors.length() == 0 && unowned.length() == 0),
            400,
            "inconsistent_evaluation",
        );
    }
}
