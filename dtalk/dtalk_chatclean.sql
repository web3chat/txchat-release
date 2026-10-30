-- 聊天记录清理功能相关表
USE dtalk;

-- -----------------------------------------------------
-- 1. 自动删除配置表
--    每对私聊用户（uid_a < uid_b）保存一条配置记录。
--    option 枚举值：
--      0 = 从不自动删除（默认）
--      1 = 保留 1 天
--      2 = 保留 3 天
--      3 = 保留 7 天
--      4 = 保留 30 天
--      5 = 保留 180 天
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS dtalk_auto_delete_config (
    id         BIGINT       NOT NULL AUTO_INCREMENT COMMENT '主键',
    uid_a      VARCHAR(128) NOT NULL                COMMENT '用户 ID（字典序较小的一方）',
    uid_b      VARCHAR(128) NOT NULL                COMMENT '用户 ID（字典序较大的一方）',
    `option`   TINYINT      NOT NULL DEFAULT 0      COMMENT '自动删除选项：0=不删除,1=1天,2=3天,3=7天,4=30天,5=180天',
    updated_by VARCHAR(128) NOT NULL DEFAULT ''     COMMENT '最后修改人用户 ID',
    updated_at BIGINT       NOT NULL DEFAULT 0      COMMENT '最后修改时间（Unix ms）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_pair (uid_a, uid_b),
    KEY idx_option (`option`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='私聊自动删除配置';

-- -----------------------------------------------------
-- 2. 清理操作审计日志表
--    记录所有手动/自动删除操作，便于追溯和排查。
--    source 枚举值：
--      0 = 用户手动触发
--      1 = 调度器自动触发
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS dtalk_clean_audit (
    id          BIGINT       NOT NULL AUTO_INCREMENT COMMENT '主键',
    operator_id VARCHAR(128) NOT NULL                COMMENT '发起删除的用户 ID；调度器时填 "scheduler"',
    target_id   VARCHAR(128) NOT NULL                COMMENT '对方用户 ID',
    source      TINYINT      NOT NULL DEFAULT 0      COMMENT '来源：0=手动,1=自动调度',
    date_option TINYINT      NOT NULL DEFAULT 0      COMMENT '时间选项枚举值',
    start_time  BIGINT       NOT NULL DEFAULT 0      COMMENT '实际删除起始时间（Unix ms）',
    end_time    BIGINT       NOT NULL DEFAULT 0      COMMENT '实际删除结束时间（Unix ms）',
    deleted_cnt BIGINT       NOT NULL DEFAULT 0      COMMENT '删除消息条数',
    created_at  BIGINT       NOT NULL DEFAULT 0      COMMENT '操作时间（Unix ms）',
    PRIMARY KEY (id),
    KEY idx_operator  (operator_id),
    KEY idx_created   (created_at),
    KEY idx_source    (source)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='聊天记录清理审计日志';
