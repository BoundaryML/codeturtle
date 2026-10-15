// A clap-style command-line parser in pure BAML, local to this
// project. Depends only on the standard library (never on app code),
// so it could be lifted into a shared library unchanged.
//
// Declare commands and arguments with the builder functions, then
// parse argv (without the program name) into typed Matches:
//
//   let spec = Command.new("tool").about("Does things").subcommand(
//       Command.new("check").arg(Arg.opt("backend").with_value_name("URL")),
//   );
//   let matches = spec.parse(args);    // throws ParseError
//   matches.subcommand()               // "check"
//   matches.sub().get("backend")       // string?
//
// Every command gets built-in -h/--help and (when it has a version)
// --version args, as in clap. Matching one throws DisplayHelp or
// DisplayVersion carrying rendered text; the application prints and
// chooses the exit code. Disable them per command (`auto_help(false)`)
// or replace them by declaring an arg with the same name or with the
// Help/Version action. A `help` subcommand is synthesized when
// subcommands exist.

enum ArgAction {
    Flag,
    Value,
    Positional,
    Help,
    Version,
}

class Arg {
    name: string,
    action: ArgAction,
    short: string?,
    value_name: string?,
    help_text: string,
    is_required: bool,
    is_multiple: bool,
    default_value: string?,
    choices: string[],
    conflicts: string[],
    requires_args: string[],
    allow_hyphen: bool,

    function _empty(name: string, action: ArgAction) -> Arg {
        Arg {
            name: name,
            action: action,
            short: null,
            value_name: null,
            help_text: "",
            is_required: false,
            is_multiple: false,
            default_value: null,
            choices: [],
            conflicts: [],
            requires_args: [],
            allow_hyphen: false,
        }
    }

    function flag(name: string) -> Arg {
        Arg._empty(name, ArgAction.Flag)
    }

    function opt(name: string) -> Arg {
        Arg._empty(name, ArgAction.Value)
    }

    function pos(name: string) -> Arg {
        Arg._empty(name, ArgAction.Positional)
    }

    function with_action(self, action: ArgAction) -> Arg {
        self.action = action;
        self
    }

    function with_short(self, short: string) -> Arg {
        self.short = short;
        self
    }

    function help(self, text: string) -> Arg {
        self.help_text = text;
        self
    }

    function with_value_name(self, value_name: string) -> Arg {
        self.value_name = value_name;
        self
    }

    function required(self) -> Arg {
        self.is_required = true;
        self
    }

    function multiple(self) -> Arg {
        self.is_multiple = true;
        self
    }

    function default(self, value: string) -> Arg {
        self.default_value = value;
        self
    }

    function value_parser(self, choices: string[]) -> Arg {
        self.choices = choices;
        self
    }

    function conflicts_with(self, other: string) -> Arg {
        self.conflicts.push(other);
        self
    }

    function requires_arg(self, other: string) -> Arg {
        self.requires_args.push(other);
        self
    }

    function allow_hyphen_values(self) -> Arg {
        self.allow_hyphen = true;
        self
    }

    function is_option(self) -> bool {
        self.action != ArgAction.Positional
    }

    function _check_value(self, value: string, command: string) -> null throws InvalidValueError {
        if (self.choices.length() > 0 && !self.choices.includes(value)) {
            throw InvalidValueError.not_possible(self, value, command);
        }
        null
    }

    function _annotation(self) -> string {
        root.lib.text.Text.join_present(
            [
                root.lib.text.Text.non_empty(self.help_text),
                match (root.lib.text.Text.non_empty(self.choices.join(", "))) {
                    null => null,
                    let choices: string => `[possible values: ${choices}]`,
                },
                match (self.default_value) {
                    null => null,
                    let d: string => `[default: ${d}]`,
                },
            ],
            " ",
        )
    }

    function _usage(self) -> string {
        let rendered = if (self.is_multiple) {
            `${self.display_name()}...`
        } else {
            self.display_name()
        };
        if (self.is_required) {
            rendered
        } else {
            `[${rendered}]`
        }
    }

