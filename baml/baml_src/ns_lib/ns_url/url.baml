// URL parsing modeled on the Rust `url` crate (WHATWG URL Standard):
// a parsed value exposing component getters, `Host` and `Origin` types,
// classified parse errors, special-scheme default ports, and `join`
// relative resolution.
//
// Deliberate subsets for this codebase: only special schemes with an
// authority parse at all (cannot-be-a-base URLs are unrepresentable),
// domains are ASCII (no IDNA), IPv4 is decimal dotted-quad only, and
// characters the standard would percent-encode are rejected instead.

enum UrlParseErrorKind {
    EmptyHost,
    InvalidDomainCharacter,
    InvalidIpv4Address,
    InvalidIpv6Address,
    InvalidPort,
    InvalidScheme,
    UnsupportedScheme,
    InvalidAuthority,
    RelativeUrlWithoutBase,
}

class UrlParseError {
    kind: UrlParseErrorKind,
    message: string,
}

enum Scheme {
    Http,
    Https,
    Ws,
    Wss,
    Ftp,
}

function scheme_name(scheme: Scheme) -> string {
    match (scheme) {
        Scheme.Http => "http",
        Scheme.Https => "https",
        Scheme.Ws => "ws",
        Scheme.Wss => "wss",
        Scheme.Ftp => "ftp",
    }
}

function scheme_default_port(scheme: Scheme) -> int {
    match (scheme) {
        Scheme.Http => 80,
        Scheme.Ws => 80,
        Scheme.Https => 443,
        Scheme.Wss => 443,
        Scheme.Ftp => 21,
    }
}

function parse_scheme(name: string) -> Scheme throws UrlParseError {
    match (name.to_lower_case()) {
        "http" => Scheme.Http,
        "https" => Scheme.Https,
        "ws" => Scheme.Ws,
        "wss" => Scheme.Wss,
        "ftp" => Scheme.Ftp,
        _ => {
            if (is_valid_scheme_syntax(name)) {
                throw UrlParseError { kind: UrlParseErrorKind.UnsupportedScheme, message: `unsupported scheme "${name}"` }
            } else {
                throw UrlParseError { kind: UrlParseErrorKind.InvalidScheme, message: `invalid scheme "${name}"` }
            }
        },
    }
}

function is_valid_scheme_syntax(name: string) -> bool {
    if (name.is_empty()) {
        return false;
    }
    let chars = name.chars();
    if (!chars[0].is_ascii_alphabetic()) {
        return false;
    }
    chars.every((c: string) -> bool {
        c.is_ascii_alphanumeric() || c == "+" || c == "-" || c == "."
    })
}

class DomainHost {
    name: string,

    function serialize(self) -> string {
        self.name
    }
}

class Ipv4Host {
    octets: int[],

    function serialize(self) -> string {
        self.octets
            .map((n: int) -> string {
                string.from(n)
            })
            .join(".")
    }
}

class Ipv6Host {
    address: string,

    function serialize(self) -> string {
        `[${self.address}]`
    }
}

type Host = DomainHost | Ipv4Host | Ipv6Host;

function host_str(host: Host) -> string {
    match (host) {
        DomainHost => host.serialize(),
        Ipv4Host => host.serialize(),
        Ipv6Host => host.serialize(),
    }
}

function parse_ipv4(text: string) -> int[] throws UrlParseError {
    let parts = text.split(".");
    if (parts.length() != 4) {
        throw UrlParseError { kind: UrlParseErrorKind.InvalidIpv4Address, message: `invalid IPv4 address "${text}"` };
    }
    parts.map((part: string) -> int {
        if (
            part.is_empty()
                || !part.chars().every((c: string) -> bool {
                    c.is_ascii_numeric()
                })
        ) {
            throw UrlParseError { kind: UrlParseErrorKind.InvalidIpv4Address, message: `invalid IPv4 address "${text}"` };
        }
        match (root.lib.text.Text.parse_int_or_null(part)) {
            null => {
                throw UrlParseError { kind: UrlParseErrorKind.InvalidIpv4Address, message: `invalid IPv4 address "${text}"` }
            },
            let n: int => {
                if (n > 255) {
                    throw UrlParseError { kind: UrlParseErrorKind.InvalidIpv4Address, message: `invalid IPv4 address "${text}"` }
                } else {
                    n
                }
            },
        }
    })
}

function looks_like_ipv4(text: string) -> bool {
    let parts = text.split(".");
    parts.length() == 4
        && parts.every((p: string) -> bool {
            !p.is_empty()
                && p.chars().every((c: string) -> bool {
                    c.is_ascii_numeric()
                })
        })
}

