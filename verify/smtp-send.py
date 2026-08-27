#!/usr/bin/env python3
"""Send one message through Postfix and report whether it was accepted.

    smtp-send.py --to root@example.com [--starttls]

Exits non-zero if the connection, the handshake, or the message is refused.
The point is to exercise the running smtpd -- STARTTLS included -- rather than
to test any particular content, so the body just carries the marker the
delivery check greps for.
"""
import argparse
import smtplib
import ssl
import sys
from email.message import EmailMessage

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1")
ap.add_argument("--port", type=int, default=25)
ap.add_argument("--sender", default="verify@example.com")
ap.add_argument("--to", required=True)
ap.add_argument("--marker", required=True)
ap.add_argument("--starttls", action="store_true")
a = ap.parse_args()

msg = EmailMessage()
msg["From"] = a.sender
msg["To"] = a.to
msg["Subject"] = "postfix verify %s" % a.marker
msg.set_content("marker: %s\n" % a.marker)

with smtplib.SMTP(a.host, a.port, timeout=30) as s:
    s.ehlo("verify.example.com")
    if a.starttls:
        if not s.has_extn("starttls"):
            print("smtpd did not advertise STARTTLS", file=sys.stderr)
            sys.exit(1)
        # The cert postfix's %post generates is self-signed, so verification
        # is off here on purpose -- this is checking that the TLS build works
        # and the handshake completes, not that a CA trusts the cert.
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        s.starttls(context=ctx)
        s.ehlo("verify.example.com")
        print("negotiated:", s.sock.version(), s.sock.cipher()[0])
    s.send_message(msg)

print("accepted:", a.marker)
