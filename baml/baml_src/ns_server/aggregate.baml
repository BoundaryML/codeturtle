// Decision projection and collective approval. Pure over store
// records; team membership arrives as data so tests inject it and the
// HTTP layer fills it from the GitHub API.

function srv_latest_decisions(store: StoreState, evaluation_id: string) -> DecisionRecord[] {
    let latest: DecisionRecord[] = [];
    for (let d in store.decisions) {
        if (d.evaluation_id != evaluation_id) {
            continue;
        }
        let idx = latest.find_index((x: DecisionRecord) -> bool {
            x.actor_id == d.actor_id && x.path == d.path
        });
        if (idx == null) {
            latest.push(d);
        } else {
            latest[idx ?? 0] = d;
        }
    }
    latest
}

function srv_is_eligible(
    actor_login: string,
    owner: string,
    memberships: map<string, bool>,
    pr_author: string?,
    allow_self_review: bool,
) -> bool {
    if (
        !allow_self_review
            && pr_author != null
            && actor_login.to_lower_case() == (pr_author ?? "").to_lower_case()
    ) {
        return false;
    }
    let body = if (owner.starts_with("@")) {
        owner.slice(1, owner.length())
    } else {
        owner
    };
    if (body.includes("/")) {
        memberships.get(`${body}|${actor_login.to_lower_case()}`) ?? false
    } else {
        actor_login.to_lower_case() == body.to_lower_case()
    }
}

function srv_slot_satisfied(
    requirement: root.Requirement,
    owner: string,
    latest: DecisionRecord[],
    memberships: map<string, bool>,
    pr_author: string?,
    allow_self_review: bool,
) -> bool {
    latest.some((d: DecisionRecord) -> bool {
        d.path == requirement.path
            && d.action == "approve"
            && srv_is_eligible(d.actor_login, owner, memberships, pr_author, allow_self_review)
    })
}

function srv_requirement_satisfied(
    requirement: root.Requirement,
    latest: DecisionRecord[],
    memberships: map<string, bool>,
    pr_author: string?,
    allow_self_review: bool,
) -> bool {
    match (requirement.threshold) {
        "any" => {
            requirement.owners.some((owner: string) -> bool {
                srv_slot_satisfied(requirement, owner, latest, memberships, pr_author, allow_self_review)
            })
        },
        "all" => {
            requirement.owners.every((owner: string) -> bool {
                srv_slot_satisfied(requirement, owner, latest, memberships, pr_author, allow_self_review)
            })
        },
    }
}

function srv_actor_eligible_for_file(
    evaluation: EvaluationRecord,
    path: string,
    actor_login: string,
    memberships: map<string, bool>,
    pr_author: string?,
    allow_self_review: bool,
) -> bool {
    evaluation.requirements.some((r: root.Requirement) -> bool {
        r.path == path
            && r.owners.some((owner: string) -> bool {
                srv_is_eligible(actor_login, owner, memberships, pr_author, allow_self_review)
            })
    })
}

function srv_open_objections(
    store: StoreState,
    pr_id: string,
    evaluation_id: string?,
) -> ObjectionRecord[] {
    store.objections.filter((o: ObjectionRecord) -> bool {
        o.pr_id == pr_id && o.open && (evaluation_id == null || o.evaluation_id == evaluation_id)
    })
}

function srv_compute_state(
    store: StoreState,
    pr: PrRecord,
    memberships: map<string, bool>,
    allow_self_review: bool,
) -> ReviewState {
    if (pr.closed) {
        return "closed";
    }
    match (srv_current_evaluation(store, pr)) {
        null => "evaluating",
        let evaluation: EvaluationRecord => {
            if (!evaluation.succeeded) {
                return "evaluation_error";
            }
            if (srv_open_objections(store, pr.id, null).length() > 0) {
                return "blocked";
            }
            let latest = srv_latest_decisions(store, evaluation.id);
            let all_satisfied = evaluation.requirements.every((r: root.Requirement) -> bool {
                srv_requirement_satisfied(r, latest, memberships, pr.author_login, allow_self_review)
            });
            if (all_satisfied) {
                "approved"
            } else {
                "awaiting_review"
            }
        },
    }
}

function srv_allow_self_review(store: StoreState, pr: PrRecord) -> bool {
    match (srv_enrollment(store, pr.repository)) {
        null => false,
        let e: Enrollment => e.allow_self_review,
    }
}

