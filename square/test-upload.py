#!/usr/bin/env python3
"""测试广场运营台上传图片。

在发布目录的 square 下执行：

    python3 test-upload.py
    python3 test-upload.py --url http://127.0.0.1:18100 --url http://127.0.0.1:8888
    python3 test-upload.py --url http://公网地址:18100 --file ./a.png --bytes 800000

每个地址先发一张不带登录的小图。返回「未登录」说明接口收到了请求。
再读取旁边的 .env，用 SQUARE_JWT_SECRET 给库里的管理员签一张一小时令牌，
按页面同样的方式 POST /square/admin/upload。
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
MAX_IMAGE = 2 * 1024 * 1024


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
        return args.token, "命令行令牌"
    secret = env.get("SQUARE_JWT_SECRET", "")
    password = env.get("SQUARE_PG_PASSWORD", "")
    if not secret or not password:
        return "", "缺少 SQUARE_JWT_SECRET 或 SQUARE_PG_PASSWORD，跳过已登录上传"
    try:
        admin_id, username, role = lookup_admin(password)
    except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as exc:
        return "", f"读取管理员失败（{exc}），跳过已登录上传"
    return mint_token(secret, admin_id, username, role), f"管理员 {username} id={admin_id}"


def image_bytes(args):
    if args.file:
        data = Path(args.file).read_bytes()
        name = Path(args.file).name
    else:
        data = PNG_1X1
        name = "probe.png"
    if args.bytes and args.bytes > len(data):
        data = data + b"\x00" * (args.bytes - len(data))
    return name, data


def encode_form(name, data, kind):
    boundary = "----square" + uuid.uuid4().hex
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="kind"\r\n\r\n{kind}\r\n'
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode()
    body = head + data + f"\r\n--{boundary}--\r\n".encode()
    return boundary, body


def post_upload(base, body, boundary, token, timeout):
    url = base.rstrip("/") + "/square/admin/upload"
    origin = base.rstrip("/")
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("Origin", origin)
    req.add_header("User-Agent", "square-upload-test")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read(1 << 20)
            return resp.status, dict(resp.headers), raw, time.monotonic() - started, None
    except urllib.error.HTTPError as exc:
        raw = exc.read(1 << 20)
        return exc.code, dict(exc.headers), raw, time.monotonic() - started, None
    except urllib.error.URLError as exc:
        return 0, {}, b"", time.monotonic() - started, str(exc.reason)


def get_url(url, timeout):
    req = urllib.request.Request(url, method="GET")
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read(64)
            return resp.status, len(raw), time.monotonic() - started, None
    except urllib.error.HTTPError as exc:
        return exc.code, 0, time.monotonic() - started, None
    except urllib.error.URLError as exc:
        return 0, 0, time.monotonic() - started, str(exc.reason)


def recent_upload_logs():
    try:
        proc = subprocess.run(
            ["docker", "logs", "txchat-square", "--since", "2m"],
            capture_output=True, text=True, timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        info(f"  读广场日志失败: {exc}")
        return
    text = (proc.stdout or "") + (proc.stderr or "")
    lines = [line for line in text.splitlines() if "upload" in line.lower() or "oss " in line.lower()]
    if not lines:
        info("  近两分钟广场日志里没有 upload / oss")
        return
    info("  广场日志:")
    for line in lines[-12:]:
        info("    " + line)


def explain(status, body, err, authed):
    if err:
        return False, f"连不上: {err}"
    text = body.decode("utf-8", "replace").strip()
    if status == 403 and not text:
        return False, "HTTP 403 且响应为空。来源不在 SQUARE_CORS 里，或 Nginx 把端口从 Host 里去掉了"
    if status == 503 or status == 0:
        return False, f"HTTP {status}。广场进程没有按正常 JSON 应答"
    try:
        parsed = json.loads(text or "{}")
    except json.JSONDecodeError:
        return False, f"HTTP {status} 不是 JSON: {text[:300]}"
    code = parsed.get("code")
    message = parsed.get("message") or ""
    data = parsed.get("data") or {}
    url = data.get("url") if isinstance(data, dict) else ""
    if not authed:
        if status == 200 and code == 401:
            return True, "接口收到了图片，并返回未登录。这一步正常"
        return False, f"未登录探测异常 HTTP {status} code={code} {message} {text[:300]}"
    if status == 200 and code == 200 and url:
        return True, f"上传成功 {url}"
    return False, f"上传失败 HTTP {status} code={code} {message} {text[:300]}"


def run_one(base, name, data, token, timeout, authed):
    boundary, body = encode_form(name, data, "picture")
    label = "已登录" if authed else "未登录"
    info(f"POST {base.rstrip('/')}/square/admin/upload  {label}  文件 {name} {len(data)} 字节")
    status, _headers, raw, elapsed, err = post_upload(base, body, boundary, token if authed else "", timeout)
    ok, detail = explain(status, raw, err, authed)
    info(f"  {elapsed:.2f}s  {detail}")
    if ok and authed:
        url = ""
        try:
            url = (json.loads(raw.decode("utf-8", "replace")).get("data") or {}).get("url") or ""
        except json.JSONDecodeError:
            url = ""
        if url.startswith("http://") or url.startswith("https://"):
            code, n, cost, get_err = get_url(url, timeout)
            if get_err:
                info(f"  打开图片地址失败 {cost:.2f}s {get_err}")
            else:
                info(f"  打开图片地址 HTTP {code} {cost:.2f}s 读到 {n} 字节")
        recent_upload_logs()
    elif not ok and authed:
        recent_upload_logs()
    return ok


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="测试广场运营台图片上传")
    parser.add_argument("--env", default=str(here / ".env"), help="square/.env，用来签发登录令牌")
    parser.add_argument("--url", action="append", default=[], help="广场根地址，可重复。默认测 18100 和 8888")
    parser.add_argument("--token", default="", help="已有的运营台令牌。不填则用 .env 现签一张")
    parser.add_argument("--file", default="", help="要上传的图片。不填则用 1x1 PNG")
    parser.add_argument("--bytes", type=int, default=0, help="把图片填充到这个字节数，用来试更大的请求")
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()

    urls = args.url or ["http://127.0.0.1:18100", "http://127.0.0.1:8888"]
    env = load_env(Path(args.env))
    token, how = resolve_token(args, env)
    name, data = image_bytes(args)
    info(f"令牌: {how}")
    if len(data) > MAX_IMAGE:
        info(f"文件 {len(data)} 字节，超过广场上限 {MAX_IMAGE}，预期返回「单张图片不超过 2MB」")

    failed = False
    for base in urls:
        info("")
        if not run_one(base, name, data, token, args.timeout, False):
            failed = True
        if not token:
            info("  没有令牌，跳过已登录上传")
            failed = True
            continue
        if not run_one(base, name, data, token, args.timeout, True):
            failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
