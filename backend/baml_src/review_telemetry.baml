// Only identifiers and ownership metadata; never capture report bodies or credentials.
function record_review_event() -> void {}

function emit_review_event(event: json) -> void {
    record_review_event($trace = trace.span(inputs = false, output = false, error = false).context(
        metadata = {"service": "codeturtle", "stage": "review", "event": baml.json.stringify(event)},
    ))
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
