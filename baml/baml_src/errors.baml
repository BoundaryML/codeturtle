// Typed error model, stdlib style (cf. baml.csv.Error): a thrown class
// classified by a closed enum, plus a prose message. Match on the enum,
// never on the message. Collectable validation problems are Diagnostic
// values, never throws. ErrorCode renders as its spec snake_case name
// via ToString/ToJson, so diagnostics serialize exactly as displayed.

enum ErrorCode {
    PolicyMissing,
    InvalidPolicyBlock,
    InvalidPolicy,
    UnknownDirective,
    UnknownFunction,
    InvalidContract,
    CompilationFailed,
    ConditionFailed,
    ConditionTimeout,
    InvalidConditionResult,
    MissingContext,
    ModelConfigurationMissing,
    ModelUnavailable,
    InputLimitExceeded,
    UnsupportedPathEncoding,
    AmbiguousMergeBase,
    InvalidRevision,
    RepositoryUnavailable,
    InputUnavailable,
    ConflictingInputs,
    UnsupportedExecutionContext,
    InvalidBackendUrl,
    UsageError,
    ArtifactWriteFailed,
    ReportLimitExceeded,
    RepositoryNotEnrolled,
    UntrustedWorkflow,
    IdentityRejected,
    BackendUnavailable,
    ReportConflict,
    ReportRejected,
    StaleEvaluation,
    PullRequestClosed,
    Interrupted,
}

class CliError {
    code: ErrorCode,
    message: string,

    function new(code: ErrorCode, message: string) -> CliError {
        CliError { code: code, message: message }
    }
}

class Diagnostic {
    code: ErrorCode,
    message: string,
    source: string?,
    line: int?,

    function new(code: ErrorCode, message: string, source: string?, line: int?) -> Diagnostic {
        Diagnostic { code: code, message: message, source: source, line: line }
    }

    function format_all(diagnostics: Diagnostic[]) -> string {
        diagnostics
            .map((d: Diagnostic) -> string {
                d.render()
            })
            .join("\n")
    }

    function location(self) -> string {
        match (self.source) {
            null => "",
            let source: string => match (self.line) {
                null => source,
                let line: int => `${source}:${line}`,
            },
        }
    }

    function render(self) -> string {
        let head = match (root.lib.text.Text.non_empty(self.location())) {
            null => `[${self.code}]`,
            let loc: string => `${loc} [${self.code}]`,
        };
        `${head}\n  ${self.message}`
    }
}

// Spec wire names. Exhaustive like exit_code below.
implement baml.ToString for ErrorCode {
    function to_string(self) -> string {
        match (self) {
        ErrorCode.PolicyMissing => "policy_missing",
        ErrorCode.InvalidPolicyBlock => "invalid_policy_block",
        ErrorCode.InvalidPolicy => "invalid_policy",
        ErrorCode.UnknownDirective => "unknown_directive",
        ErrorCode.UnknownFunction => "unknown_function",
        ErrorCode.InvalidContract => "invalid_contract",
        ErrorCode.CompilationFailed => "compilation_failed",
        ErrorCode.ConditionFailed => "condition_failed",
        ErrorCode.ConditionTimeout => "condition_timeout",
        ErrorCode.InvalidConditionResult => "invalid_condition_result",
        ErrorCode.MissingContext => "missing_context",
        ErrorCode.ModelConfigurationMissing => "model_configuration_missing",
        ErrorCode.ModelUnavailable => "model_unavailable",
        ErrorCode.InputLimitExceeded => "input_limit_exceeded",
        ErrorCode.UnsupportedPathEncoding => "unsupported_path_encoding",
        ErrorCode.AmbiguousMergeBase => "ambiguous_merge_base",
        ErrorCode.InvalidRevision => "invalid_revision",
        ErrorCode.RepositoryUnavailable => "repository_unavailable",
        ErrorCode.InputUnavailable => "input_unavailable",
        ErrorCode.ConflictingInputs => "conflicting_inputs",
        ErrorCode.UnsupportedExecutionContext => "unsupported_execution_context",
        ErrorCode.InvalidBackendUrl => "invalid_backend_url",
        ErrorCode.UsageError => "usage_error",
        ErrorCode.ArtifactWriteFailed => "artifact_write_failed",
        ErrorCode.ReportLimitExceeded => "report_limit_exceeded",
        ErrorCode.RepositoryNotEnrolled => "repository_not_enrolled",
        ErrorCode.UntrustedWorkflow => "untrusted_workflow",
        ErrorCode.IdentityRejected => "identity_rejected",
        ErrorCode.BackendUnavailable => "backend_unavailable",
        ErrorCode.ReportConflict => "report_conflict",
        ErrorCode.ReportRejected => "report_rejected",
        ErrorCode.StaleEvaluation => "stale_evaluation",
        ErrorCode.PullRequestClosed => "pull_request_closed",
            ErrorCode.Interrupted => "interrupted",
        }
    }
}

