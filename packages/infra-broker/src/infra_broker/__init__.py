"""Read-only infra tools for the infra-agent broker VM.

Everything in this package runs inside the broker microVM. Credentials come from
infra-credd on the host (see modules/infra-agent/credd) through a vsock bridge
on 127.0.0.1; nothing here stores credentials on disk.
"""
