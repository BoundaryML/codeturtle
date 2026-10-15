// CLI dispatch: check / lint / help / version, exactly per spec.
// Every failure is a typed CliError; `Cli.run` returns an exit code.

class Cli {
    function spec() -> root.lib.clap.Command {
        root.lib.clap.Command.new("codeturtle")
            .about("Who must review which changed files, and why.")
            .version(root.Versions.evaluator())
            .help_text(Help.text())
            .subcommand_required()
            .subcommand(
                root.lib.clap.Command.new("check")
                    .about("Compute required reviewers for changed files")
                    .arg(
                        root.lib.clap.Arg.opt("backend")
                            .with_value_name("URL")
                            .help("Authenticate through Actions OIDC and upload")
                            .conflicts_with("base"),
                    )
                    .arg(
                        root.lib.clap.Arg.opt("base").with_value_name("REF").help(
                            "Comparison base for a local preview",
                        ),
                    )
                    .arg(
                        root.lib.clap.Arg.opt("report-out").with_value_name("PATH").help(
                            "Save the exact JSON report",
                        ),
                    ),
            )
            .subcommand(
                root.lib.clap.Command.new("lint").about("Validate policy and condition contracts"),
            )
            .subcommand(root.lib.clap.Command.new("version").about("Print the version"))
    }

    function run(argv: string[]) -> int throws root.CliError {
        let spec = Cli.spec();
        let matches = spec.parse_from(argv) catch (e) {
            root.lib.clap.ParseError => {
                let code = match (e) {
                    root.lib.clap.ConflictError => root.ErrorCode.ConflictingInputs,
                    _ => root.ErrorCode.UsageError,
                };
                throw root.CliError.new(code, `${e.message()}. Run codeturtle help.`)
            },
            root.lib.clap.DisplayHelp => {
                baml.io.println(e.text);
                return 0;
            },
            root.lib.clap.DisplayVersion => {
                baml.io.println(e.text);
                return 0;
            },
        };
        let sub = matches.sub() ?? root.lib.clap.Matches.empty();
        match (matches.subcommand()) {
            "check" => CheckOptions.from_matches(sub).run(),
            "lint" => Cli.lint(),
            "version" => {
                baml.io.println(spec.version_line());
                0
            },
            _ => {
                throw root.CliError.new(root.ErrorCode.UsageError, "no command given. Run codeturtle help.")
            },
        }
    }

    function lint() -> int {
        let markdown = baml.fs.read(root.engine.policy_source_name()) catch (e) {
            baml.errors.Io => null,
            baml.errors.ParseError => null,
        };
        match (markdown) {
            null => {
                baml.io.println(Render.policy_missing());
                1
            },
            let text: string => match (Cli.validated_policy(text)) {
                null => 1,
                let policy: root.Policy => {
                    baml.io.println(Render.policy_valid(policy));
                    0
                },
            },
        }
    }

    // The parsed policy if it is valid; otherwise prints why it is not
    // and returns null.
    function validated_policy(markdown: string) -> root.Policy? {
        let parsed = root.engine.parse_policy(markdown);
        let diagnostics = match (parsed.policy) {
            null => parsed.diagnostics,
            let policy: root.Policy => root.engine.validate_conditions(policy),
        };
        if (parsed.policy == null || diagnostics.length() > 0) {
            baml.io.println(Render.policy_invalid(diagnostics));
            return null;
        }
        parsed.policy
    }
}

class CheckOptions {
    backend: root.lib.url.Url?,
    base: string?,
    report_out: string?,

    function from_matches(matches: root.lib.clap.Matches) -> CheckOptions throws root.CliError {
        let backend = match (matches.get("backend")) {
            null => null,
            let url: string => root.lib.url.parse_backend_url(url),
        };
        CheckOptions {
            backend: backend,
            base: matches.get("base"),
            report_out: matches.get("report-out"),
        }
    }

    function run(self) -> int throws root.CliError {
        match (self.backend) {
            null => LocalCheck.new(self).run(),
            let backend: root.lib.url.Url => HostedCheck.start(backend, self).run(),
        }
    }
}

