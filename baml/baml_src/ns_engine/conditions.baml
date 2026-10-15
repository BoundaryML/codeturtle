// Condition contracts and registry.
//
// Policy text names conditions dynamically (`when=checks.foo`): the full
// spec resolves those names against user-authored BAML functions in the
// trusted base snapshot's .codeturtle/functions package, validated by
// signature. This build ships the compiled-in registry behind the same
// contracts, so the master list is the `Check` enum below. The string
// name exists only at the parse boundary; `resolve_check` converts it
// once, and everything downstream matches exhaustively on `Check`.

enum FileCheck {
    AddsEnvironmentAccess,
    UndocumentedApiChange,
}

enum FilesCheck {
    TouchesBinaryFiles,
}

enum PrCheck {
    TitleMentionsBreaking,
}

class FileCondition {
    check: FileCheck,
}

class FilesCondition {
    check: FilesCheck,
}

class PrCondition {
    check: PrCheck,
}

type Condition = FileCondition | FilesCondition | PrCondition;

class ResolvedRule {
    rule: root.Rule,
    condition: Condition?,
    pattern: root.lib.paths.PathPattern,
}

function resolve_check(name: string) -> Condition? {
    match (name) {
        "checks.adds_environment_access" => FileCondition { check: FileCheck.AddsEnvironmentAccess },
        "checks.undocumented_api_change" => FileCondition { check: FileCheck.UndocumentedApiChange },
        "checks.touches_binary_files" => FilesCondition { check: FilesCheck.TouchesBinaryFiles },
        "checks.title_mentions_breaking" => PrCondition { check: PrCheck.TitleMentionsBreaking },
        _ => null,
    }
}

function check_name(condition: Condition) -> string {
    match (condition) {
        FileCondition { check } => match (check) {
            FileCheck.AddsEnvironmentAccess => "checks.adds_environment_access",
            FileCheck.UndocumentedApiChange => "checks.undocumented_api_change",
        },
        FilesCondition { check } => match (check) {
            FilesCheck.TouchesBinaryFiles => "checks.touches_binary_files",
        },
        PrCondition { check } => match (check) {
            PrCheck.TitleMentionsBreaking => "checks.title_mentions_breaking",
        },
    }
}

function validate_conditions(policy: root.Policy) -> root.Diagnostic[] {
    let diagnostics: root.Diagnostic[] = [];
    for (let rule in policy.rules) {
        match (rule.condition) {
            null => null,
            let name: string => match (resolve_check(name)) {
                null => {
                    diagnostics.push(
                        root.Diagnostic.new(
                            root.ErrorCode.UnknownFunction,
                            `${name} could not be resolved.`,
                            policy_source_name(),
                            rule.line,
                        ),
                    )
                },
                _ => null,
            },
        };
    }
    diagnostics
}

// Pre: validate_conditions reported no diagnostics.
function resolve_rules(policy: root.Policy) -> ResolvedRule[] throws root.CliError {
    policy.rules.map((rule: root.Rule) -> ResolvedRule {
        let condition = match (rule.condition) {
            null => null,
            let name: string => match (resolve_check(name)) {
                null => {
                    throw root.CliError.new(root.ErrorCode.UnknownFunction, `${name} could not be resolved.`)
                },
                let resolved: Condition => resolved,
            },
        };
        ResolvedRule {
            rule: rule,
            condition: condition,
            pattern: root.lib.paths.PathPattern.compile(rule.pattern),
        }
    })
}

// Example predicates from the CLI spec.

function adds_environment_access(change: root.FileChange) -> bool {
    change.added_text.includes("process.env.")
}

function undocumented_api_change(change: root.FileChange) -> root.Match {
    match (root.lib.text.Text.first_line_containing(change.added_text, "export ")) {
        null => {
            root.Match {
                path: change.path,
                verdict: "does_not_apply",
                reason: "no new exported symbol",
                evidence: null,
            }
        },
        let line: string => {
            root.Match {
                path: change.path,
                verdict: "uncertain",
                reason: "new exported symbol may need documentation",
                evidence: line,
            }
        },
    }
}

