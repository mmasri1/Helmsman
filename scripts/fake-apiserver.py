#!/usr/bin/env python3
"""A tiny stand-in for kube-apiserver, just enough to test a Helmsman node join.

It makes a throwaway CA and a serving certificate (SANs: 10.0.2.2, which is the
build host as seen from QEMU user networking, plus 127.0.0.1 and localhost), then
serves over HTTPS:

  GET  /api/v1/namespaces/kube-public/configmaps/cluster-info   the CA, as kubeadm publishes it
  POST /apis/certificates.k8s.io/v1/certificatesigningrequests  logged, never approved
  GET  /apis/certificates.k8s.io/v1/certificatesigningrequests  an empty list

Every CSR is logged as one line to --log:
  CSR cn=system:node:NAME o=system:nodes signer=... usages=... token=TOKENID
The CA's kubeadm-style pin (sha256 of its SubjectPublicKeyInfo) goes to DIR/ca-hash,
written last, so its existence means the server is listening.

Needs python3-cryptography (it is a test fixture for the build host, not part of the image).
"""
import argparse
import base64
import datetime
import hashlib
import ipaddress
import json
import os
import ssl
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

CLUSTER_INFO = "/api/v1/namespaces/kube-public/configmaps/cluster-info"
CSRS = "/apis/certificates.k8s.io/v1/certificatesigningrequests"


def make_pki(d):
    now = datetime.datetime.now(datetime.timezone.utc)
    start, end = now - datetime.timedelta(hours=1), now + datetime.timedelta(days=2)
    ca_key = ec.generate_private_key(ec.SECP256R1())
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "helmsman-test-ca")])
    ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name)
          .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(start).not_valid_after(end)
          .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
          .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
          .sign(ca_key, hashes.SHA256()))
    key = ec.generate_private_key(ec.SECP256R1())
    sans = [x509.DNSName("localhost"), x509.DNSName("kubernetes"),
            x509.IPAddress(ipaddress.ip_address("10.0.2.2")), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]
    cert = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "kube-apiserver")]))
            .issuer_name(ca_name).public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(start).not_valid_after(end)
            .add_extension(x509.SubjectAlternativeName(sans), critical=False)
            .add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .sign(ca_key, hashes.SHA256()))
    pem = lambda c: c.public_bytes(serialization.Encoding.PEM)
    with open(os.path.join(d, "ca.crt"), "wb") as f:
        f.write(pem(ca))
    with open(os.path.join(d, "server.crt"), "wb") as f:
        f.write(pem(cert) + pem(ca))
    with open(os.path.join(d, "server.key"), "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                  serialization.NoEncryption()))
    spki = ca.public_key().public_bytes(serialization.Encoding.DER,
                                        serialization.PublicFormat.SubjectPublicKeyInfo)
    return pem(ca), "sha256:" + hashlib.sha256(spki).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dir", required=True, help="where to write the CA, server cert and ca-hash")
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6443)
    ap.add_argument("--log", required=True, help="file that receives one line per CSR")
    ap.add_argument("--server-url", default="https://10.0.2.2:6443",
                    help="server written into the published cluster-info kubeconfig")
    a = ap.parse_args()

    os.makedirs(a.dir, exist_ok=True)
    ca_pem, ca_hash = make_pki(a.dir)
    kubeconfig = ("apiVersion: v1\nkind: Config\nclusters:\n- cluster:\n"
                  f"    certificate-authority-data: {base64.b64encode(ca_pem).decode()}\n"
                  f"    server: {a.server_url}\n  name: \"\"\ncontexts: null\n"
                  "current-context: \"\"\npreferences: {}\nusers: null\n")
    cluster_info = {"kind": "ConfigMap", "apiVersion": "v1",
                    "metadata": {"name": "cluster-info", "namespace": "kube-public"},
                    "data": {"kubeconfig": kubeconfig}}
    log_lock = threading.Lock()

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            sys.stderr.write("fake-apiserver: %s %s\n" % (self.address_string(), fmt % args))

        def send_json(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def not_found(self):
            self.send_json(404, {"kind": "Status", "apiVersion": "v1", "status": "Failure",
                                 "reason": "NotFound", "code": 404, "message": self.path})

        def do_GET(self):
            path = self.path.split("?")[0]
            if path == CLUSTER_INFO:
                self.send_json(200, cluster_info)
            elif path == CSRS:
                self.send_json(200, {"kind": "CertificateSigningRequestList",
                                     "apiVersion": "certificates.k8s.io/v1",
                                     "metadata": {"resourceVersion": "1"}, "items": []})
            else:
                self.not_found()

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if self.path.split("?")[0] != CSRS:
                return self.not_found()
            obj = json.loads(body)
            csr = x509.load_pem_x509_csr(base64.b64decode(obj["spec"]["request"]))
            attr = lambda oid: ",".join(v.value for v in csr.subject.get_attributes_for_oid(oid))
            auth = self.headers.get("Authorization", "")
            token = auth.split(" ", 1)[1].split(".")[0] if auth.startswith("Bearer ") else "-"
            with log_lock, open(a.log, "a") as f:
                f.write("CSR cn=%s o=%s signer=%s usages=%s token=%s\n" % (
                    attr(NameOID.COMMON_NAME), attr(NameOID.ORGANIZATION_NAME),
                    obj["spec"].get("signerName"), ",".join(obj["spec"].get("usages", [])), token))
            obj.setdefault("metadata", {})
            obj["metadata"]["name"] = obj["metadata"].get("name") or "csr-" + uuid.uuid4().hex[:5]
            obj["metadata"].update(uid=str(uuid.uuid4()), resourceVersion="2")
            obj["status"] = {}
            self.send_json(201, obj)

    srv = ThreadingHTTPServer((a.bind, a.port), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(a.dir, "server.crt"), os.path.join(a.dir, "server.key"))
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    with open(os.path.join(a.dir, "ca-hash"), "w") as f:
        f.write(ca_hash + "\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
