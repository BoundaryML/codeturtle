// A GitHub review is a summary of the persisted, per-file CodeTurtle sign-offs.
function review_ready(report: json, decisions: ReviewDecision[]) -> bool {
    if (report == null || field(report, "evaluation_complete") != true) { return false; }
    if (field(report, "errors") == null || baml.json.to<json[]>(field(report, "errors")).length() > 0) { return false; }
    let requirements = review_requirements(report);
    if (requirements.length() == 0) { return false; }
    let index = 0;
    for (let requirement in requirements) {
        if (!requirement_reviewed(requirement, index, decisions)) { return false; }
        index += 1;
    }
    true
}

function bot_reviews(github: GitHubClient, repository: string, pr: int, token: string) -> json[] {
    let result: json[] = [];
    let page = 1;
    while (page <= 100) {
        let reviews = baml.json.to<json[]>(github.api("GET", repository, `/pulls/${pr}/reviews?per_page=100&page=${page}`, token));
        for (let review in reviews) {
            if (num(field(review, "user"), "id") == github.bot_id && str(review, "body").includes("<!-- codeturtle-review:")) { result.push(review); }
        }
        if (reviews.length() < 100) { return result; }
        page += 1;
    }
    throw ApiError {status: 503, code: "review_reconciliation_limit"}
}

function dismiss_bot_review(github: GitHubClient, repository: string, pr: int, token: string, review: json) -> void {
    let _ = github.api("PUT", repository, `/pulls/${pr}/reviews/${num(review, "id")}/dismissals`, token,
        body = {"message": "CodeTurtle approval is no longer current. Required file reviews must be satisfied again."});
}

function sync_bot_review(github: GitHubClient, run: StoredRun, origin: string, decisions: ReviewDecision[]) -> void {
    let i = run.authorized.identity;
    let token = github.installation_token(run.authorized.enrollment, write = true);
    let pr = github.current_pr(i, token);
    let marker = `<!-- codeturtle-review:${run.id}:${i.head}:${i.base} -->`;
    let ready = run.envelope != null && run.envelope?.setup_failure == null
        && field(pr, "draft") != true && review_ready(run.envelope?.report, decisions);
    let reviews = bot_reviews(github, i.repository, i.pr, token);
    let existing = false;
    //# Reconcile after retries, and remove approvals whose coverage is no longer valid.
    for (let review in reviews) {
        let current = field(review, "commit_id") == i.head && str(review, "body").includes(marker);
        if (field(review, "state") == "APPROVED") {
            if (ready && current) { existing = true; }
            else { dismiss_bot_review(github, i.repository, i.pr, token, review); }
        }
        if (!ready && current && field(review, "state") == "COMMENTED") { existing = true; }
    }
    if (existing) { return; }
    let _ = github.current_pr(i, token);
    let message = if (ready) { "All required CodeTurtle file reviews are satisfied for this revision." }
        else if (no_review_required(run.envelope?.report)) { "No files match the configured review rules. No CodeTurtle review required" }
        else { "Waiting for required CodeTurtle file reviews. This is not an approval." };
    let created = github.api("POST", i.repository, `/pulls/${i.pr}/reviews`, token,
        body = {"commit_id": i.head, "event": if (ready) {"APPROVE"} else {"COMMENT"},
            "body": message + "\n\n[Open CodeTurtle review](" + origin + "/?run=" + run.id + ")\n\n" + marker});
    // Recheck after the write: never leave approval on a head/base changed during delivery.
    if (ready) {
        github.check_current(run.authorized) catch_all (error) {
            _ => { dismiss_bot_review(github, i.repository, i.pr, token, created); throw error; }
        };
    }
}

// Called only after the webhook signature has been verified. Read current GitHub
// state rather than trusting delayed or out-of-order webhook revisions.
function invalidate_bot_review(github: GitHubClient, store: RunStore, payload: json) -> void {
    let repository_id = num(field(payload, "repository"), "id").to_string();
    let enrollment = store.rpc("enrollment", {"repository_id": repository_id});
    if (enrollment == null) { return; }
    let e = baml.json.to<Enrollment>(enrollment);
    if (!e.active) { return; }
    let token = github.installation_token(e, write = true);
    let pr_number = num(payload, "number");
    let pr = github.api("GET", e.repository, `/pulls/${pr_number}`, token);
    let revision = ":" + str(field(pr, "head"), "sha") + ":" + str(field(pr, "base"), "sha") + " -->";
    for (let review in bot_reviews(github, e.repository, pr_number, token)) {
        if (field(review, "state") == "APPROVED" && (field(pr, "draft") == true || !str(review, "body").includes(revision))) {
            dismiss_bot_review(github, e.repository, pr_number, token, review);
        }
    }
}

test "Native approval requires every file, not just one reviewer" {
    let report: json = {"evaluation_complete": true, "errors": [], "requirements": [
        {"path":"a.txt", "owners":["@a"], "approval":"Any"},
        {"path":"b.txt", "owners":["@b"], "approval":"Any"}
    ]};
    let a = ReviewDecision {requirement_index:0,owner:"@a",github_user_id:"1",github_login:"a",reviewed_at:"now"};
    let b = ReviewDecision {requirement_index:1,owner:"@b",github_user_id:"2",github_login:"b",reviewed_at:"now"};
    assert.equal(review_ready(report, []), false);
    assert.equal(review_ready(report, [a]), false);
    assert.equal(review_ready(report, [a,b]), true);
    assert.equal(review_ready({"evaluation_complete":false,"errors":[],"requirements":[]}, []), false);
    assert.equal(review_ready({"evaluation_complete":true,"errors":[],"requirements":[]}, []), false);
}