function srv_refresh_state(
    store: StoreState,
    pr: PrRecord,
    memberships: map<string, bool>,
) -> null {
    pr.state = srv_compute_state(store, pr, memberships, srv_allow_self_review(store, pr));
    pr.version = pr.version + 1;
    pr.publication = "pending";
    null
}

class DecisionRequest {
    path: string,
    action: DecisionAction,
    explanation: string?,
    diff_digest: string,
    version: int?,
    idempotency_key: string,
}

function srv_apply_decision(
    store: StoreState,
    evaluation: EvaluationRecord,
    pr: PrRecord,
    actor_id: int,
    actor_login: string,
    request: DecisionRequest,
    memberships: map<string, bool>,
) -> DecisionRecord throws HttpError {
    let prior = store.decisions.find((d: DecisionRecord) -> bool {
        d.evaluation_id == evaluation.id && d.idempotency_key == request.idempotency_key
    });
    match (prior) {
        null => null,
        let existing: DecisionRecord => {
            if (
                existing.path == request.path
                    && existing.action == request.action
                    && existing.actor_id == actor_id
            ) {
                return existing;
            }
            throw http_error(409, "idempotency_conflict", "idempotency key was reused with a different decision");
        },
    };
    if (pr.closed) {
        throw http_error(409, "pull_request_closed", "pull request is closed; decisions are read-only");
    }
    if (pr.current_evaluation_id != evaluation.id) {
        throw http_error(409, "stale_evaluation", "evaluation is not current; reload and review the current files");
    }
    match (request.version) {
        null => null,
        let v: int => {
            if (v != pr.version) {
                throw http_error(412, "stale_version", "pull request state changed; reload before deciding");
            }
            null
        },
    };
    let file = evaluation.files.find((f: root.FileOutcome) -> bool {
        f.path == request.path
    });
    let outcome = match (file) {
        null => {
            throw http_error(422, "unknown_file", `file ${request.path} is not in this evaluation`)
        },
        let f: root.FileOutcome => f,
    };
    if (outcome.digest != request.diff_digest) {
        throw http_error(409, "stale_evaluation", "diff digest does not match the current file state");
    }
    let allow_self = srv_allow_self_review(store, pr);
    if (
        request.action != "withdraw"
            && !srv_actor_eligible_for_file(evaluation, request.path, actor_login, memberships, pr.author_login, allow_self)
    ) {
        throw http_error(403, "not_eligible", "actor holds no owner slot for this file");
    }
    if (
        request.action == "reject"
            && (request.explanation == null || (request.explanation ?? "").trim().is_empty())
    ) {
        throw http_error(422, "explanation_required", "reject requires an explanation");
    }
    let record = DecisionRecord {
        id: srv_next_id(store, "dec"),
        evaluation_id: evaluation.id,
        pr_id: pr.id,
        path: request.path,
        actor_id: actor_id,
        actor_login: actor_login,
        action: request.action,
        explanation: request.explanation,
        diff_digest: request.diff_digest,
        idempotency_key: request.idempotency_key,
        at: srv_now(),
    };
    store.decisions.push(record);
    match (request.action) {
        "reject" => {
            store.objections.push(
                ObjectionRecord {
                    id: srv_next_id(store, "obj"),
                    evaluation_id: evaluation.id,
                    pr_id: pr.id,
                    path: request.path,
                    actor_id: actor_id,
                    actor_login: actor_login,
                    explanation: request.explanation ?? "",
                    open: true,
                    created_at: srv_now(),
                    resolved_at: null,
                },
            );
            null
        },
        _ => {
            for (let objection in store.objections) {
                if (
                    objection.pr_id == pr.id
                        && objection.path == request.path
                        && objection.actor_id == actor_id
                        && objection.open
                ) {
                    objection.open = false;
                    objection.resolved_at = srv_now();
                }
            }
            null
        },
    };
    srv_audit(store, pr.id, `decision_${request.action}`, request.path, actor_login);
    srv_refresh_state(store, pr, memberships);
    record
}