implement baml.ToJson for ErrorCode {
    function to_json(self) -> json {
        self.to_string()
    }
}

// Enums cannot declare methods, so the exit code mapping is an
// interface implementation.
interface ExitStatus {
    function exit_code(self) -> int throws never;
}

// Exit codes per CLI spec. Exhaustive: a new variant will not compile
// until it is assigned a wire name and an exit class.
implement ExitStatus for ErrorCode {
    function exit_code(self) -> int {
    match (self) {
        ErrorCode.PolicyMissing => 1,
        ErrorCode.InvalidPolicyBlock => 1,
        ErrorCode.InvalidPolicy => 1,
        ErrorCode.UnknownDirective => 1,
        ErrorCode.UnknownFunction => 1,
        ErrorCode.InvalidContract => 1,
        ErrorCode.CompilationFailed => 1,
        ErrorCode.ConditionFailed => 1,
        ErrorCode.ConditionTimeout => 1,
        ErrorCode.InvalidConditionResult => 1,
        ErrorCode.MissingContext => 1,
        ErrorCode.ModelConfigurationMissing => 1,
        ErrorCode.ModelUnavailable => 1,
        ErrorCode.InputLimitExceeded => 1,
        ErrorCode.UnsupportedPathEncoding => 1,
        ErrorCode.AmbiguousMergeBase => 1,
        ErrorCode.ReportLimitExceeded => 1,
        ErrorCode.InvalidRevision => 2,
        ErrorCode.RepositoryUnavailable => 2,
        ErrorCode.InputUnavailable => 2,
        ErrorCode.ConflictingInputs => 2,
        ErrorCode.UnsupportedExecutionContext => 2,
        ErrorCode.InvalidBackendUrl => 2,
        ErrorCode.UsageError => 2,
        ErrorCode.ArtifactWriteFailed => 2,
        ErrorCode.RepositoryNotEnrolled => 3,
        ErrorCode.UntrustedWorkflow => 3,
        ErrorCode.IdentityRejected => 3,
        ErrorCode.BackendUnavailable => 3,
        ErrorCode.ReportConflict => 3,
        ErrorCode.ReportRejected => 3,
        ErrorCode.StaleEvaluation => 4,
        ErrorCode.PullRequestClosed => 4,
        ErrorCode.Interrupted => 130,
    }
    }
}

test "exit codes cover spec classes" {
    let exit = (code: ErrorCode) -> int {
        code.exit_code()
    };
    assert.equal(exit(ErrorCode.UnknownFunction), 1);
    assert.equal(exit(ErrorCode.UsageError), 2);
    assert.equal(exit(ErrorCode.BackendUnavailable), 3);
    assert.equal(exit(ErrorCode.StaleEvaluation), 4);
    assert.equal(exit(ErrorCode.Interrupted), 130);
    assert.equal(string.from(ErrorCode.InvalidPolicy), "invalid_policy");
    assert.equal(`${ErrorCode.StaleEvaluation}`, "stale_evaluation")
}

test "diagnostics serialize with wire code names" {
    let d = Diagnostic.new(ErrorCode.UnknownDirective, "nope", "CODETURTLE.md", 9);
    assert.is_true(baml.json.to_string(d).includes("\"unknown_directive\""))
}
