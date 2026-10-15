// Rule evaluation: match -> invoke -> normalize. Per-rule failures are
// collected as diagnostics; valid partial requirements are retained.

class Evaluation {
    requirements: root.Requirement[],
    rule_evaluations: root.RuleEvaluation[],
    errors: root.Diagnostic[],
}

function requirement_for(rule: root.Rule, m: root.Match) -> root.Requirement {
    root.Requirement {
        path: m.path,
        rule_line: rule.line,
        condition: rule.condition,
        owners: rule.owner_handles(),
        threshold: rule.threshold,
        verdict: m.verdict,
        reason: m.reason,
        evidence: m.evidence,
    }
}

function apply_matches(
    resolved: ResolvedRule,
    matches: root.Match[],
    scope: root.FileChange[],
    requirements: root.Requirement[],
    traces: root.RuleEvaluation[],
) -> null {
    for (let m in matches) {
        traces.push(
            match (m.verdict) {
                "applies" => {
                    requirements.push(requirement_for(resolved.rule, m));
                    root.RuleEvaluation {
                        rule_line: resolved.rule.line,
                        path: m.path,
                        outcome: "matched",
                        detail: m.reason,
                    }
                },
                "uncertain" => {
                    requirements.push(requirement_for(resolved.rule, m));
                    root.RuleEvaluation {
                        rule_line: resolved.rule.line,
                        path: m.path,
                        outcome: "uncertain",
                        detail: m.reason,
                    }
                },
                "does_not_apply" => {
                    root.RuleEvaluation {
                        rule_line: resolved.rule.line,
                        path: m.path,
                        outcome: "negative",
                        detail: m.reason,
                    }
                },
            },
        );
    }
    for (let change in scope) {
        let covered = matches.some((m: root.Match) -> bool {
            m.path == change.path || m.path == change.old_path
        });
        if (!covered) {
            traces.push(
                root.RuleEvaluation {
                    rule_line: resolved.rule.line,
                    path: change.path,
                    outcome: "negative",
                    detail: null,
                },
            );
        }
    }
    null
}

function evaluate_rule(
    resolved: ResolvedRule,
    changes: root.FileChange[],
    pr: root.PullRequest?,
    requirements: root.Requirement[],
    traces: root.RuleEvaluation[],
    errors: root.Diagnostic[],
) -> null {
    let scope = dedupe_scope(
        changes.filter((change: root.FileChange) -> bool {
            resolved.pattern.matches_change(change)
        }),
    );
    if (scope.length() == 0) {
        traces.push(
            root.RuleEvaluation {
                rule_line: resolved.rule.line,
                path: null,
                outcome: "skipped",
                detail: "no matching files",
            },
        );
        return null;
    }
    match (resolved.condition) {
        null => {
            for (let change in scope) {
                requirements.push(
                    requirement_for(
                        resolved.rule,
                        root.Match {
                            path: change.path,
                            verdict: "applies",
                            reason: `matches ${resolved.rule.pattern}`,
                            evidence: null,
                        },
                    ),
                );
                traces.push(
                    root.RuleEvaluation {
                        rule_line: resolved.rule.line,
                        path: change.path,
                        outcome: "matched",
                        detail: `matches ${resolved.rule.pattern}`,
                    },
                );
            }
        },
        FileCondition { check } => {
            for (let change in scope) {
                let matches = invoke_file_condition(check, change);
                validate_scope(matches, [change]);
                if (matches.length() == 0) {
                    traces.push(
                        root.RuleEvaluation {
                            rule_line: resolved.rule.line,
                            path: change.path,
                            outcome: "negative",
                            detail: null,
                        },
                    );
                } else {
                    apply_matches(resolved, matches, [change], requirements, traces);
                }
            }
        },
        FilesCondition { check } => {
            let matches = invoke_files_condition(check, scope);
            validate_scope(matches, scope);
            apply_matches(resolved, matches, scope, requirements, traces);
        },
        PrCondition { check } => {
            let matches = invoke_pr_condition(check, pr);
            validate_scope(matches, scope);
            apply_matches(resolved, matches, scope, requirements, traces);
        },
    }
    null
}

function evaluate(
    policy: root.Policy,
    changes: root.FileChange[],
    pr: root.PullRequest?,
) -> Evaluation throws root.CliError {
    let requirements: root.Requirement[] = [];
    let traces: root.RuleEvaluation[] = [];
    let errors: root.Diagnostic[] = [];
    for (let resolved in resolve_rules(policy)) {
        evaluate_rule(resolved, changes, pr, requirements, traces, errors) catch (e) {
            root.CliError => {
                errors.push(
                    root.Diagnostic.new(e.code, e.message, policy_source_name(), resolved.rule.line),
                );
                traces.push(
                    root.RuleEvaluation {
                        rule_line: resolved.rule.line,
                        path: null,
                        outcome: "error",
                        detail: e.message,
                    },
                );
            },
        };
    }
    requirements.sort_by((a: root.Requirement, b: root.Requirement) -> baml.ops.Ordering {
        match (a.rule_line.cmp(b.rule_line)) {
            baml.ops.Ordering.Equal => a.path.cmp(b.path),
            let other: baml.ops.Ordering => other,
        }
    });
    traces.sort_by((a: root.RuleEvaluation, b: root.RuleEvaluation) -> baml.ops.Ordering {
        match (a.rule_line.cmp(b.rule_line)) {
            baml.ops.Ordering.Equal => (a.path ?? "").cmp(b.path ?? ""),
            let other: baml.ops.Ordering => other,
        }
    });
    Evaluation { requirements: requirements, rule_evaluations: traces, errors: errors }
}

