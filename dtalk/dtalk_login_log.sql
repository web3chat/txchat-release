USE dtalk;

CREATE TABLE IF NOT EXISTS `dtalk_login_log` (
  `id`           bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT,
  `uid`          varchar(50)  NOT NULL            COMMENT '用户ID',
  `connect_id`   varchar(128) NOT NULL            COMMENT '连接ID(key)',
  `device_uuid`  varchar(64)  NOT NULL DEFAULT '' COMMENT '设备唯一标识',
  `device_type`  tinyint(4)   NOT NULL DEFAULT 0  COMMENT '设备类型(1=iOS 2=Android 3=PC 4=Web)',
  `device_name`  varchar(128) NOT NULL DEFAULT '' COMMENT '设备名称',
  `username`     varchar(128) NOT NULL DEFAULT '' COMMENT '用户名',
  `device_token` varchar(256) NOT NULL DEFAULT '' COMMENT '推送Token',
  `login_time`   bigint(20) UNSIGNED NOT NULL     COMMENT '登录时间(毫秒时间戳)',
  `created_at`   datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '记录创建时间',
  PRIMARY KEY (`id`),
  KEY `idx_uid`            (`uid`),
  KEY `idx_uid_login_time` (`uid`, `login_time`),
  KEY `idx_connect_id`     (`connect_id`),
  KEY `idx_device_uuid`    (`device_uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='客户端登录日志';
