// HMAC-SHA256 (RFC 2104) built on baml.crypto.Sha256, plus base64url
// helpers for JWT handling. Used for GitHub webhook verification.

function bytes_from_ints(values: int[]) -> uint8array {
    uint8array.from_array(values) catch (e) {
        baml.errors.InvalidArgument => baml.sys.panic("hmac byte out of range"),
    }
}

class Hmac {
    function sha256(key: uint8array, message: uint8array) -> uint8array {
        let block_size = 64;
        let normalized = if (key.length() > block_size) {
            let h = baml.crypto.Sha256.new();
            h.update(key);
            h.finish()
        } else {
            key
        };
        let ipad: int[] = [];
        let opad: int[] = [];
        let i = 0;
        while (i < block_size) {
            let byte = normalized.at(i) ?? 0;
            ipad.push(byte ^ 54);
            opad.push(byte ^ 92);
            i = i + 1;
        }
        let inner = baml.crypto.Sha256.new();
        inner.update(bytes_from_ints(ipad));
        inner.update(message);
        let outer = baml.crypto.Sha256.new();
        outer.update(bytes_from_ints(opad));
        outer.update(inner.finish());
        outer.finish()
    }

    function sha256_hex(key: string, message: string) -> string {
        Hmac.sha256(key.to_utf8(), message.to_utf8()).to_hex()
    }

    function verify_hex(key: string, message: string, expected_hex: string) -> bool {
        Hmac.sha256_hex(key, message) == expected_hex.to_lower_case()
    }
}

test "hmac sha256 known vector" {
    assert.equal(
        Hmac.sha256_hex("key", "The quick brown fox jumps over the lazy dog"),
        "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
    )
}

