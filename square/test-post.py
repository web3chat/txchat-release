#!/usr/bin/env python3
"""模拟运营台发帖：一条不带图片，一条带刚上传的图片。

在发布目录的 square 下执行：

    python3 test-post.py
    python3 test-post.py --url http://127.0.0.1:18100
    python3 test-post.py --url http://公网地址:8888 --file ./a.png

两条都会出现在广场里，标题带当前时间。脚本用 .env 里的密钥签发运营台令牌，
先 POST /square/admin/posts/official 发纯文字，再 POST /square/admin/upload
拿到图片地址，然后把这个地址放进 mediaUrls 再发一条。
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import uuid
import urllib.error
import urllib.request
from pathlib import Path

PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)


def info(msg):
    print(msg, flush=True)


def load_env(path):
    out = {}
    if not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        out[key.strip()] = val.strip().strip('"').strip("'")
    return out


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def mint_token(secret, admin_id, username, role):
    now = int(time.time())
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(json.dumps({
        "adminId": admin_id,
        "username": username,
        "role": role,
        "iat": now,
        "exp": now + 3600,
    }, separators=(",", ":")).encode())
    sig = hmac.new(secret.encode("utf-8"), f"{header}.{payload}".encode("ascii"), hashlib.sha256).digest()
    return f"{header}.{payload}.{b64url(sig)}"


def lookup_admin(password):
    env = os.environ.copy()
    env["PGPASSWORD"] = password
    sql = "SELECT id || '|' || username || '|' || role FROM square_admin WHERE status=1 ORDER BY id LIMIT 1"
    proc = subprocess.run(
        ["docker", "exec", "-e", "PGPASSWORD", "txchat-square-pg",
         "psql", "-U", "square", "-d", "square", "-tAc", sql],
        env=env, capture_output=True, text=True, timeout=20,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(err or f"psql exit {proc.returncode}")
    line = proc.stdout.strip()
    if not line or "|" not in line:
        raise RuntimeError("square_admin 没有 status=1 的账号")
    admin_id, username, role = line.split("|", 2)
    return int(admin_id), username, role


def resolve_token(args, env):
    if args.token:
        return args.token
    secret = env.get("SQUARE_JWT_SECRET", "")
    password = env.get("SQUARE_PG_PASSWORD", "")
    if not secret or not password:
        raise RuntimeError("缺少 SQUARE_JWT_SECRET 或 SQUARE_PG_PASSWORD，也可传 --token")
    admin_id, username, role = lookup_admin(password)
    info(f"令牌: 管理员 {username} id={admin_id}")
    return mint_token(secret, admin_id, username, role)


def fetch_public(url, timeout):
    req = urllib.request.Request(url, method="GET")
    req.add_header("User-Agent", "square-post-test")
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read(1 << 20)
            return resp.status, raw, time.monotonic() - started, None
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(1 << 20), time.monotonic() - started, None
    except urllib.error.URLError as exc:
        return 0, b"", time.monotonic() - started, str(exc.reason)


def call(method, url, token, timeout, payload=None, body=None, content_type="application/json"):
    data = body
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", content_type)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("User-Agent", "square-post-test")
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read(1 << 20)
            return resp.status, raw, time.monotonic() - started, None
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(1 << 20), time.monotonic() - started, None
    except urllib.error.URLError as exc:
        return 0, b"", time.monotonic() - started, str(exc.reason)


def parse_body(status, raw, err):
    if err:
        raise RuntimeError(f"连不上: {err}")
    text = raw.decode("utf-8", "replace").strip()
    if status == 403 and not text:
        raise RuntimeError("HTTP 403 且响应为空。来源不在 SQUARE_CORS 里")
    try:
        parsed = json.loads(text or "{}")
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"HTTP {status} 不是 JSON: {text[:300]}") from exc
    return parsed


def upload_image(base, token, name, data, timeout):
    boundary = "----square" + uuid.uuid4().hex
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="kind"\r\n\r\npicture\r\n'
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode()
    body = head + data + f"\r\n--{boundary}--\r\n".encode()
    url = base.rstrip("/") + "/square/admin/upload"
    info(f"POST {url}  文件 {name} {len(data)} 字节")
    status, raw, elapsed, err = call(
        "POST", url, token, timeout, body=body,
        content_type=f"multipart/form-data; boundary={boundary}",
    )
    parsed = parse_body(status, raw, err)
    if status != 200 or parsed.get("code") != 200:
        raise RuntimeError(f"上传失败 {elapsed:.2f}s HTTP {status} code={parsed.get('code')} {parsed.get('message')} {raw[:300]!r}")
    image_url = ((parsed.get("data") or {}).get("url") or "").strip()
    if not image_url:
        raise RuntimeError(f"上传没有返回地址 {raw[:300]!r}")
    info(f"  {elapsed:.2f}s  图片地址 {image_url}")
    return image_url


def create_post(base, token, timeout, title, content, media):
    url = base.rstrip("/") + "/square/admin/posts/official"
    payload = {
        "title": title,
        "intro": "",
        "content": content,
        "mediaUrls": media,
        "commentsEnabled": True,
        "draft": False,
        "tag": "消息",
    }
    kind = "带图" if media else "纯文字"
    info(f"POST {url}  {kind}  标题 {title}")
    status, raw, elapsed, err = call("POST", url, token, timeout, payload=payload)
    parsed = parse_body(status, raw, err)
    if status != 200 or parsed.get("code") != 200:
        raise RuntimeError(f"发帖失败 {elapsed:.2f}s HTTP {status} code={parsed.get('code')} {parsed.get('message')} {raw[:300]!r}")
    data = parsed.get("data") or {}
    info(
        f"  {elapsed:.2f}s  id={data.get('id')} status={data.get('status')} "
        f"图片 {len(data.get('mediaUrls') or [])} 张"
    )
    return data


def confirm_post(base, token, timeout, post_id, expect_images):
    url = base.rstrip("/") + f"/square/admin/posts/{post_id}"
    status, raw, elapsed, err = call("GET", url, token, timeout)
    parsed = parse_body(status, raw, err)
    if status != 200 or parsed.get("code") != 200:
        raise RuntimeError(f"回读帖子失败 {elapsed:.2f}s HTTP {status} {parsed.get('message')}")
    data = parsed.get("data") or {}
    urls = data.get("mediaUrls") or []
    info(f"  回读 id={post_id} {elapsed:.2f}s 图片 {len(urls)} 张 status={data.get('status')}")
    if expect_images and not urls:
        raise RuntimeError(f"带图帖回读没有 mediaUrls: {data}")
    if not expect_images and urls:
        raise RuntimeError(f"纯文字帖回读却有图片: {urls}")
    return urls


def image_bytes(args):
    if args.file:
        path = Path(args.file)
        return path.name, path.read_bytes()
    return "probe.png", PNG_1X1


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="模拟运营台发纯文字帖和带图帖")
    parser.add_argument("--env", default=str(here / ".env"))
    parser.add_argument("--url", default="http://127.0.0.1:18100", help="广场根地址")
    parser.add_argument("--token", default="")
    parser.add_argument("--file", default="", help="带图帖使用的图片。不填则用 1x1 PNG")
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()

    env = load_env(Path(args.env))
    token = resolve_token(args, env)
    if args.token:
        info("令牌: 命令行令牌")
    stamp = time.strftime("%H:%M:%S")
    failed = False

    info("")
    info("1. 不带图片")
    try:
        text = create_post(
            args.url, token, args.timeout,
            f"纯文字测试 {stamp}",
            f"这是一条不带图片的测试帖，时间 {stamp}",
            [],
        )
        confirm_post(args.url, token, args.timeout, text.get("id"), False)
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError) as exc:
        info(f"  失败: {exc}")
        failed = True

    info("")
    info("2. 带图片")
    try:
        name, data = image_bytes(args)
        image_url = upload_image(args.url, token, name, data, args.timeout)
        imaged = create_post(
            args.url, token, args.timeout,
            f"带图测试 {stamp}",
            f"这是一条带图片的测试帖，时间 {stamp}",
            [image_url],
        )
        urls = confirm_post(args.url, token, args.timeout, imaged.get("id"), True)
        if urls and (urls[0].startswith("http://") or urls[0].startswith("https://")):
            status, raw, elapsed, err = fetch_public(urls[0], args.timeout)
            if err:
                info(f"  打开图片失败 {elapsed:.2f}s {err}")
                failed = True
            elif status != 200:
                snippet = raw[:120].decode("utf-8", "replace").replace("\n", " ")
                info(f"  打开图片 HTTP {status} {elapsed:.2f}s {snippet}")
                failed = True
            else:
                info(f"  打开图片 HTTP {status} {elapsed:.2f}s {len(raw)} 字节")
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError) as exc:
        info(f"  失败: {exc}")
        failed = True

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
