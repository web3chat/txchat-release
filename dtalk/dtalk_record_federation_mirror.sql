-- 方案 E：MirrorPrivate 所需 outbox/inbox 增量（可重复执行）
USE dtalk_record;

-- outbox: op_type
SET @col_exists := (
  SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'dtalk_federation_outbox'
    AND COLUMN_NAME = 'op_type'
);
SET @sql := IF(@col_exists = 0,
  'ALTER TABLE dtalk_federation_outbox ADD COLUMN op_type varchar(32) NOT NULL DEFAULT ''deliver_private'' COMMENT ''deliver_private/mirror_private/sync_state'' AFTER idempotency_key',
  'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- outbox: lease_owner
SET @col_exists := (
  SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'dtalk_federation_outbox'
    AND COLUMN_NAME = 'lease_owner'
);
SET @sql := IF(@col_exists = 0,
  'ALTER TABLE dtalk_federation_outbox ADD COLUMN lease_owner varchar(128) NOT NULL DEFAULT '''' AFTER last_error',
  'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- outbox: lease_expire_at
SET @col_exists := (
  SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'dtalk_federation_outbox'
    AND COLUMN_NAME = 'lease_expire_at'
);
SET @sql := IF(@col_exists = 0,
  'ALTER TABLE dtalk_federation_outbox ADD COLUMN lease_expire_at bigint NOT NULL DEFAULT 0 AFTER lease_owner',
  'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- inbox: content_hash
SET @col_exists := (
  SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'dtalk_federation_inbox'
    AND COLUMN_NAME = 'content_hash'
);
SET @sql := IF(@col_exists = 0,
  'ALTER TABLE dtalk_federation_inbox ADD COLUMN content_hash char(64) NOT NULL DEFAULT '''' AFTER op_type',
  'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