    function display_name(self) -> string {
        let value = `<${self.value_name ?? self.name.to_upper_case()}>`;
        let short = match (self.short) {
            null => "",
            let s: string => `-${s}, `,
        };
        match (self.action) {
            ArgAction.Positional => value,
            ArgAction.Value => `${short}--${self.name} ${value}`,
            _ => `${short}--${self.name}`,
        }
    }
}

// One argv token, classified the way clap_lex does. Tokens after `--`
// are `_Escaped`: positional values even if they look like flags or
// subcommands.
class _DoubleDash {
}

class _Long {
    name: string,
    value: string?,
}

class _Shorts {
    chars: string[],
}

class _Word {
    text: string,
}

class _Escaped {
    text: string,
}

type _Token = _DoubleDash | _Long | _Shorts | _Word | _Escaped;

// Cursor state threaded through `Command._consume`; steps return a
// new state rather than mutating this one.
class _ParseState {
    path: string,
    positional_index: int,
    escaped: bool,

    function escape(self) -> _ParseState {
        _ParseState { path: self.path, positional_index: self.positional_index, escaped: true }
    }

    function next_positional(self) -> _ParseState {
        _ParseState {
            path: self.path,
            positional_index: self.positional_index + 1,
            escaped: self.escaped,
        }
    }

    function lex(self, token: string) -> _Token {
        if (self.escaped) {
            _Escaped { text: token }
        } else if (token == "--") {
            _DoubleDash {}
        } else if (token.starts_with("--")) {
            let body = token.slice(2, token.length());
            match (body.index_of("=")) {
                null => _Long { name: body, value: null },
                let i: int => {
                    _Long { name: body.slice(0, i), value: body.slice(i + 1, body.length()) }
                },
            }
        } else if (_ParseState._looks_like_flag(token)) {
            _Shorts { chars: token.slice(1, token.length()).chars() }
        } else {
            _Word { text: token }
        }
    }

    function _looks_like_flag(token: string) -> bool {
        token.length() > 1 && token.starts_with("-")
    }
}

class Command {
    name: string,
    about_text: string,
    version_text: string?,
    args: Arg[],
    subcommands: Command[],
    help_enabled: bool,
    version_enabled: bool,
    subcommand_is_required: bool,
    help_override: string?,

    function new(name: string) -> Command {
        Command {
            name: name,
            about_text: "",
            version_text: null,
            args: [],
            subcommands: [],
            help_enabled: true,
            version_enabled: true,
            subcommand_is_required: false,
            help_override: null,
        }
    }

    function parse(
        self,
        args: string[],
    ) -> Matches throws ParseError | DisplayHelp | DisplayVersion {
        self._parse(args, self.name)
    }

    // Parses the process argv. BAML always runs a program as
    // `<binary> <entry function> args...`, both under `baml run` and
    // from a packed binary, so the first two entries are skipped.
    function parse_from(
        self,
        argv: string[],
    ) -> Matches throws ParseError | DisplayHelp | DisplayVersion {
        self.parse(argv.slice(2, argv.length()))
    }

    function about(self, text: string) -> Command {
        self.about_text = text;
        self
    }

    function version(self, text: string) -> Command {
        self.version_text = text;
        self
    }

    function arg(self, argument: Arg) -> Command {
        self.args.push(argument);
        self
    }

    function subcommand(self, sub: Command) -> Command {
        self.subcommands.push(sub);
        self
    }

    function help_text(self, text: string) -> Command {
        self.help_override = text;
        self
    }

    function auto_help(self, enabled: bool) -> Command {
        self.help_enabled = enabled;
        self
    }

    function auto_version(self, enabled: bool) -> Command {
        self.version_enabled = enabled;
        self
    }

    function subcommand_required(self) -> Command {
        self.subcommand_is_required = true;
        self
    }

    function version_line(self) -> string {
        `${self.name} ${self.version_text ?? ""}`
    }