function srv_test_setup() -> StoreState {
    let store = srv_empty_state();
    store.enrollments.push(
        Enrollment {
            repository: "example/project",
            trusted_workflow: null,
            allow_self_review: false,
            enabled: true,
        },
    );
    let pr = srv_get_or_create_pr(store, "example/project", 42);
    let evaluation = EvaluationRecord {
        id: srv_next_id(store, "eval"),
        pr_id: pr.id,
        inputs: root.ReportInputs {
            mode: "hosted",
            repository: "example/project",
            pr_number: 42,
            base: "bbbb",
            head: "aaaa",
            merge_base: "bbbb",
            policy_digest: "d5ab",
            evaluator_version: "0.1.0",
        },
        succeeded: true,
        files: [
            root.FileOutcome {
                path: "stdlib/env.baml",
                old_path: null,
                status: "modified",
                required: true,
                digest: "d-stdlib",
            },
            root.FileOutcome {
                path: "app/config.ts",
                old_path: null,
                status: "modified",
                required: true,
                digest: "d-app",
            },
            root.FileOutcome {
                path: "docs/readme.md",
                old_path: null,
                status: "modified",
                required: false,
                digest: "d-docs",
            },
        ],
        requirements: [
            root.Requirement {
                path: "stdlib/env.baml",
                rule_line: 4,
                condition: null,
                owners: ["@alice", "@bob"],
                threshold: "all",
                verdict: "applies",
                reason: "matches /stdlib/",
                evidence: null,
            },
            root.Requirement {
                path: "app/config.ts",
                rule_line: 5,
                condition: "checks.adds_environment_access",
                owners: ["@example/security"],
                threshold: "any",
                verdict: "applies",
                reason: "introduces environment access",
                evidence: null,
            },
        ],
        rule_evaluations: [],
        errors: [],
        current: true,
        created_at: "2026-01-01T00:00:00Z",
    };
    store.evaluations.push(evaluation);
    pr.current_evaluation_id = evaluation.id;
    pr.state = "awaiting_review";
    store
}

function srv_test_decision(
    path: string,
    action: DecisionAction,
    digest: string,
    key: string,
) -> DecisionRequest {
    DecisionRequest {
        path: path,
        action: action,
        explanation: null,
        diff_digest: digest,
        version: null,
        idempotency_key: key,
    }
}

test "all requires every owner and any accepts a verified team member" {
    let store = srv_test_setup();
    let pr = srv_pr_by_repo_number(store, "example/project", 42)
        ?? srv_get_or_create_pr(store, "example/project", 42);
    let evaluation = srv_current_evaluation(store, pr) ?? srv_test_setup().evaluations[0];
    let memberships: map<string, bool> = { "example/security|carol": true };
    srv_apply_decision(
        store,
        evaluation,
        pr,
        1,
        "alice",
        srv_test_decision("stdlib/env.baml", "approve", "d-stdlib", "k1"),
        memberships,
    );
    assert.equal(pr.state, "awaiting_review");
    srv_apply_decision(
        store,
        evaluation,
        pr,
        3,
        "carol",
        srv_test_decision("app/config.ts", "approve", "d-app", "k2"),
        memberships,
    );
    assert.equal(pr.state, "awaiting_review");
    srv_apply_decision(
        store,
        evaluation,
        pr,
        2,
        "bob",
        srv_test_decision("stdlib/env.baml", "approve", "d-stdlib", "k3"),
        memberships,
    );
    assert.equal(pr.state, "approved")
}

test "rejection blocks until withdrawn and stale digests are rejected" {
    let store = srv_test_setup();
    let pr = srv_pr_by_repo_number(store, "example/project", 42)
        ?? srv_get_or_create_pr(store, "example/project", 42);
    let evaluation = srv_current_evaluation(store, pr) ?? srv_test_setup().evaluations[0];
    let reject = DecisionRequest {
        path: "stdlib/env.baml",
        action: "reject",
        explanation: "needs a test",
        diff_digest: "d-stdlib",
        version: null,
        idempotency_key: "r1",
    };
    srv_apply_decision(store, evaluation, pr, 1, "alice", reject, {});
    assert.equal(pr.state, "blocked");
    srv_apply_decision(
        store,
        evaluation,
        pr,
        1,
        "alice",
        srv_test_decision("stdlib/env.baml", "withdraw", "d-stdlib", "r2"),
        {},
    );
    assert.equal(pr.state, "awaiting_review");
    let stale = srv_apply_decision(
        store,
        evaluation,
        pr,
        1,
        "alice",
        srv_test_decision("stdlib/env.baml", "approve", "wrong", "r3"),
        {},
    ) catch (e) {
        HttpError => e.code,
    };
    assert.equal(stale, "stale_evaluation");
    let replay = srv_apply_decision(
        store,
        evaluation,
        pr,
        1,
        "alice",
        srv_test_decision("stdlib/env.baml", "withdraw", "d-stdlib", "r2"),
        {},
    );
    assert.equal(store.decisions.length(), 2)
}
