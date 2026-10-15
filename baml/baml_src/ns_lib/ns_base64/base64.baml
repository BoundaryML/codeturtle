// Base64url encoding (RFC 4648 section 5), as used by JWTs.

class Base64Url {
    function encode(data: uint8array) -> string {
        data.to_base64().replace_all("+", "-").replace_all("/", "_").replace_all("=", "")
    }

    function decode(text: string) -> uint8array? {
        let std = text.replace_all("-", "+").replace_all("_", "/");
        let padded = match (std.length() % 4) {
            2 => `${std}==`,
            3 => `${std}=`,
            _ => std,
        };
        uint8array.from_base64(padded) catch (e) {
            baml.errors.InvalidArgument => null,
        }
    }

    function decode_text(text: string) -> string? {
        match (Base64Url.decode(text)) {
            null => null,
            let data: uint8array => root.lib.text.Text.decode_utf8(data),
        }
    }
}

test "base64url round trips jwt payload" {
    let decoded = Base64Url.decode_text("eyJhbGciOiJIUzI1NiJ9");
    assert.equal(decoded, "{\"alg\":\"HS256\"}")
}
