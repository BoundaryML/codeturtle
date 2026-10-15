// JSON-file store. Load once at startup; save atomically after every
// mutation (temp file + rename). Single-process by design.

function srv_db_path() -> string {
    root.lib.env.env_or_null("CODETURTLE_DB") ?? "codeturtle-db.json"
}

function srv_empty_state() -> StoreState {
    StoreState {
        next_id: 1,
        enrollments: [],
        prs: [],
        attempts: [],
        evaluations: [],
        decisions: [],
        objections: [],
        comments: [],
        sessions: [],
        oauth_txs: [],
        audit: [],
    }
}

function srv_load(path: string) -> StoreState {
    if (!baml.fs.exists(path)) {
        return srv_empty_state();
    }
    let text = baml.fs.read(path) catch (e) {
        baml.errors.Io => null,
        baml.errors.ParseError => null,
    };
    match (text) {
        null => srv_empty_state(),
        let raw: string => {
            baml.json.from_string<StoreState>(raw) catch (e) {
                baml.json.ParseError => srv_empty_state(),
                baml.json.DecodeError => srv_empty_state(),
            }
        },
    }
}

function srv_save(store: StoreState, path: string) -> null {
    let text = baml.json.to_string(store) catch (e) {
        baml.json.SerializationError => "",
    };
    if (text.is_empty()) {
        return null;
    }
    let tmp = `${path}.tmp-${baml.sys.pid()}`;
    let written = baml.fs.write(tmp, text) catch (e) {
        baml.errors.Io => -1,
    };
    if (written >= 0) {
        baml.sys.exec("mv", [tmp, path], null) catch (e) {
            baml.errors.Io => null,
            baml.errors.Timeout => null,
        };
    }
    null
}

function srv_next_id(store: StoreState, prefix: string) -> string {
    let id = `${prefix}_${store.next_id}`;
    store.next_id = store.next_id + 1;
    id
}

function srv_audit(
    store: StoreState,
    pr_id: string,
    kind: string,
    detail: string,
    actor: string?,
) -> null {
    store.audit.push(
        AuditEvent {
            id: srv_next_id(store, "evt"),
            pr_id: pr_id,
            kind: kind,
            detail: detail,
            actor: actor,
            at: srv_now(),
        },
    );
    null
}

function srv_enrollment(store: StoreState, repository: string) -> Enrollment? {
    store.enrollments.find((e: Enrollment) -> bool {
        e.repository == repository
    })
}

function srv_pr(store: StoreState, pr_id: string) -> PrRecord? {
    store.prs.find((p: PrRecord) -> bool {
        p.id == pr_id
    })
}

function srv_pr_by_repo_number(store: StoreState, repository: string, number: int) -> PrRecord? {
    store.prs.find((p: PrRecord) -> bool {
        p.repository == repository && p.number == number
    })
}

function srv_get_or_create_pr(store: StoreState, repository: string, number: int) -> PrRecord {
    match (srv_pr_by_repo_number(store, repository, number)) {
        null => {
            let created = PrRecord {
                id: srv_next_id(store, "pr"),
                repository: repository,
                number: number,
                title: null,
                author_login: null,
                closed: false,
                current_evaluation_id: null,
                version: 1,
                state: "evaluating",
                publication: "pending",
                check_run_id: null,
                summary_comment_id: null,
                bot_review_id: null,
            };
            store.prs.push(created);
            created
        },
        let existing: PrRecord => existing,
    }
}

function srv_attempt(store: StoreState, attempt_id: string) -> AttemptRecord? {
    store.attempts.find((a: AttemptRecord) -> bool {
        a.id == attempt_id
    })
}

function srv_evaluation(store: StoreState, evaluation_id: string) -> EvaluationRecord? {
    store.evaluations.find((e: EvaluationRecord) -> bool {
        e.id == evaluation_id
    })
}

function srv_current_evaluation(store: StoreState, pr: PrRecord) -> EvaluationRecord? {
    match (pr.current_evaluation_id) {
        null => null,
        let id: string => srv_evaluation(store, id),
    }
}

function srv_token_hash(token: string) -> string {
    root.lib.digest.Digest.sha256_hex(token)
}
