// Canonical tuning constants. One definition each; call sites name the
// limit instead of embedding magic numbers.

class Limits {
    function short_rev_length() -> int {
        8
    }

    function max_login_length() -> int {
        39
    }

    function max_file_text_bytes() -> int {
        1048576
    }

    function max_changed_files() -> int {
        5000
    }

    function git_timeout_ms() -> int {
        30000
    }

    function http_timeout_seconds() -> int {
        15
    }

    function upload_max_attempts() -> int {
        4
    }

    function max_report_bytes() -> int {
        8388608
    }
}
