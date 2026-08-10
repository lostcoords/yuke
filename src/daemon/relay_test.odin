package daemon

import "core:testing"

@(test)
test_relay_cloud_url_normalization :: proc(t: ^testing.T) {
    Case :: struct {
        source: string,
        want:   string,
        valid:  bool,
    }
    cases := []Case {
        {"https://platform.yuke.sh", "https://platform.yuke.sh", true},
        {"https://platform.yuke.sh/base///", "https://platform.yuke.sh/base", true},
        {"https://[::1]:8443/control", "https://[::1]:8443/control", true},
        {"http://127.0.0.1:8080", "http://127.0.0.1:8080", true},
        {"http://127.9.8.7/dev", "http://127.9.8.7/dev", true},
        {"http://localhost:8080", "", false},
        {"http://192.0.2.1", "", false},
        {"https://user@example.com", "", false},
        {"https://example.com?target=x", "", false},
        {"https://example.com/#fragment", "", false},
        {"https://example.com:", "", false},
        {"https://example.com:0", "", false},
        {"https://example.com:65536", "", false},
        {"https://example.com/a/../b", "", false},
        {"ftp://example.com", "", false},
    }

    for tc in cases {
        normalized, err := relay_cloud_url_normalize(tc.source)
        defer delete(normalized)

        testing.expect_value(t, err == .None, tc.valid)
        if tc.valid {
            testing.expect_value(t, normalized, tc.want)
        }
    }
}