function touches_binary_files(files: root.FileChange[]) -> root.Match[] {
    files.filter_map((change: root.FileChange) -> root.Match? {
        if (change.is_binary) {
            root.Match {
                path: change.path,
                verdict: "applies",
                reason: "binary file changed",
                evidence: null,
            }
        } else {
            null
        }
    })
}

function title_mentions_breaking(pr: root.PullRequest) -> root.Match[] {
    if (pr.title.to_lower_case().includes("breaking")) {
        pr.changes.map((change: root.FileChange) -> root.Match {
            root.Match {
                path: change.path,
                verdict: "applies",
                reason: "PR title declares a breaking change",
                evidence: pr.title,
            }
        })
    } else {
        []
    }
}

// Invocation. Wrong-context invocation is unrepresentable: each function
// only accepts checks declared for its context. Bool true becomes an
// `applies` match.

function invoke_file_condition(check: FileCheck, change: root.FileChange) -> root.Match[] {
    match (check) {
        FileCheck.AddsEnvironmentAccess => {
            if (adds_environment_access(change)) {
                [
                    root.Match {
                        path: change.path,
                        verdict: "applies",
                        reason: "introduces environment access",
                        evidence: root.lib.text.Text.first_line_containing(change.added_text, "process.env."),
                    },
                ]
            } else {
                []
            }
        },
        FileCheck.UndocumentedApiChange => [undocumented_api_change(change)],
    }
}

function invoke_files_condition(check: FilesCheck, files: root.FileChange[]) -> root.Match[] {
    match (check) {
        FilesCheck.TouchesBinaryFiles => touches_binary_files(files),
    }
}

function invoke_pr_condition(
    check: PrCheck,
    pr: root.PullRequest?,
) -> root.Match[] throws root.CliError {
    match (pr) {
        null => {
            throw root.CliError.new(root.ErrorCode.MissingContext, `${check_name(PrCondition { check: check })} requires pull request context`)
        },
        let ctx: root.PullRequest => match (check) {
            PrCheck.TitleMentionsBreaking => title_mentions_breaking(ctx),
        },
    }
}

// Detailed results may select a subset of scope, never escape it, and
// never select the same file twice.

function validate_scope(
    matches: root.Match[],
    scope: root.FileChange[],
) -> null throws root.CliError {
    let seen: string[] = [];
    for (let m in matches) {
        if (seen.includes(m.path)) {
            throw root.CliError.new(root.ErrorCode.InvalidConditionResult, `duplicate match for ${m.path}`);
        }
        seen.push(m.path);
        let allowed = scope.some((change: root.FileChange) -> bool {
            change.path == m.path || change.old_path == m.path
        });
        if (!allowed) {
            throw root.CliError.new(root.ErrorCode.InvalidConditionResult, `match path ${m.path} is outside the rule scope`);
        }
    }
    null
}

function dedupe_scope(files: root.FileChange[]) -> root.FileChange[] {
    let out: root.FileChange[] = [];
    for (let change in files) {
        if (
            !out.some((c: root.FileChange) -> bool {
                c.path == change.path
            })
        ) {
            out.push(change);
        }
    }
    out
}

test "check names round trip" {
    let resolved = resolve_check("checks.adds_environment_access");
    match (resolved) {
        FileCondition { check } => assert.equal(check, FileCheck.AddsEnvironmentAccess),
        _ => throw root.CliError.new(root.ErrorCode.UnknownFunction, "wrong condition kind"),
    }
    assert.equal(
        check_name(PrCondition { check: PrCheck.TitleMentionsBreaking }),
        "checks.title_mentions_breaking",
    );
    assert.equal(resolve_check("checks.nope"), null)
}
