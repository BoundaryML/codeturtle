class Text {
    function first_line_containing(text: string, needle: string) -> string? {
        match (
            text.lines().find((line: string) -> bool {
                line.includes(needle)
            })
        ) {
            null => null,
            let line: string => line.trim(),
        }
    }

    function short_rev(rev: string) -> string {
        let n = root.lib.limits.Limits.short_rev_length();
        if (rev.length() <= n) {
            rev
        } else {
            rev.slice(0, n)
        }
    }

    function plural(count: int, singular: string, plural: string) -> string {
        if (count == 1) {
            singular
        } else {
            plural
        }
    }

    function pad_to(text: string, width: int) -> string {
        if (text.length() >= width) {
            text
        } else {
            `${text}${" ".repeat(width - text.length())}`
        }
    }

    function non_empty(text: string) -> string? {
        if (text.is_empty()) {
            null
        } else {
            text
        }
    }

    function join_present(parts: (string | null)[], separator: string) -> string {
        parts
            .filter_map((part: string?) -> string? {
                part
            })
            .join(separator)
    }

    function max_length(texts: string[]) -> int {
        texts.reduce(
            (widest: int, text: string) -> int {
                if (text.length() > widest) {
                    text.length()
                } else {
                    widest
                }
            },
            0,
        )
    }

    function parse_int_or_null(text: string) -> int? {
        int.parse(text) catch (e) {
            baml.errors.ParseError => null,
        }
    }

    function decode_utf8(data: uint8array) -> string? {
        string.from_utf8(data) catch (e) {
            baml.errors.InvalidArgument => null,
        }
    }
}