function parse_ipv6(text: string) -> string throws UrlParseError {
    let lower = text.to_lower_case();
    let valid_chars = lower.chars().every((c: string) -> bool {
        c.is_ascii_hex() || c == ":" || c == "."
    });
    let compressions = lower.split("::").length() - 1;
    if (!valid_chars || compressions > 1 || lower.is_empty()) {
        throw UrlParseError { kind: UrlParseErrorKind.InvalidIpv6Address, message: `invalid IPv6 address "${text}"` };
    }
    lower
}

function parse_host(text: string) -> Host throws UrlParseError {
    if (text.is_empty()) {
        throw UrlParseError { kind: UrlParseErrorKind.EmptyHost, message: "host is empty" };
    }
    if (text.starts_with("[")) {
        if (!text.ends_with("]")) {
            throw UrlParseError { kind: UrlParseErrorKind.InvalidIpv6Address, message: `invalid IPv6 host "${text}"` };
        }
        return Ipv6Host { address: parse_ipv6(text.slice(1, text.length() - 1)) };
    }
    if (looks_like_ipv4(text)) {
        return Ipv4Host { octets: parse_ipv4(text) };
    }
    let valid = text.chars().every((c: string) -> bool {
        c.is_ascii_alphanumeric() || c == "-" || c == "." || c == "_"
    });
    if (!valid || text.starts_with(".") || text.includes("..")) {
        throw UrlParseError { kind: UrlParseErrorKind.InvalidDomainCharacter, message: `invalid domain "${text}"` };
    }
    DomainHost { name: text.to_lower_case() }
}

// Tuple origin only: every supported scheme has one (cf. Origin::Tuple).
class Origin {
    scheme: Scheme,
    host: Host,
    port: int,

    function ascii_serialization(self) -> string {
        if (self.port == scheme_default_port(self.scheme)) {
            `${scheme_name(self.scheme)}://${host_str(self.host)}`
        } else {
            `${scheme_name(self.scheme)}://${host_str(self.host)}:${self.port}`
        }
    }
}

class AuthorityParts {
    username: string,
    password: string?,
    host: Host,
    port: int?,
}

function parse_port(text: string) -> int throws UrlParseError {
    match (root.lib.text.Text.parse_int_or_null(text)) {
        null => {
            throw UrlParseError { kind: UrlParseErrorKind.InvalidPort, message: `invalid port "${text}"` }
        },
        let port: int => {
            if (port < 0 || port > 65535) {
                throw UrlParseError { kind: UrlParseErrorKind.InvalidPort, message: `port out of range "${text}"` }
            } else {
                port
            }
        },
    }
}

function parse_authority(text: string, scheme: Scheme) -> AuthorityParts throws UrlParseError {
    let hostport = text;
    let username = "";
    let password: string? = null;
    match (text.last_index_of("@")) {
        null => null,
        let at: int => {
            let userinfo = text.slice(0, at);
            hostport = text.slice(at + 1, text.length());
            let colon = userinfo.index_of(":");
            if (colon == null) {
                username = userinfo;
            } else {
                let c = colon ?? 0;
                username = userinfo.slice(0, c);
                password = userinfo.slice(c + 1, userinfo.length());
            }
        },
    };
    let host_text = hostport;
    let port: int? = null;
    if (hostport.starts_with("[")) {
        match (hostport.index_of("]")) {
            null => {
                throw UrlParseError { kind: UrlParseErrorKind.InvalidIpv6Address, message: `invalid authority "${text}"` }
            },
            let close: int => {
                host_text = hostport.slice(0, close + 1);
                let rest = hostport.slice(close + 1, hostport.length());
                if (!rest.is_empty()) {
                    if (!rest.starts_with(":")) {
                        throw UrlParseError { kind: UrlParseErrorKind.InvalidAuthority, message: `invalid authority "${text}"` };
                    }
                    port = parse_port(rest.slice(1, rest.length()));
                }
            },
        };
    } else {
        match (hostport.last_index_of(":")) {
            null => null,
            let colon: int => {
                host_text = hostport.slice(0, colon);
                let port_text = hostport.slice(colon + 1, hostport.length());
                if (!port_text.is_empty()) {
                    port = parse_port(port_text);
                }
            },
        };
    }
    let effective = match (port) {
        null => null,
        let p: int => {
            if (p == scheme_default_port(scheme)) {
                null
            } else {
                p
            }
        },
    };
    AuthorityParts {
        username: username,
        password: password,
        host: parse_host(host_text),
        port: effective,
    }
}