    // Declared args followed by the built-in help/version args that
    // apply to this command.
    function all_args(self) -> Arg[] {
        let builtins = [
            Arg.flag("help").with_short("h").help("Print help").with_action(ArgAction.Help),
            Arg.flag("version").help("Print version").with_action(ArgAction.Version),
        ];
        self.args.concat(
            builtins.filter((builtin: Arg) -> bool {
                self._wants_builtin(builtin)
            }),
        )
    }

    function _wants_builtin(self, builtin: Arg) -> bool {
        let enabled = match (builtin.action) {
            ArgAction.Help => self.help_enabled,
            _ => self.version_enabled && self.version_text != null,
        };
        enabled
            && !self.args.some((a: Arg) -> bool {
                a.action == builtin.action || a.name == builtin.name
            })
    }

    function find_arg(self, name: string) -> Arg? {
        self.all_args().find((a: Arg) -> bool {
            a.name == name
        })
    }

    function find_long(self, name: string) -> Arg? {
        self.options().find((a: Arg) -> bool {
            a.name == name
        })
    }

    function find_short(self, short: string) -> Arg? {
        self.options().find((a: Arg) -> bool {
            a.short == short
        })
    }

    function options(self) -> Arg[] {
        self.all_args().filter((a: Arg) -> bool {
            a.is_option()
        })
    }

    function positionals(self) -> Arg[] {
        self.args.filter((a: Arg) -> bool {
            !a.is_option()
        })
    }

    function _resolve(self, found: Arg?, flag: string) -> Arg throws UnknownArgumentError {
        match (found) {
            null => throw UnknownArgumentError.new(flag, self.name),
            let arg: Arg => arg,
        }
    }

    function find_subcommand(self, name: string) -> Command? {
        self.subcommands.find((c: Command) -> bool {
            c.name == name
        })
    }

    function _path_under(self, parent: string) -> string {
        `${parent} ${self.name}`
    }

    function _synthesizes_help(self) -> bool {
        self.help_enabled && self.subcommands.length() > 0 && self.find_subcommand("help") == null
    }

    function _parse(
        self,
        tokens: string[],
        path: string,
    ) -> Matches throws ParseError | DisplayHelp | DisplayVersion {
        let state = _ParseState { path: path, positional_index: 0, escaped: false };
        self._finish(self._consume(Matches.new(self.name), tokens, state))
    }

    function _consume(
        self,
        matches: Matches,
        tokens: string[],
        state: _ParseState,
    ) -> Matches throws ParseError | DisplayHelp | DisplayVersion {
        match (tokens.at(0)) {
            null => matches,
            let token: string => {
                let rest = tokens.slice(1, tokens.length());
                match (state.lex(token)) {
                    _DoubleDash => self._consume(matches, rest, state.escape()),
                    let long: _Long => self._consume_long(matches, long, rest, state),
                    let shorts: _Shorts => self._consume_shorts(matches, shorts, rest, state),
                    let word: _Word => self._consume_word(matches, word, rest, state),
                    let value: _Escaped => {
                        self._consume_positional(matches, value.text, rest, state)
                    },
                }
            },
        }
    }

    function _consume_long(
        self,
        matches: Matches,
        long: _Long,
        rest: string[],
        state: _ParseState,
    ) -> Matches throws ParseError | DisplayHelp | DisplayVersion {
        let arg = self._resolve(self.find_long(long.name), `--${long.name}`);
        let remaining = match (arg.action) {
            ArgAction.Value => self._take_value(matches, arg, long.value, rest),
            _ => match (long.value) {
                null => {
                    self._take_flag(matches, arg, state.path);
                    rest
                },
                let value: string => throw InvalidValueError.no_value_allowed(arg, value, self.name),
            },
        };
        self._consume(matches, remaining, state)
    }