function build_report(
    inputs: root.ReportInputs,
    evaluation_id: string?,
    changes: root.FileChange[],
    evaluation: Evaluation,
) -> root.Report {
    let files = changes.map((change: root.FileChange) -> root.FileOutcome {
        root.FileOutcome {
            path: change.path,
            old_path: change.old_path,
            status: change.status,
            required: evaluation.requirements.some((r: root.Requirement) -> bool {
                r.path == change.path
            }),
            digest: change_digest(change),
        }
    });
    root.Report {
        schema_version: root.Versions.report_schema(),
        mode: inputs.mode,
        evaluation_id: evaluation_id,
        inputs: inputs,
        succeeded: evaluation.errors.length() == 0,
        files: files,
        requirements: evaluation.requirements,
        rule_evaluations: evaluation.rule_evaluations,
        errors: evaluation.errors,
    }
}

function serialize_report(report: root.Report) -> string throws root.CliError {
    let json_text = baml.json.stringify_pretty(baml.json.to_json(report)) catch (e) {
        baml.json.SerializationError => {
            throw root.CliError.new(root.ErrorCode.ReportLimitExceeded, `report cannot be serialized: ${e.message}`)
        },
    };
    if (json_text.byte_length() > root.lib.limits.Limits.max_report_bytes()) {
        throw root.CliError.new(root.ErrorCode.ReportLimitExceeded, "report exceeds the size limit");
    }
    json_text
}

function failure_report(
    inputs: root.ReportInputs,
    evaluation_id: string?,
    error: root.CliError,
) -> root.Report {
    root.Report {
        schema_version: root.Versions.report_schema(),
        mode: inputs.mode,
        evaluation_id: evaluation_id,
        inputs: inputs,
        succeeded: false,
        files: [],
        requirements: [],
        rule_evaluations: [],
        errors: [root.Diagnostic.new(error.code, error.message, null, null)],
    }
}

function save_report(path: string, json_text: string) -> null throws root.CliError {
    let tmp = `${path}.tmp-${baml.sys.pid()}`;
    baml.fs.write(tmp, json_text) catch (e) {
        baml.errors.Io => {
            throw root.CliError.new(root.ErrorCode.ArtifactWriteFailed, `cannot write report to ${path}: ${e.message}`)
        },
    };
    let moved = baml.sys.exec("mv", [tmp, path], null) catch (e) {
        baml.errors.Io => {
            throw root.CliError.new(root.ErrorCode.ArtifactWriteFailed, `cannot save report to ${path}: ${e.message}`)
        },
        baml.errors.Timeout => {
            throw root.CliError.new(root.ErrorCode.ArtifactWriteFailed, `cannot save report to ${path}: timed out`)
        },
    };
    if (!moved.ok()) {
        throw root.CliError.new(root.ErrorCode.ArtifactWriteFailed, `cannot save report to ${path}`);
    }
    null
}

function test_change(path: string, added: string) -> root.FileChange {
    root.FileChange {
        path: path,
        old_path: null,
        status: "modified",
        before_blob: null,
        after_blob: null,
        before_text: "",
        after_text: added,
        added_text: added,
        removed_text: "",
        patch: "",
        hunks: [],
        is_binary: false,
        content_available: true,
        is_submodule: false,
        is_symlink: false,
    }
}

test "overlapping rules accumulate independently" {
    let parsed = parse_policy(
        "```codeturtle\n/stdlib/ @alice @bob # codeturtle: all\n* @example/security # codeturtle: when=checks.adds_environment_access\n```\n",
    );
    let policy = match (parsed.policy) {
        null => throw root.CliError.new(root.ErrorCode.InvalidPolicy, "expected policy"),
        let p: root.Policy => p,
    };
    let changes = [
        test_change("stdlib/env.baml", "let x = 1;"),
        test_change("app/config.ts", "const token = process.env.TOKEN;"),
        test_change("docs/readme.md", "hello"),
    ];
    let result = evaluate(policy, changes, null);
    assert.equal(result.errors.length(), 0);
    assert.equal(result.requirements.length(), 2);
    assert.equal(result.requirements[0].threshold, "all");
    assert.equal(result.requirements[1].evidence, "const token = process.env.TOKEN;")
}

test "pr predicate without context is missing_context" {
    let parsed = parse_policy("```codeturtle\n* @alice # codeturtle: when=checks.title_mentions_breaking\n```\n");
    let policy = match (parsed.policy) {
        null => throw root.CliError.new(root.ErrorCode.InvalidPolicy, "expected policy"),
        let p: root.Policy => p,
    };
    let result = evaluate(policy, [test_change("a.ts", "x")], null);
    assert.equal(result.errors.length(), 1);
    assert.equal(result.errors[0].code, root.ErrorCode.MissingContext)
}