function split_path_query_fragment(rest: string) -> string[] {
    let fragment: string? = null;
    let query: string? = null;
    let path = rest;
    let hash = path.index_of("#");
    if (hash != null) {
        let idx = hash ?? 0;
        fragment = path.slice(idx + 1, path.length());
        path = path.slice(0, idx);
    }
    let qmark = path.index_of("?");
    if (qmark != null) {
        let idx = qmark ?? 0;
        query = path.slice(idx + 1, path.length());
        path = path.slice(0, idx);
    }
    let parts: string[] = [path, (query ?? ""), (fragment ?? "")];
    parts
}

function reject_bad_chars(input: string) -> null throws UrlParseError {
    if (
        input.chars().some((c: string) -> bool {
            c.is_ascii_control() || c == " "
        })
    ) {
        throw UrlParseError { kind: UrlParseErrorKind.InvalidAuthority, message: "URL contains spaces or control characters" };
    }
    null
}

class Url {
    scheme: Scheme,
    username: string,
    password: string?,
    host: Host,
    port: int?,
    path: string,
    query: string?,
    fragment: string?,

    function parse(input: string) -> Url throws UrlParseError {
        reject_bad_chars(input);
        match (input.index_of("://")) {
            null => {
                throw UrlParseError { kind: UrlParseErrorKind.RelativeUrlWithoutBase, message: `relative URL without a base: ${input}` }
            },
            let sep: int => {
                let scheme = parse_scheme(input.slice(0, sep));
                let rest = input.slice(sep + 3, input.length());
                let authority_end = match (rest.index_of("/")) {
                    null => match (rest.index_of("?")) {
                        null => match (rest.index_of("#")) {
                            null => rest.length(),
                            let h: int => h,
                        },
                        let q: int => q,
                    },
                    let s: int => s,
                };
                let authority = parse_authority(rest.slice(0, authority_end), scheme);
                let tail = split_path_query_fragment(rest.slice(authority_end, rest.length()));
                Url {
                    scheme: scheme,
                    username: authority.username,
                    password: authority.password,
                    host: authority.host,
                    port: authority.port,
                    path: if (tail[0].is_empty()) {
                        "/"
                    } else {
                        Url.remove_dot_segments(tail[0])
                    },
                    query: if (tail[1].is_empty()) {
                        null
                    } else {
                        tail[1]
                    },
                    fragment: if (tail[2].is_empty()) {
                        null
                    } else {
                        tail[2]
                    },
                }
            },
        }
    }

    function as_str(self) -> string {
        let userinfo = if (self.username.is_empty()) {
            ""
        } else {
            match (self.password) {
                null => `${self.username}@`,
                let pw: string => `${self.username}:${pw}@`,
            }
        };
        let port = match (self.port) {
            null => "",
            let p: int => `:${p}`,
        };
        let query = match (self.query) {
            null => "",
            let q: string => `?${q}`,
        };
        let fragment = match (self.fragment) {
            null => "",
            let f: string => `#${f}`,
        };
        `${scheme_name(self.scheme)}://${userinfo}${host_str(self.host)}${port}${self.path}${query}${fragment}`
    }

    function origin(self) -> Origin {
        Origin { scheme: self.scheme, host: self.host, port: self.port_or_known_port() }
    }

    function port_or_known_port(self) -> int {
        self.port ?? scheme_default_port(self.scheme)
    }

    function domain(self) -> string? {
        match (self.host) {
            DomainHost { name } => name,
            _ => null,
        }
    }

    function path_segments(self) -> string[] {
        self.path.split("/").filter((s: string) -> bool {
            !s.is_empty()
        })
    }

    function has_credentials(self) -> bool {
        !self.username.is_empty() || self.password != null
    }

    function remove_dot_segments(path: string) -> string {
        let out: string[] = [];
        for (let seg in path.split("/")) {
            match (seg) {
                "." => null,
                ".." => {
                    out.pop();
                    null
                },
                "" => null,
                _ => {
                    out.push(seg);
                    null
                },
            };
        }
        let joined = `/${out.join("/")}`;
        if (
            (path.ends_with("/") || path.ends_with("/.") || path.ends_with("/.."))
                && !joined.ends_with("/")
        ) {
            `${joined}/`
        } else {
            joined
        }
    }

