// Only identifiers and ownership metadata; never capture report bodies or credentials.
function record_review_event() -> void {}

function emit_review_event(event: json) -> void {
    record_review_event($trace = trace.span(inputs = false, output = false, error = false).context(
        metadata = {"service": "codeturtle", "stage": "review", "event": baml.json.stringify(event)},
    ))
}

function report_evaluation_status(report: json) -> string {
    let errors = baml.json.to<json[]?>(field(report, "errors"));
    if (report == null || errors == null) { return "failed"; }
    if (errors.length() > 0) { return "failed"; }
    let exit_code = field(report, "cli_exit_code");
    if (exit_code != null) { return if (exit_code == 0) { "passed" } else { "failed" }; }
    // Older CLIs exit 1 for incomplete coverage, including unmatched-only changes.
    if (field(report, "evaluation_complete") != true) { return "failed"; }
    "passed"
}

test "Telemetry reports legacy incomplete evaluations as failures" {
    let report: json = {"requirements": [], "errors": [], "evaluation_complete": false};
    assert.equal(report_evaluation_status(report), "failed");
    assert.equal(report_evaluation_status({"requirements": [], "errors": [], "evaluation_complete": false, "cli_exit_code": 0}), "passed");
    assert.equal(report_evaluation_status({"errors": [{"message": "Bad policy"}], "cli_exit_code": 0}), "failed");
    assert.equal(report_evaluation_status(null), "failed")
}

function trace_review_report(run: StoredRun, author: string) -> void {
    let envelope = run.envelope;
    if (envelope == null) { return; }
    let requirements = review_requirements(envelope.report);
    let identity = run.authorized.identity;
    let summary: json = {
        "kind": "report", "run_id": run.id, "repository": identity.repository,
        "pr": identity.pr, "head": identity.head, "occurred_at": run.accepted_at,
        "author": author, "title": run.authorized.title,
        "source": "live", "requirements": requirements.length(),
        "github_run_id": identity.run_id, "attempt": identity.run_attempt,
        "evaluation_status": if (envelope.setup_failure != null) { "failed" } else { report_evaluation_status(envelope.report) },
        "cli_exit_code": field(envelope.report, "cli_exit_code"),
        "evaluation_complete": field(envelope.report, "evaluation_complete"),
        "unowned_files": field(envelope.report, "unowned_files"),
        "outcome": if (envelope.setup_failure != null) { "Setup failed" }
            else if (no_review_required(envelope.report)) { "No review required" }
            else { "Review required" },
    };
    emit_review_event(summary);
    let index = 0;
    for (let requirement in requirements) {
        emit_review_event({
            "kind": "assignment", "run_id": run.id, "repository": identity.repository,
            "pr": identity.pr, "head": identity.head, "occurred_at": run.accepted_at,
            "source": "live", "index": index,
            "path": str(requirement, "path"), "owners": field(requirement, "owners"),
        });
        index += 1;
    }
}

// Import historical metadata without replaying application side effects.
function import_review_events(path: string) -> void {
    for (let event in baml.json.from_string<json[]>(baml.fs.read(path))) {
        emit_review_event(event);
    }
}

// Invoked only after GitHub webhook signature validation. Captures failures before report upload too.
function trace_workflow_job(store: RunStore, payload: json) -> void {
    if (str(payload, "action") != "completed") { return; }
    let job = field(payload, "workflow_job");
    if (str(job, "name") != "codeturtle") { return; }
    let repository = field(payload, "repository");
    let enrollment = store.rpc("enrollment", {"repository_id": field(repository, "id").to_string()});
    if (enrollment == null) { return; }
    let e = baml.json.to<Enrollment>(enrollment);
    if (!e.active) { return; }
    emit_review_event({
        "kind": "workflow", "run_id": "github-run:" + field(job, "run_id").to_string(),
        "github_run_id": field(job, "run_id").to_string(), "attempt": field(job, "run_attempt"),
        "repository": e.repository, "head": str(job, "head_sha"),
        "occurred_at": str(job, "completed_at"), "source": "live",
        "workflow_status": str(job, "conclusion"), "job_url": str(job, "html_url"),
        "started_at": str(job, "started_at"), "completed_at": str(job, "completed_at"),
    });
}
