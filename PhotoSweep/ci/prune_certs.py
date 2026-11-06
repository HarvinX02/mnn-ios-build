#!/usr/bin/env python3
"""删除 CI 自己申请、且已经无用的旧开发证书。

每次 xcodebuild -allowProvisioningUpdates 在干净的 runner 上都会申请一张新的
"Created via API" 开发证书，私有密钥只存在于那次构建的临时钥匙串里，事后再也
用不上。积累过多就会撞上 Apple 的证书数量上限，让后续构建直接失败
（"Your account has reached the maximum number of certificates"）。

这里只清理创建时间早于 KEEP_DAYS 天的证书：证书有效期固定一年，因此
创建时间 = expirationDate - 365 天，不需要额外的接口字段。
"""
from __future__ import annotations

import datetime as dt
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
KEY_ID = os.environ.get("ASC_KEY_ID", "")
ISSUER = os.environ.get("ASC_ISSUER_ID", "")
KEY_P8 = os.environ.get("ASC_KEY_P8", "")
KEEP_DAYS = int(os.environ.get("KEEP_DAYS", "3"))


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        KEY_P8,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


def main() -> int:
    if not (KEY_ID and ISSUER and KEY_P8):
        print("missing ASC credentials, skip prune")
        return 0

    s = requests.Session()
    s.headers.update({"Authorization": "Bearer " + token()})

    r = s.get(f"{API}/v1/certificates", params={"limit": 200}, timeout=60)
    r.raise_for_status()
    certs = r.json().get("data", [])

    cutoff = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=365 - KEEP_DAYS)
    victims = []
    for c in certs:
        a = c.get("attributes", {})
        if a.get("displayName") != "Created via API":
            continue
        exp = a.get("expirationDate") or ""
        parsed = dt.datetime.fromisoformat(exp.replace("Z", "+00:00")) if exp else None
        if parsed and parsed < cutoff:
            victims.append((c["id"], a.get("certificateType"), exp))

    print(f"certificates total={len(certs)} prune_candidates={len(victims)} keep_days={KEEP_DAYS}")
    for cid, ctype, exp in victims:
        d = s.delete(f"{API}/v1/certificates/{cid}", timeout=60)
        print(f"  delete {cid} {ctype} {exp} -> {d.status_code}")

    r2 = s.get(f"{API}/v1/certificates", params={"limit": 200}, timeout=60)
    print("remaining", len(r2.json().get("data", [])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
