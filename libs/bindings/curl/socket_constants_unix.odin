#+build linux, darwin, freebsd, openbsd, netbsd

package curl

import posix "core:sys/posix"

SOCK_FAMILY_INET :: posix.AF_INET
SOCK_FAMILY_INET6 :: posix.AF_INET6
SOCK_TYPE_STREAM :: posix.SOCK_STREAM
SOCK_TYPE_DGRAM :: posix.SOCK_DGRAM
