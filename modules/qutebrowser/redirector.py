import re
from urllib.parse import urljoin

from qutebrowser.api import interceptor, message
from PyQt6.QtCore import QUrl

EMR_URL_REGEX = re.compile(
    r"ip-(\d+)-(\d+)-(\d+)-(\d+)(?:[^:/]+)?"
)

def _aws_dns_to_ip(url: str) -> str:
    """
    Example: 'ip-10-10-200-213.ap-southeast-2.compute.internal' => '10.10.200.213'
    """
    parts = EMR_URL_REGEX.match(url)

    def none_as_empty_str(s: str) -> str:
        return "" if s is None else s

    if parts:
        return "%s.%s.%s.%s" % (
            none_as_empty_str(parts[1]),
            none_as_empty_str(parts[2]),
            none_as_empty_str(parts[3]),
            none_as_empty_str(parts[4]),
        )
    else:
        return url

def intercept_fn(info: interceptor.Request):
    url = info.request_url

    # Work around AWS urls when working on VPN
    url_host = url.host()
    if EMR_URL_REGEX.match(url_host):
        redir_url_host = _aws_dns_to_ip(url_host)
        url.setHost(redir_url_host)
        info.redirect(url)

interceptor.register(intercept_fn)