    function join(self, input: string) -> Url throws UrlParseError {
        reject_bad_chars(input);
        if (input.is_empty()) {
            return Url {
                scheme: self.scheme,
                username: self.username,
                password: self.password,
                host: self.host,
                port: self.port,
                path: self.path,
                query: self.query,
                fragment: null,
            };
        }
        if (input.starts_with("#")) {
            return Url {
                scheme: self.scheme,
                username: self.username,
                password: self.password,
                host: self.host,
                port: self.port,
                path: self.path,
                query: self.query,
                fragment: input.slice(1, input.length()),
            };
        }
        if (input.includes("://")) {
            return Url.parse(input);
        }
        if (input.starts_with("//")) {
            return Url.parse(`${scheme_name(self.scheme)}:${input}`);
        }
        let tail = split_path_query_fragment(input);
        if (input.starts_with("?")) {
            return Url {
                scheme: self.scheme,
                username: self.username,
                password: self.password,
                host: self.host,
                port: self.port,
                path: self.path,
                query: tail[1],
                fragment: if (tail[2].is_empty()) {
                    null
                } else {
                    tail[2]
                },
            };
        }
        let merged = if (tail[0].starts_with("/")) {
            tail[0]
        } else {
            let dir = match (self.path.last_index_of("/")) {
                null => "/",
                let idx: int => self.path.slice(0, idx + 1),
            };
            `${dir}${tail[0]}`
        };
        Url {
            scheme: self.scheme,
            username: self.username,
            password: self.password,
            host: self.host,
            port: self.port,
            path: Url.remove_dot_segments(merged),
            query: if (tail[1].is_empty()) {
                null
            } else {
                tail[1]
            },
            fragment: if (tail[2].is_empty()) {
                null
            } else {
                tail[2]
            },
        }
    }

    function require_https_origin(self) -> Url throws root.CliError {
        if (self.scheme != Scheme.Https) {
            throw root.CliError.new(root.ErrorCode.InvalidBackendUrl, `backend URL must use https: ${self.as_str()}`);
        }
        if (self.has_credentials()) {
            throw root.CliError.new(root.ErrorCode.InvalidBackendUrl, "backend URL must not embed credentials");
        }
        if (self.path != "/" || self.query != null || self.fragment != null) {
            throw root.CliError.new(root.ErrorCode.InvalidBackendUrl, `backend URL must be an origin: ${self.as_str()}`);
        }
        self
    }
}

function parse_backend_url(raw: string) -> Url throws root.CliError {
    let parsed = Url.parse(raw) catch (e) {
        UrlParseError => throw root.CliError.new(root.ErrorCode.InvalidBackendUrl, e.message),
    };
    parsed.require_https_origin()
}

test "url parses and serializes like rust url" {
    let u = Url.parse("https://user:pw@Example.COM:443/a/./b/../c?x=1#top");
    assert.equal(u.as_str(), "https://user:pw@example.com/a/c?x=1#top");
    assert.equal(u.port_or_known_port(), 443);
    assert.equal(u.origin().ascii_serialization(), "https://example.com");
    assert.equal(u.domain(), "example.com")
}

test "url join resolves relative references" {
    let base = Url.parse("https://reviews.example.com/app/index");
    assert.equal(
        base.join("/v1/me/workload").as_str(),
        "https://reviews.example.com/v1/me/workload",
    );
    assert.equal(base.join("detail").as_str(), "https://reviews.example.com/app/detail");
    assert.equal(base.join("../list").as_str(), "https://reviews.example.com/list");
    assert.equal(base.join("?page=2").as_str(), "https://reviews.example.com/app/index?page=2");
    assert.equal(base.join("//other.example.com/x").as_str(), "https://other.example.com/x")
}

test "url classifies parse errors" {
    let a = Url.parse("reviews.example.com") catch (e) {
        UrlParseError => e.kind,
    };
    assert.equal(a, UrlParseErrorKind.RelativeUrlWithoutBase);
    let b = Url.parse("https://example.com:99999/") catch (e) {
        UrlParseError => e.kind,
    };
    assert.equal(b, UrlParseErrorKind.InvalidPort);
    let c = Url.parse("gopher://example.com/") catch (e) {
        UrlParseError => e.kind,
    };
    assert.equal(c, UrlParseErrorKind.UnsupportedScheme)
}

test "backend url gate" {
    assert.equal(
        parse_backend_url("https://reviews.example.com").origin().ascii_serialization(),
        "https://reviews.example.com",
    );
    let bad = parse_backend_url("http://reviews.example.com") catch (e) {
        root.CliError => e.code,
    };
    assert.equal(bad, root.ErrorCode.InvalidBackendUrl);
    let creds = parse_backend_url("https://user:pw@reviews.example.com") catch (e) {
        root.CliError => e.code,
    };
    assert.equal(creds, root.ErrorCode.InvalidBackendUrl)
}