class LocalCheck {
    options: CheckOptions,
    git: root.engine.Git,

    function new(options: CheckOptions) -> LocalCheck throws root.CliError {
        let git = root.engine.Git.here();
        git.require_repository();
        LocalCheck { options: options, git: git }
    }

    function run(self) -> int throws root.CliError {
        let head = self.git.head();
        let base = self._base(head);
        let merge_base = self.git.merge_base(base, head);
        let policy = match (Cli.validated_policy(self.git.read_policy_at(base))) {
            null => {
                return 1;
            },
            let p: root.Policy => p,
        };
        let changes = self.git.inventory(merge_base, head);
        let inputs = root.ReportInputs {
            mode: "preview",
            repository: null,
            pr_number: null,
            base: base.sha,
            head: head.sha,
            merge_base: merge_base.sha,
            policy_digest: policy.digest,
            evaluator_version: root.Versions.evaluator(),
        };
        let report = root.engine.build_report(inputs, null, changes, root.engine.evaluate(policy, changes, null));
        match (self.options.report_out) {
            null => null,
            let path: string => root.engine.save_report(path, root.engine.serialize_report(report)),
        };
        if (!report.succeeded) {
            baml.io.println(Render.evaluation_failed(report, changes, null));
            return 1;
        }
        let notices = [
            if (self.git.is_dirty()) {
                "Notice: dirty worktree changes are excluded; only committed refs were evaluated."
            } else {
                null
            },
            match (self.options.report_out) {
                null => null,
                let path: string => `Report saved: ${path}`,
            },
        ]
            .filter_map((notice: string?) -> string? {
                notice
            });
        baml.io.println(Render.preview(report, changes, base, merge_base, head, notices));
        0
    }

    // --base REF, or the repository's default base when unambiguous.
    function _base(self, head: root.engine.Revision) -> root.engine.Revision throws root.CliError {
        let invalid = root.ErrorCode.InvalidRevision;
        let base_ref = match (self.options.base ?? self.git.default_base_ref()) {
            null => {
                throw root.CliError.new(invalid, "cannot infer a base unambiguously; pass --base REF")
            },
            let r: string => r,
        };
        let base = self.git.resolve_commit(base_ref);
        if (base.sha == head.sha) {
            throw root.CliError.new(invalid, "base resolves to HEAD itself; pass --base REF");
        }
        base
    }
}

class HostedEvaluation {
    policy: root.Policy,
    changes: root.FileChange[],
    evaluation: root.engine.Evaluation,
}

class HostedCheck {
    backend: BackendClient,
    options: CheckOptions,
    registration: root.RegisterResponse,
    git: root.engine.Git,

    function start(
        backend: root.lib.url.Url,
        options: CheckOptions,
    ) -> HostedCheck throws root.CliError {
        let ctx = ActionsContext.from_env();
        let connection = BackendClient.connect(backend);
        let registration = connection.register(ctx);
        let git = root.engine.Git.here();
        git.require_repository();
        HostedCheck { backend: connection, options: options, registration: registration, git: git }
    }

    // A failure while evaluating is still reported to the backend
    // (best effort) before it propagates.
    function run(self) -> int throws root.CliError {
        let head = self._resolve(self.registration.head_sha);
        let base = self._resolve(self.registration.base_sha);
        let merge_base = self._resolve(self.registration.merge_base);
        let hosted = self._evaluate(base, merge_base, head) catch (e) {
            root.CliError => {
                self._upload_failure(e);
                throw e;
            },
        };
        match (hosted) {
            null => 1,
            let h: HostedEvaluation => self._deliver(h),
        }
    }

    function _inputs(self, policy_digest: string) -> root.ReportInputs {
        root.ReportInputs {
            mode: "hosted",
            repository: self.registration.repository,
            pr_number: self.registration.pr_number,
            base: self.registration.base_sha,
            head: self.registration.head_sha,
            merge_base: self.registration.merge_base,
            policy_digest: policy_digest,
            evaluator_version: root.Versions.evaluator(),
        }
    }

