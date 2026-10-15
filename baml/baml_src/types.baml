// Domain and wire types. Wire-visible discriminators are literal unions
// so JSON is exact and `match` stays exhaustive end to end.

class UserOwner {
    handle: string,
}

class TeamOwner {
    org: string,
    team: string,
}

implement baml.ToString for UserOwner {
    function to_string(self) -> string {
        `@${self.handle}`
    }
}

implement baml.ToString for TeamOwner {
    function to_string(self) -> string {
        `@${self.org}/${self.team}`
    }
}

type Owner = UserOwner | TeamOwner;

type Threshold = "any" | "all";

type ChangeStatus = "added" | "modified" | "deleted" | "renamed" | "typechanged";

type Verdict = "applies" | "does_not_apply" | "uncertain";

class Hunk {
    header: string,
    lines: string[],
}

class FileChange {
    path: string,
    old_path: string?,
    status: ChangeStatus,
    before_blob: string?,
    after_blob: string?,
    before_text: string?,
    after_text: string?,
    added_text: string,
    removed_text: string,
    patch: string,
    hunks: Hunk[],
    is_binary: bool,
    content_available: bool,
    is_submodule: bool,
    is_symlink: bool,
}

// Detailed predicate result. Named `Match` in the authoring contract.
class Match {
    path: string,
    verdict: Verdict,
    reason: string,
    evidence: string?,
}

class PullRequest {
    repository: string,
    number: int,
    title: string,
    body: string,
    labels: string[],
    author_id: string,
    head: string,
    base: string,
    merge_base: string,
    changes: FileChange[],
}

class Rule {
    pattern: string,
    owners: Owner[],
    threshold: Threshold,
    condition: string?,
    line: int,
    raw: string,

    function owner_handles(self) -> string[] {
        self.owners.map((o: Owner) -> string {
            string.from(o)
        })
    }
}

class Policy {
    rules: Rule[],
    digest: string,
}

class Requirement {
    path: string,
    rule_line: int,
    condition: string?,
    owners: string[],
    threshold: Threshold,
    verdict: Verdict,
    reason: string,
    evidence: string?,

    function threshold_label(self) -> string {
        match (self.threshold) {
            "any" => "ANY",
            "all" => "ALL",
        }
    }
}

class FileOutcome {
    path: string,
    old_path: string?,
    status: ChangeStatus,
    required: bool,
    digest: string,
}

type RuleOutcome = "matched" | "not_matched" | "negative" | "skipped" | "uncertain" | "error";

class RuleEvaluation {
    rule_line: int,
    path: string?,
    outcome: RuleOutcome,
    detail: string?,
}

type ReportMode = "preview" | "hosted";

class ReportInputs {
    mode: ReportMode,
    repository: string?,
    pr_number: int?,
    base: string,
    head: string,
    merge_base: string,
    policy_digest: string,
    evaluator_version: string,
}

class Report {
    schema_version: string,
    mode: ReportMode,
    evaluation_id: string?,
    inputs: ReportInputs,
    succeeded: bool,
    files: FileOutcome[],
    requirements: Requirement[],
    rule_evaluations: RuleEvaluation[],
    errors: Diagnostic[],
}

test "owner handles render" {
    assert.equal(string.from(UserOwner { handle: "alice" }), "@alice");
    assert.equal(string.from(TeamOwner { org: "example", team: "security" }), "@example/security")
}

class RegisterResponse {
    attempt_id: string,
    evaluation_id: string,
    upload_token: string,
    repository: string,
    pr_number: int,
    head_sha: string,
    base_sha: string,
    merge_base: string,
    pr_title: string?,
    pr_body: string?,
    pr_labels: string[]?,
    pr_author_id: string?,
}

class UploadResponse {
    evaluation_id: string,
    review_url: string?,
}

class CredentialsResponse {
    upload_token: string,
}

class Versions {
    function evaluator() -> string {
        "0.1.0"
    }

    function report_schema() -> string {
        "1"
    }
}