    function _consume_shorts(
        self,
        matches: Matches,
        shorts: _Shorts,
        rest: string[],
        state: _ParseState,
    ) -> Matches throws ParseError | DisplayHelp | DisplayVersion {
        let remaining = self._take_shorts(matches, shorts.chars, rest, state.path);
        self._consume(matches, remaining, state)
    }

    // A word is a subcommand if one has that name; otherwise a positional.
    function _consume_word(
        self,
        matches: Matches,
        word: _Word,
        rest: string[],
        state: _ParseState,
    ) -> Matches throws ParseError | DisplayHelp | DisplayVersion {
        match (self._subcommand_match(word.text, rest, state.path)) {
            null => self._consume_positional(matches, word.text, rest, state),
            let sub: SubMatch => {
                matches.sub_match = sub;
                matches
            },
        }
    }

    // A `multiple` positional keeps its slot; the last positional also
    // absorbs any overflow so it reports duplicates instead of
    // "unexpected argument".
    function _consume_positional(
        self,
        matches: Matches,
        token: string,
        rest: string[],
        state: _ParseState,
    ) -> Matches throws ParseError | DisplayHelp | DisplayVersion {
        let positionals = self.positionals();
        match (positionals.at(state.positional_index) ?? positionals.at(-1)) {
            null => throw UnexpectedPositionalError.new(token, self.name),
            let arg: Arg => {
                matches._take(arg, token);
                let next = if (arg.is_multiple) {
                    state
                } else {
                    state.next_positional()
                };

                self._consume(matches, rest, next)
            },
        }
    }

    // `-abc` is three flags; `-ofile` is option `o` with value `file`.
    // Returns the tokens left after the cluster.
    function _take_shorts(
        self,
        matches: Matches,
        chars: string[],
        rest: string[],
        path: string,
    ) -> string[] throws UnknownArgumentError
        | MissingValueError
        | InvalidValueError
        | DuplicateArgumentError
        | DisplayHelp
        | DisplayVersion {
        match (chars.at(0)) {
            null => rest,
            let head: string => {
                let arg = self._resolve(self.find_short(head), `-${head}`);
                let tail = chars.slice(1, chars.length());

                match (arg.action) {
                    ArgAction.Value => {
                        self._take_value(
                            matches,
                            arg,
                            root.lib.text.Text.non_empty(tail.join("")),
                            rest,
                        )
                    },
                    _ => {
                        self._take_flag(matches, arg, path);
                        self._take_shorts(matches, tail, rest, path)
                    },
                }
            },
        }
    }
    function _take_flag(
        self,
        matches: Matches,
        arg: Arg,
        path: string,
    ) -> null throws InvalidValueError | DuplicateArgumentError | DisplayHelp | DisplayVersion {
        match (arg.action) {
            ArgAction.Help => throw DisplayHelp { text: self.format_help(path) },
            ArgAction.Version => {
                throw DisplayVersion { text: self.version_line() }
            },
            _ => matches._take(arg, "true"),
        }
    }

    // Takes one value for `arg`: `inline` (from `--name=v` or `-nv`) if
    // given, otherwise the next token unless it looks like a flag.
    // Returns the tokens left after the value.
    function _take_value(
        self,
        matches: Matches,
        arg: Arg,
        inline: string?,
        rest: string[],
    ) -> string[] throws MissingValueError | InvalidValueError | DuplicateArgumentError {
        let value = match (inline) {
            let value: string => value,
            null => {
                let next = rest.slice(0, 1).find((token: string) -> bool {
                    arg.allow_hyphen || !_ParseState._looks_like_flag(token)
                });
                match (next) {
                    null => throw MissingValueError.new(arg, self.name),
                    let value: string => value,
                }
            },
        };
        matches._take(arg, value);
        match (inline) {
            null => rest.slice(1, rest.length()),
            _ => rest,
        }
    }