    // A backend-issued commit, fetched first if it is not local yet.
    function _resolve(self, sha: string) -> root.engine.Revision throws root.CliError {
        match (self.git.try_resolve_commit(sha)) {
            null => {
                self.git.fetch_commit(sha);
                self.git.resolve_commit(sha)
            },
            let rev: root.engine.Revision => rev,
        }
    }

    function _pull_request(self, changes: root.FileChange[]) -> root.PullRequest? {
        let registration = self.registration;
        match (registration.pr_title) {
            null => null,
            let title: string => {
                root.PullRequest {
                    repository: registration.repository,
                    number: registration.pr_number,
                    title: title,
                    body: registration.pr_body ?? "",
                    labels: registration.pr_labels ?? [],
                    author_id: registration.pr_author_id ?? "",
                    head: registration.head_sha,
                    base: registration.base_sha,
                    merge_base: registration.merge_base,
                    changes: changes,
                }
            },
        }
    }

    function _evaluate(
        self,
        base: root.engine.Revision,
        merge_base: root.engine.Revision,
        head: root.engine.Revision,
    ) -> HostedEvaluation? throws root.CliError {
        match (Cli.validated_policy(self.git.read_policy_at(base))) {
            null => null,
            let policy: root.Policy => {
                let changes = self.git.inventory(merge_base, head);
                HostedEvaluation {
                    policy: policy,
                    changes: changes,
                    evaluation: root.engine.evaluate(policy, changes, self._pull_request(changes)),
                }
            },
        }
    }

    function _upload_failure(self, error: root.CliError) -> null {
        let report = root.engine.failure_report(self._inputs(""), self.registration.evaluation_id, error);
        let json_text = root.engine.serialize_report(report) catch (e) {
            root.CliError => null,
        };
        match (json_text) {
            null => null,
            let text: string => {
                self.backend.upload(self.registration, text) catch (e) {
                    root.CliError => null,
                };
                null
            },
        }
    }

    function _deliver(self, hosted: HostedEvaluation) -> int throws root.CliError {
        let report = root.engine.build_report(
            self._inputs(hosted.policy.digest),
            self.registration.evaluation_id,
            hosted.changes,
            hosted.evaluation,
        );
        let json_text = root.engine.serialize_report(report);
        match (self.options.report_out) {
            null => null,
            let path: string => root.engine.save_report(path, json_text),
        };
        let uploaded = self.backend.upload(self.registration, json_text) catch (e) {
            root.CliError => {
                match (e.code) {
                    root.ErrorCode.StaleEvaluation => {
                        baml.io.println(Render.superseded(e));
                        return 4;
                    },
                    root.ErrorCode.PullRequestClosed => {
                        baml.io.println(Render.superseded(e));
                        return 4;
                    },
                    _ => {
                        baml.io.println(Render.reporting_failed(e));
                        throw e;
                    },
                }
            },
        };
        if (!report.succeeded) {
            baml.io.println(
                Render.evaluation_failed(report, hosted.changes, uploaded.evaluation_id),
            );
            return 1;
        }
        baml.io.println(
            Render.hosted(report, hosted.changes, uploaded.evaluation_id, uploaded.review_url),
        );
        0
    }
}

test "cli option parsing and conflicts" {
    let conflict = Cli.spec().parse(["check", "--backend", "https://reviews.example.com", "--base", "main"]) catch (e) {
        root.lib.clap.ConflictError => `${e.argument}/${e.other}`,
    };
    assert.equal(conflict, "backend/base");
    let unknown = Cli.spec().parse(["check", "--verbose"]) catch (e) {
        root.lib.clap.UnknownArgumentError => e.argument,
    };
    assert.equal(unknown, "--verbose");
    let parsed = Cli.spec().parse(["check", "--base", "main", "--report-out=r.json"]);
    let options = CheckOptions.from_matches(parsed.sub() ?? root.lib.clap.Matches.empty());
    assert.equal(options.base, "main");
    assert.equal(options.report_out, "r.json");
    assert.equal(options.backend, null)
}
