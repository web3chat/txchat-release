-- Per-cluster dtalk_record: federation outbox / inbox
-- Safe for re-run (CREATE IF NOT EXISTS + idempotent ALTER).
-- Prefer: make migrate-federation-mysql  (existing MySQL data volume)
SET NAMES utf8mb4;
USE dtalk_record;

CREATE TABLE IF NOT EXISTS dtalk_federation_outbox (
  id               bigint unsigned NOT NULL AUTO_INCREMENT,
  idempotency_key  varchar(128) NOT NULL COMMENT '{sourceCluster}:{mid} or {source}:mirror:{mid}',
  op_type          varchar(32)  NOT NULL DEFAULT 'deliver_private' COMMENT 'deliver_private/mirror_private/sync_state',
  dest_cluster_id  varchar(64)  NOT NULL DEFAULT '' COMMENT 'dest cluster; mirror may resolve later',
  app_id           varchar(32)  NOT NULL DEFAULT '',
  from_uid         varchar(64)  NOT NULL,
  target_uid       varchar(64)  NOT NULL,
  mid              bigint unsigned NOT NULL COMMENT 'source mid/logId',
  seq              varchar(64)  NOT NULL DEFAULT '' COMMENT 'client msgId',
  frame_type       varchar(32)  NOT NULL DEFAULT '',
  payload          mediumblob   NOT NULL COMMENT 'full RPC payload or push msg bytes',
  need_store       tinyint unsigned NOT NULL DEFAULT 1,
  status           tinyint unsigned NOT NULL DEFAULT 0 COMMENT '0pending 1sending 2done 3dead',
  retry_count      int unsigned NOT NULL DEFAULT 0,
  next_retry_at    bigint NOT NULL DEFAULT 0 COMMENT 'ms; claim when due',
  last_error       varchar(512) NOT NULL DEFAULT '',
  lease_owner      varchar(128) NOT NULL DEFAULT '',
  lease_expire_at  bigint NOT NULL DEFAULT 0 COMMENT 'ms; lease reclaim after expire',
  created_at       bigint NOT NULL,
  updated_at       bigint NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_idempotency (idempotency_key),
  KEY idx_status_retry (status, next_retry_at),
  KEY idx_mid (mid),
  KEY idx_dest (dest_cluster_id, status),
  KEY idx_lease (status, lease_expire_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='federation outbox';

CREATE TABLE IF NOT EXISTS dtalk_federation_inbox (
  idempotency_key   varchar(128) NOT NULL COMMENT '{sourceCluster}:{mid} or state key',
  source_cluster_id varchar(64)  NOT NULL,
  mid               bigint unsigned NOT NULL DEFAULT 0,
  app_id            varchar(32)  NOT NULL DEFAULT '',
  from_uid          varchar(64)  NOT NULL DEFAULT '',
  target_uid        varchar(64)  NOT NULL DEFAULT '',
  op_type           varchar(32)  NOT NULL DEFAULT 'deliver_private' COMMENT 'deliver_private/mirror_private/sync_state/deliver_group',
  content_hash      char(64)     NOT NULL DEFAULT '' COMMENT 'content fingerprint',
  -- `stored` is a MySQL 8 keyword; backticks required
  `stored`          tinyint unsigned NOT NULL DEFAULT 0 COMMENT '1 if written to msg tables',
  created_at        bigint NOT NULL,
  PRIMARY KEY (idempotency_key),
  KEY idx_mid (mid),
  KEY idx_target (target_uid, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='federation inbox idempotency';

-- Idempotent add source_cluster on dtalk_msg_content
SET @col_exists := (
  SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'dtalk_msg_content'
    AND COLUMN_NAME = 'source_cluster'
);
SET @sql := IF(@col_exists = 0,
  'ALTER TABLE dtalk_msg_content ADD COLUMN source_cluster varchar(64) NOT NULL DEFAULT '''' COMMENT ''source cluster id'' AFTER reference',
  'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