    // The subcommand `word` names, parsed with the remaining tokens, or
    // null when `word` should be taken as a positional instead.
    function _subcommand_match(
        self,
        word: string,
        rest: string[],
        path: string,
    ) -> SubMatch? throws ParseError | DisplayHelp | DisplayVersion {
        if (self._synthesizes_help() && word == "help") {
            throw DisplayHelp {
                text: match (rest.at(0)) {
                    null => self.format_help(path),
                    let name: string => match (self.find_subcommand(name)) {
                        null => throw UnknownCommandError.new(name, self.name),
                        let sub: Command => sub.format_help(sub._path_under(path)),
                    },
                },
            };
        }
        match (self.find_subcommand(word)) {
            let sub: Command => {
                SubMatch { name: sub.name, matches: sub._parse(rest, sub._path_under(path)) }
            },
            null => {
                if (self.subcommands.length() > 0 && self.positionals().length() == 0) {
                    throw UnknownCommandError.new(word, self.name);
                }
                null
            },
        }
    }

    function _finish(
        self,
        matches: Matches,
    ) -> Matches throws MissingRequiredError | ConflictError | UnknownCommandError {
        for (let arg in self.args) {
            matches._apply_default(arg);
            self._validate_arg(matches, arg);
        }
        if (self.subcommand_is_required && matches.sub_match == null) {
            throw UnknownCommandError.missing(self.name);
        }
        matches
    }

    function _validate_arg(
        self,
        matches: Matches,
        arg: Arg,
    ) -> null throws MissingRequiredError | ConflictError {
        if (matches.is_present(arg.name)) {
            self._check_relations(matches, arg)
        } else {
            self._check_required(arg)
        }
    }

    function _check_required(self, arg: Arg) -> null throws MissingRequiredError {
        if (arg.is_required && arg.default_value == null) {
            throw MissingRequiredError.new(arg, self.name);
        }
        null
    }

    function _check_relations(
        self,
        matches: Matches,
        arg: Arg,
    ) -> null throws MissingRequiredError | ConflictError {
        match (arg.conflicts.find(matches.is_present)) {
            null => null,
            let other: string => {
                throw ConflictError.new(arg, other, self.find_arg(other), self.name)
            },
        };
        match (
            arg.requires_args.find((needed: string) -> bool {
                !matches.is_present(needed)
            })
        ) {
            null => null,
            let needed: string => throw MissingRequiredError.required_by(needed, arg, self.name),
        }
    }

    function _only_if<T>(condition: bool, items: T[]) -> T[] {
        if (condition) {
            items
        } else {
            []
        }
    }

    function _help_rows(rows: string[][]) -> string {
        let width = root.lib.text.Text.max_length(
            rows.map((row: string[]) -> string {
                row[0]
            }),
        );

        rows
            .map((row: string[]) -> string {
                match (root.lib.text.Text.non_empty(row[1])) {
                    null => `  ${row[0]}`,
                    let about: string => `  ${root.lib.text.Text.pad_to(row[0], width)}  ${about}`,
                }
            })
            .join("\n")
    }

    function _help_section(title: string, rows: string[][]) -> string? {
        match (rows.length()) {
            0 => null,
            _ => `${title}:\n${Command._help_rows(rows)}`,
        }
    }

    function format_help(self, path: string) -> string {
        self.help_override ?? self._generated_help(path)
    }

    function _generated_help(self, path: string) -> string {
        let options = self.options();
        let positionals = self.positionals();
        let arg_row = (a: Arg) -> string[] {
            [a.display_name(), a._annotation()]
        };
        let usage = [
            [path],
            Command._only_if(options.length() > 0, ["[OPTIONS]"]),
            positionals.map((a: Arg) -> string {
                a._usage()
            }),
            Command._only_if(self.subcommands.length() > 0, ["[COMMAND]"]),
        ]
            .flat_map((part: string[]) -> string[] {
                part
            })
            .join(" ");
        let command_rows = self.subcommands
            .map((c: Command) -> string[] {
                [c.name, c.about_text]
            })
            .concat(
                Command._only_if(self._synthesizes_help(), [["help", "Print help for a command"]]),
            );
        root.lib.text.Text.join_present(
            [
                root.lib.text.Text.non_empty(self.about_text),
                `Usage: ${usage}`,
                Command._help_section("Commands", command_rows),
                Command._help_section("Arguments", positionals.map(arg_row)),
                Command._help_section("Options", options.map(arg_row)),
            ],
            "\n\n",
        )
    }
}

