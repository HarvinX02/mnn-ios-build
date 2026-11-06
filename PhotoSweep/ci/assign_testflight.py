#!/usr/bin/env python3
"""上传后自动把新 build 关联到 TestFlight 内部测试组。

用法（在 GitHub Actions 里）：
    python ci/assign_testflight.py --build-number 3

环境变量：
    ASC_KEY_ID      API Key ID
    ASC_ISSUER_ID   Issuer ID
    ASC_KEY_P8      私钥内容（PEM 文本）
    BUNDLE_ID       App 的 bundle id

为什么需要这个脚本：
    altool --upload-app 只是把 ipa 送到 Apple 服务器。
    新 build 默认「不属于任何测试组」，TestFlight 客户端里看不到。
    必须调用 App Store Connect API 显式关联，否则每次都要手动去网页点。
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"


def make_token():
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    # 私钥可能带转义换行，统一还原
    pem = os.environ["ASC_KEY_P8"].replace("\\n", "\n").strip()
    if not pem.endswith("\n"):
        pem += "\n"
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, pem, algorithm="ES256", headers={"kid": key_id})


class Client:
    def __init__(self):
        self.token = make_token()

    def call(self, path, method="GET", body=None, ok_codes=(200, 201, 204)):
        url = API + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=45) as r:
                raw = r.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode()[:500]
            return {"__error": e.code, "__detail": detail}


def find_app(c, bundle_id):
    r = c.call("/v1/apps?filter[bundleId]=%s&limit=1" % bundle_id)
    if r.get("__error"):
        sys.exit("查 App 失败: %s %s" % (r["__error"], r["__detail"]))
    data = r.get("data") or []
    if not data:
        sys.exit("找不到 bundleId=%s 的 App" % bundle_id)
    return data[0]["id"]


def find_internal_group(c, app_id):
    r = c.call("/v1/betaGroups?filter[app]=%s&limit=50" % app_id)
    if r.get("__error"):
        sys.exit("查测试组失败: %s %s" % (r["__error"], r["__detail"]))
    groups = r.get("data") or []
    internal = [g for g in groups if g["attributes"].get("isInternalGroup")]
    if internal:
        g = internal[0]
    elif groups:
        g = groups[0]
    else:
        sys.exit("没有找到任何 betaGroup，请先在 App Store Connect 建一个内部测试组")
    return g["id"], g["attributes"].get("name")


def wait_for_build(c, app_id, build_number, timeout_sec=1200):
    """轮询等待指定 build 出现并处理完成。"""
    deadline = time.time() + timeout_sec
    last_state = None
    while time.time() < deadline:
        r = c.call("/v1/builds?filter[app]=%s&filter[version]=%s&limit=10"
                   % (app_id, build_number))
        if r.get("__error"):
            print("  查询出错，重试: %s" % r["__error"])
            time.sleep(20)
            continue
        for b in r.get("data") or []:
            state = b["attributes"].get("processingState")
            if state != last_state:
                print("  build=%s state=%s" % (build_number, state))
                last_state = state
            if state == "VALID":
                return b["id"]
            if state == "FAILED" or state == "INVALID":
                sys.exit("build 处理失败，状态=%s" % state)
        time.sleep(20)
    sys.exit("等待 build %s 超时（%ds）" % (build_number, timeout_sec))


def ensure_whats_new(c, build_id, text):
    """写 What to Test。已存在则 PATCH，避免 409 locale 冲突。"""
    r = c.call("/v1/betaBuildLocalizations?filter[build]=%s&limit=50" % build_id)
    existing = None
    for loc in (r.get("data") or []):
        if loc["attributes"].get("locale") == "zh-Hans":
            existing = loc["id"]
            break

    if existing:
        r = c.call("/v1/betaBuildLocalizations/%s" % existing, "PATCH", {
            "data": {
                "type": "betaBuildLocalizations",
                "id": existing,
                "attributes": {"whatsNew": text},
            }
        })
        if r.get("__error"):
            print("  更新 whatsNew 失败: %s" % r["__error"])
        else:
            print("  更新 whatsNew 成功")
        return

    r = c.call("/v1/betaBuildLocalizations", "POST", {
        "data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "zh-Hans", "whatsNew": text},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
        }
    })
    if r.get("__error"):
        print("  写 whatsNew 失败: %s %s" % (r["__error"], r["__detail"]))
    else:
        print("  写 whatsNew 成功")


def assign_to_group(c, group_id, build_id):
    # 先查是否已在组内，避免重复关联报 409
    r = c.call("/v1/betaGroups/%s/builds?limit=200" % group_id)
    for b in (r.get("data") or []):
        if b["id"] == build_id:
            print("  该 build 已在组内，跳过")
            return True

    r = c.call("/v1/betaGroups/%s/relationships/builds" % group_id, "POST", {
        "data": [{"type": "builds", "id": build_id}]
    })
    if r.get("__error"):
        print("  关联失败: %s %s" % (r["__error"], r["__detail"]))
        return False
    print("  已关联到测试组")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build-number", required=True)
    ap.add_argument("--whats-new", default="")
    args = ap.parse_args()

    bundle_id = os.environ["BUNDLE_ID"]
    c = Client()

    app_id = find_app(c, bundle_id)
    print("app_id = %s" % app_id)

    group_id, group_name = find_internal_group(c, app_id)
    print("group  = %s (%s)" % (group_name, group_id))

    print("等待 build %s 处理完成…" % args.build_number)
    build_id = wait_for_build(c, app_id, args.build_number)
    print("build_id = %s" % build_id)

    text = args.whats_new or "更新版本 %s" % args.build_number
    print("写入 What to Test…")
    ensure_whats_new(c, build_id, text)

    print("关联到测试组…")
    ok = assign_to_group(c, group_id, build_id)

    # 最后核对
    print("\n=== 最终核对 ===")
    r = c.call("/v1/betaGroups/%s/builds?limit=200" % group_id)
    for b in (r.get("data") or []):
        at = b["attributes"]
        print("  build=%-4s state=%-10s expired=%s"
              % (at.get("version"), at.get("processingState"), at.get("expired")))

    if not ok:
        sys.exit(1)
    print("\n全部完成：TestFlight 客户端下拉刷新即可看到新版本")


if __name__ == "__main__":
    main()
