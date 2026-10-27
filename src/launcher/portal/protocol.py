"""Names, operation policies, and limits shared by desktop portal consumers"""

from functools import lru_cache

from jeepney import MatchRule


@lru_cache(maxsize=128)
def _rule(signature=None, **headers):
    rule = MatchRule(**headers)
    if signature is not None:
        rule.header_fields["signature"] = signature
    return rule


def matches(message, **headers) -> bool:
    return _rule(**headers).matches(message)


PORTAL = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
OPEN_URI = "org.freedesktop.portal.OpenURI"
REQUEST = "org.freedesktop.portal.Request"
CHOOSER = "org.freedesktop.portal.FileChooser"
DOCUMENTS = "org.freedesktop.portal.Documents"
NOTIFICATIONS = "org.freedesktop.Notifications"
INHIBIT = "org.freedesktop.portal.Inhibit"
SCREENCAST = "org.freedesktop.portal.ScreenCast"
SESSION = "org.freedesktop.portal.Session"
DESKTOP_SERVICES = (PORTAL, DOCUMENTS, NOTIFICATIONS)
DESCRIPTOR_METHODS = frozendict(
    {
        (OPEN_URI, "OpenFile", "sha{sv}"): "shared-file",
        (OPEN_URI, "OpenDirectory", "sha{sv}"): "shared-file",
        (SCREENCAST, "OpenPipeWireRemote", "oa{sv}"): "pipewire",
    }
)

MAX_REQUESTS = 128
MAX_MESSAGE_BYTES = 128 * 1024 * 1024
