// Human-readable terminal output. Readable text only; JSON lives in
// the optional report file.

class Render {
    function file_block(change: root.FileChange, requirements: root.Requirement[]) -> string {
        let mine = requirements.filter((r: root.Requirement) -> bool {
            r.path == change.path
        });
        let body = if (mine.length() == 0) {
            ["  No review required by policy"]
        } else {
            mine.flat_map((r: root.Requirement) -> string[] {
                let uncertain = if (r.verdict == "uncertain") {
                    " (uncertain)"
                } else {
                    ""
                };
                [
                    `  ${r.threshold_label()} ${r.owners.join(", ")}${uncertain}`,
                    `  ${root.engine.policy_source_name()}:${r.rule_line} - ${r.reason}`,
                ]
                    .concat(
                        match (r.evidence) {
                            null => [],
                            let evidence: string => [`  Evidence: ${evidence}`],
                        },
                    )
            })
        };
        [root.lib.paths.RepoPath { raw: change.path }.display()].concat(body).join("\n")
    }

    function files(report: root.Report, changes: root.FileChange[]) -> string {
        changes
            .map((change: root.FileChange) -> string {
                Render.file_block(change, report.requirements)
            })
            .join("\n\n")
    }

    function requirement_counts(report: root.Report) -> string {
        let plural = (count: int, singular: string, many: string) -> string {
            root.lib.text.Text.plural(count, singular, many)
        };
        let total_files = report.files.length();
        let required_files = report.files
            .filter((f: root.FileOutcome) -> bool {
                f.required
            })
            .length();
        let free_files = total_files - required_files;
        let requirements = report.requirements.length();
        match (requirements) {
            0 => {
                `0 review requirements across ${total_files} changed ${plural(total_files, "file", "files")}.`
            },
            _ => {
                `${requirements} ${plural(requirements, "requirement", "requirements")} across ${required_files} ${plural(required_files, "file", "files")}; ${free_files} ${plural(free_files, "file requires", "files require")} no review.`
            },
        }
    }

    function preview(
        report: root.Report,
        changes: root.FileChange[],
        base: root.engine.Revision,
        merge_base: root.engine.Revision,
        head: root.engine.Revision,
        notices: string[],
    ) -> string {
        [
            "CodeTurtle: local preview succeeded",
            `Base: ${base.short()}   Head: ${head.short()}   Merge-base: ${merge_base.short()}`,
            `Policy: ${root.engine.policy_source_name()} at ${base.short()}`,
            "",
            Render.files(report, changes),
            "",
            Render.requirement_counts(report),
            "No upload. GitHub review status is unchanged.",
        ]
            .concat(notices)
            .join("\n")
    }

    function hosted(
        report: root.Report,
        changes: root.FileChange[],
        receipt: string,
        review_url: string?,
    ) -> string {
        let inputs = report.inputs;
        let pull_request = match (inputs.repository) {
            null => null,
            let repo: string => match (inputs.pr_number) {
                null => `PR: ${repo}`,
                let n: int => `PR: ${repo}#${n}`,
            },
        };
        let header = root.lib.text.Text.join_present(
            [
                pull_request,
                `Head: ${root.lib.text.Text.short_rev(inputs.head)}`,
                `Policy: ${root.lib.text.Text.short_rev(inputs.policy_digest)}`,
            ],
            "   ",
        );
        let outcome = if (report.requirements.length() == 0) {
            [
                "No human review required by evaluated policy.",
                "Backend determines and publishes the collective result.",
            ]
        } else {
            ["Human review remains pending."]
        };
        let review = match (review_url) {
            null => [],
            let url: string => [`Review: ${url}`],
        };
        [
            "CodeTurtle: evaluation succeeded",
            header,
            "",
            Render.files(report, changes),
            "",
            Render.requirement_counts(report),
            `Report accepted: ${receipt}`,
        ]
            .concat(outcome)
            .concat(review)
            .join("\n")
    }

    function evaluation_failed(
        report: root.Report,
        changes: root.FileChange[],
        receipt: string?,
    ) -> string {
        let requirements = report.requirements.length();
        root.lib.text.Text.join_present(
            [
                "CodeTurtle: evaluation failed",
                if (changes.length() > 0) {
                    Render.files(report, changes)
                } else {
                    null
                },
                root.Diagnostic.format_all(report.errors),
                `${requirements} valid ${root.lib.text.Text.plural(requirements, "requirement", "requirements")} retained for diagnostics; evaluation incomplete.`,
                match (receipt) {
                    null => null,
                    let id: string => `Failure report accepted: ${id}`,
                },
                "Retry evaluation after fixing the error. Human approval cannot clear it.",
            ],
            "\n",
        )
    }

    function policy_invalid(diagnostics: root.Diagnostic[]) -> string {
        `CodeTurtle: policy invalid\n${root.Diagnostic.format_all(diagnostics)}\n${diagnostics.length()} ${root.lib.text.Text.plural(diagnostics.length(), "error", "errors")}. No predicates executed.`
    }

    function policy_missing() -> string {
        `CodeTurtle: policy invalid\n${root.engine.policy_source_name()} [policy_missing]\n  policy file not found in the working tree.`
    }

    function policy_valid(policy: root.Policy) -> string {
        let rules = policy.rules.length();
        `CodeTurtle: policy valid (${rules} ${root.lib.text.Text.plural(rules, "rule", "rules")})`
    }

    function superseded(error: root.CliError) -> string {
        `CodeTurtle: attempt superseded [${error.code}]\n${error.message}\nNo current requirements replaced. Fresh Actions evaluation required.`
    }

    function reporting_failed(error: root.CliError) -> string {
        `CodeTurtle: reporting failed [${error.code}]\nEvaluation computed; acceptance could not be confirmed after bounded retries.\nThe review gate must not be considered successful.`
    }
}