class SubMatch {
    name: string,
    matches: Matches,
}

// Where a matched value came from. Defaults fill in values but do not
// count as present, so they never trigger conflicts or duplicates.
enum ValueSource {
    CommandLine,
    Default,
}

class MatchedArg {
    values: string[],
    source: ValueSource,
}

class Matches {
    command: string,
    args: map<string, MatchedArg>,
    sub_match: SubMatch?,

    function new(command: string) -> Matches {
        Matches { command: command, args: {}, sub_match: null }
    }

    function empty() -> Matches {
        Matches.new("")
    }

    function get(self, name: string) -> string? {
        self.get_many(name).at(0)
    }

    function get_or(self, name: string, fallback: string) -> string {
        self.get(name) ?? fallback
    }

    function get_many(self, name: string) -> string[] {
        match (self.args.get(name)) {
            null => [],
            let matched: MatchedArg => matched.values,
        }
    }

    function get_int(self, name: string) -> int? throws InvalidValueError {
        match (self.get(name)) {
            null => null,
            let raw: string => match (root.lib.text.Text.parse_int_or_null(raw)) {
                null => throw InvalidValueError.not_an_int(name, raw, self.command),
                let n: int => n,
            },
        }
    }

    function value_source(self, name: string) -> ValueSource? {
        match (self.args.get(name)) {
            null => null,
            let matched: MatchedArg => matched.source,
        }
    }

    function is_present(self, name: string) -> bool {
        self.value_source(name) == ValueSource.CommandLine
    }

    function subcommand(self) -> string? {
        match (self.sub_match) {
            null => null,
            let sub: SubMatch => sub.name,
        }
    }

    function sub(self) -> Matches? {
        match (self.sub_match) {
            null => null,
            let matched: SubMatch => matched.matches,
        }
    }

    function _take(
        self,
        arg: Arg,
        value: string,
    ) -> null throws InvalidValueError | DuplicateArgumentError {
        arg._check_value(value, self.command);
        if (!arg.is_multiple && self.is_present(arg.name)) {
            throw DuplicateArgumentError.new(arg, self.command);
        }
        self.args
            .get_or_insert(arg.name, MatchedArg { values: [], source: ValueSource.CommandLine })
            .values.push(value);
        null
    }

    function _apply_default(self, arg: Arg) -> null {
        match (arg.default_value) {
            null => null,
            let value: string => {
                self.args.get_or_insert(
                    arg.name,
                    MatchedArg { values: [value], source: ValueSource.Default },
                );
                null
            },
        }
    }
}

