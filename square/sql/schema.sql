-- 谈信广场 PostgreSQL schema
CREATE TABLE IF NOT EXISTS square_post (
    id               BIGSERIAL PRIMARY KEY,
    author_addr      VARCHAR(64) NOT NULL,
    author_name      VARCHAR(128) NOT NULL DEFAULT '',
    author_kind      SMALLINT NOT NULL DEFAULT 0,
    title            VARCHAR(64) NOT NULL DEFAULT '',
    intro            TEXT NOT NULL DEFAULT '',
    content          TEXT NOT NULL,
    media_json       JSONB NOT NULL DEFAULT '[]'::jsonb,
    comments_enabled SMALLINT NOT NULL DEFAULT 1,
    status           SMALLINT NOT NULL DEFAULT 5, -- 1可见 2隐藏 3已删 4AI拒绝 5待审 6草稿
    comment_count    BIGINT NOT NULL DEFAULT 0,
    like_count       BIGINT NOT NULL DEFAULT 0,
    view_count       BIGINT NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_square_post_status_created ON square_post (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_square_post_author ON square_post (author_addr, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_square_post_kind ON square_post (author_kind, status);
ALTER TABLE square_post ADD COLUMN IF NOT EXISTS title VARCHAR(64) NOT NULL DEFAULT '';
ALTER TABLE square_post ADD COLUMN IF NOT EXISTS intro TEXT NOT NULL DEFAULT '';
ALTER TABLE square_post ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_square_post_pinned ON square_post (pinned_at DESC) WHERE pinned_at IS NOT NULL;
ALTER TABLE square_post ADD COLUMN IF NOT EXISTS tag VARCHAR(32) NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS idx_square_post_tag ON square_post (tag) WHERE tag <> '';

CREATE TABLE IF NOT EXISTS square_comment (
    id          BIGSERIAL PRIMARY KEY,
    post_id     BIGINT NOT NULL REFERENCES square_post(id),
    author_addr VARCHAR(64) NOT NULL,
    author_name VARCHAR(128) NOT NULL DEFAULT '',
    content     TEXT NOT NULL,
    parent_id   BIGINT NOT NULL DEFAULT 0,
    status      SMALLINT NOT NULL DEFAULT 5,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_square_comment_post ON square_comment (post_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_square_comment_author ON square_comment (author_addr);
CREATE INDEX IF NOT EXISTS idx_square_comment_created ON square_comment (created_at);

CREATE TABLE IF NOT EXISTS square_content_moderation (
    id              BIGSERIAL PRIMARY KEY,
    target_type     VARCHAR(16) NOT NULL,
    target_id       BIGINT NOT NULL,
    verdict         VARCHAR(16) NOT NULL,
    categories      JSONB NOT NULL DEFAULT '[]'::jsonb,
    reason          TEXT NOT NULL DEFAULT '',
    model           VARCHAR(64) NOT NULL DEFAULT '',
    latency_ms      INT NOT NULL DEFAULT 0,
    overridden_by   VARCHAR(64),
    overridden_at   TIMESTAMPTZ,
    final_verdict   VARCHAR(16),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_square_moderation_target ON square_content_moderation (target_type, target_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_square_moderation_verdict ON square_content_moderation (verdict);

CREATE TABLE IF NOT EXISTS square_post_like (
    post_id    BIGINT NOT NULL REFERENCES square_post(id),
    addr       VARCHAR(64) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (post_id, addr)
);
CREATE INDEX IF NOT EXISTS idx_square_post_like_created ON square_post_like (created_at);

CREATE TABLE IF NOT EXISTS square_post_view (
    post_id    BIGINT NOT NULL REFERENCES square_post(id),
    addr       VARCHAR(64) NOT NULL,
    viewed_on  DATE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (post_id, addr, viewed_on)
);
CREATE INDEX IF NOT EXISTS idx_square_post_view_day ON square_post_view (viewed_on);

CREATE TABLE IF NOT EXISTS square_official_apply (
    id            BIGSERIAL PRIMARY KEY,
    address       VARCHAR(64) NOT NULL,
    name          VARCHAR(64) NOT NULL,
    avatar        TEXT NOT NULL DEFAULT '',
    intro         TEXT NOT NULL DEFAULT '',
    status        VARCHAR(16) NOT NULL DEFAULT 'pending',
    reviewer      VARCHAR(64),
    review_remark TEXT NOT NULL DEFAULT '',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reviewed_at   TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uniq_square_official_apply_pending
    ON square_official_apply (address) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_square_official_apply_status ON square_official_apply (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_square_official_apply_name
    ON square_official_apply (name) WHERE status IN ('pending', 'approved');

CREATE TABLE IF NOT EXISTS square_official_account (
    address    VARCHAR(64) PRIMARY KEY,
    name       VARCHAR(64) NOT NULL,
    avatar     TEXT NOT NULL DEFAULT '',
    intro      TEXT NOT NULL DEFAULT '',
    status     SMALLINT NOT NULL DEFAULT 1,
    apply_id   BIGINT,
    banned_at  TIMESTAMPTZ,
    ban_reason TEXT NOT NULL DEFAULT '',
    gold       BOOLEAN NOT NULL DEFAULT FALSE,
    gold_at    TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE square_official_account ADD COLUMN IF NOT EXISTS gold BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE square_official_account ADD COLUMN IF NOT EXISTS gold_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_square_official_gold ON square_official_account (gold) WHERE gold;
CREATE INDEX IF NOT EXISTS idx_square_official_account_name ON square_official_account (name);

CREATE TABLE IF NOT EXISTS square_admin (
    id            BIGSERIAL PRIMARY KEY,
    username      VARCHAR(64) NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role          VARCHAR(16) NOT NULL DEFAULT 'reviewer',
    status        SMALLINT NOT NULL DEFAULT 1,
    permissions   TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE square_admin ADD COLUMN IF NOT EXISTS permissions TEXT;

CREATE TABLE IF NOT EXISTS square_admin_audit (
    id          BIGSERIAL PRIMARY KEY,
    admin_id    BIGINT NOT NULL DEFAULT 0,
    username    VARCHAR(64) NOT NULL DEFAULT '',
    action      VARCHAR(64) NOT NULL,
    target_type VARCHAR(32) NOT NULL DEFAULT '',
    target_id   VARCHAR(64) NOT NULL DEFAULT '',
    extra       TEXT NOT NULL DEFAULT '',
    client_ip   VARCHAR(64) NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_square_admin_audit_created ON square_admin_audit (created_at DESC);

CREATE TABLE IF NOT EXISTS square_admin_captcha (
    id         VARCHAR(64) PRIMARY KEY,
    code_hash  TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS square_admin_login_guard (
    guard_key    VARCHAR(128) PRIMARY KEY,
    fail_count   INT NOT NULL DEFAULT 0,
    locked_until TIMESTAMPTZ,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS square_rate_hit (
    id         BIGSERIAL PRIMARY KEY,
    addr       VARCHAR(64) NOT NULL,
    action     VARCHAR(32) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_square_rate_hit ON square_rate_hit (addr, action, created_at DESC);

CREATE TABLE IF NOT EXISTS square_user_ban (
    address    VARCHAR(64) PRIMARY KEY,
    reason     TEXT NOT NULL DEFAULT '',
    operator   VARCHAR(64) NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_square_user_ban_created ON square_user_ban (created_at DESC);

CREATE TABLE IF NOT EXISTS square_follow (
    follower_addr VARCHAR(64) NOT NULL,
    target_addr   VARCHAR(64) NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (follower_addr, target_addr),
    CHECK (follower_addr <> target_addr)
);
CREATE INDEX IF NOT EXISTS idx_square_follow_target ON square_follow (target_addr, created_at DESC);

CREATE TABLE IF NOT EXISTS square_report (
    id            BIGSERIAL PRIMARY KEY,
    reporter_addr VARCHAR(64) NOT NULL,
    target_type   VARCHAR(16) NOT NULL,
    target_id     BIGINT NOT NULL,
    reason        VARCHAR(32) NOT NULL,
    detail        TEXT NOT NULL DEFAULT '',
    status        SMALLINT NOT NULL DEFAULT 0,
    handled_by    VARCHAR(64) NOT NULL DEFAULT '',
    handled_at    TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (reporter_addr, target_type, target_id)
);
CREATE INDEX IF NOT EXISTS idx_square_report_status ON square_report (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_square_report_target ON square_report (target_type, target_id);

CREATE TABLE IF NOT EXISTS square_setting (
    key        VARCHAR(64) PRIMARY KEY,
    value      TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO square_setting (key, value) VALUES
    ('gate_mode', 'open'),
    ('gate_message', '广场功能已经关闭'),
    ('allow_officials', '1'),
    ('moderation_level', 'default')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS square_poster_allow (
    address    VARCHAR(64) PRIMARY KEY,
    remark     TEXT NOT NULL DEFAULT '',
    operator   VARCHAR(64) NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
