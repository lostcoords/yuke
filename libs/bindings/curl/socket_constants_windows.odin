#+build windows

package curl

import win "core:sys/windows"

SOCK_FAMILY_INET :: win.AF_INET
SOCK_FAMILY_INET6 :: win.AF_INET6
SOCK_TYPE_STREAM :: win.SOCK_STREAM
SOCK_TYPE_DGRAM :: win.SOCK_DGRAM