testset "parser" {
    let _demo_spec = () -> Command {
        Command.new("tool")
            .about("Demo tool")
            .version("1.2.3")
            .subcommand(
                Command.new("check")
                    .about("Run a check")
                    .arg(
                        Arg.opt("backend")
                            .with_value_name("URL")
                            .help("Backend origin")
                            .conflicts_with("base"),
                    )
                    .arg(Arg.opt("base").with_value_name("REF").help("Comparison base"))
                    .arg(Arg.flag("force").with_short("f").help("Force it"))
                    .arg(Arg.pos("file").multiple()),
            )
            .subcommand(Command.new("lint").about("Lint only"))
    };

    let _expect_help = (args: string[]) -> string {
        let result = _demo_spec().parse(args) catch (e) {
            DisplayHelp => e.text,
        };
        match (result) {
            let text: string => text,
            _ => "NO_HELP",
        }
    };

    let _expect_version = (args: string[]) -> string {
        let result = _demo_spec().parse(args) catch (e) {
            DisplayVersion => e.text,
        };
        match (result) {
            let text: string => text,
            _ => "NO_VERSION",
        }
    };

    test "parses values equals shorts and positionals" {
        let m = _demo_spec().parse(["check", "--backend=https://x.example", "-f", "a.txt", "b.txt"]);
        assert.equal(m.subcommand(), "check");
        let sub = m.sub() ?? Matches.empty();
        assert.equal(sub.get("backend"), "https://x.example");
        assert.is_true(sub.is_present("force"));
        assert.equal(sub.get_many("file").join(","), "a.txt,b.txt")
    }

    test "conflicts duplicates and unknown args are typed errors" {
        let conflict = _demo_spec().parse(["check", "--backend", "u", "--base", "main"]) catch (e) {
            ConflictError => `${e.argument}/${e.other}`,
        };
        assert.equal(conflict, "backend/base");
        let dup = _demo_spec().parse(["check", "--base", "a", "--base", "b"]) catch (e) {
            DuplicateArgumentError => e.argument,
        };
        assert.equal(dup, "base");
        let unknown = _demo_spec().parse(["check", "--nope"]) catch (e) {
            UnknownArgumentError => e.argument,
        };
        assert.equal(unknown, "--nope");
        let missing = _demo_spec().parse(["check", "--backend"]) catch (e) {
            MissingValueError => e.message(),
        };
        assert.equal(missing, "a value is required for '--backend <URL>' but none was supplied")
    }

    test "parse_from skips the binary and entry function" {
        let m = _demo_spec().parse_from(["/bin/tool", "main", "check", "-f"]);
        assert.equal(m.subcommand(), "check");
        assert.is_true((m.sub() ?? Matches.empty()).is_present("force"))
    }

    test "double dash stops flag parsing" {
        let m = _demo_spec().parse(["check", "--", "--force"]);
        let sub = m.sub() ?? Matches.empty();
        assert.equal(sub.get_many("file").join(","), "--force");
        assert.equal(sub.is_present("force"), false)
    }

    test "defaults fill values without counting as present" {
        let spec = Command.new("tool").arg(Arg.opt("mode").default("fast").conflicts_with("slow")).arg(
            Arg.flag("slow"),
        );
        let m = spec.parse(["--slow"]);
        assert.equal(m.get("mode"), "fast");
        assert.equal(m.is_present("mode"), false);
        assert.equal(m.value_source("mode"), ValueSource.Default);
        assert.equal(spec.parse(["--mode", "eco"]).value_source("mode"), ValueSource.CommandLine)
    }

    test "help and version are builtin args that can be replaced" {
        let spec = Command.new("tool").version("9.0").arg(
            Arg.flag("version").with_short("V").help("Show version").with_action(ArgAction.Version),
        );
        let version = spec.parse(["-V"]) catch (e) {
            DisplayVersion => e.text,
        };
        assert.equal(version, "tool 9.0");
        let help = spec.parse(["-h"]) catch (e) {
            DisplayHelp => e.text,
        };
        assert.equal(
            help,
            "Usage: tool [OPTIONS]\n\nOptions:\n  -V, --version  Show version\n  -h, --help     Print help",
        );
        let disabled = Command.new("tool").auto_help(false).parse(["--help"]) catch (e) {
            UnknownArgumentError => e.argument,
        };
        assert.equal(disabled, "--help")
    }

    test "help override replaces generated help" {
        let spec = Command.new("tool").help_text("CUSTOM HELP");
        let result = spec.parse(["--help"]) catch (e) {
            DisplayHelp => e.text,
        };
        let text = match (result) {
            let s: string => s,
            _ => "NO_HELP",
        };
        assert.equal(text, "CUSTOM HELP")
    }

    test "help and version are display requests" {
        let help = _expect_help(["check", "--help"]);
        assert.is_true(help.includes("Usage: tool check"));
        assert.is_true(help.includes("--backend <URL>"));
        assert.equal(_expect_version(["--version"]), "tool 1.2.3");
        assert.is_true(_expect_help(["help", "check"]).includes("Run a check"))
    }
}
