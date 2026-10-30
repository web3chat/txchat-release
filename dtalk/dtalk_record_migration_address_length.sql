/*
 数据库迁移脚本：扩展地址字段长度以支持0x格式地址
  
 问题描述：
 - Base58格式地址（1x开头）通常约34字符
 - 以太坊0x格式地址固定42字符（0x + 40个十六进制字符）
 - 原字段长度varchar(40)无法存储0x格式地址
 
 解决方案：
 - 将所有地址相关字段从varchar(40)扩展到varchar(50)
 - 确保兼容两种地址格式
 
 执行日期：2025-11-10
*/

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

USE dtalk_record;

-- 修改 dtalk_msg_content 表
ALTER TABLE `dtalk_msg_content` 
  MODIFY COLUMN `sender_id` varchar(50) NOT NULL COMMENT '发送者',
  MODIFY COLUMN `receiver_id` varchar(50) NOT NULL COMMENT '接收者';

-- 修改 dtalk_group_msg_content 表
ALTER TABLE `dtalk_group_msg_content` 
  MODIFY COLUMN `sender_id` varchar(50) NOT NULL COMMENT '发送者',
  MODIFY COLUMN `receiver_id` varchar(50) NOT NULL COMMENT '接收者';

-- 修改 dtalk_msg_relation 表
ALTER TABLE `dtalk_msg_relation` 
  MODIFY COLUMN `owner_uid` varchar(50) NOT NULL COMMENT '索引用户',
  MODIFY COLUMN `other_uid` varchar(50) NOT NULL COMMENT '另一方用户';

-- 修改 dtalk_group_msg_relation 表
ALTER TABLE `dtalk_group_msg_relation` 
  MODIFY COLUMN `owner_uid` varchar(50) NOT NULL COMMENT '索引用户',
  MODIFY COLUMN `other_uid` varchar(50) NOT NULL COMMENT '另一方用户';

-- 修改 dtalk_msg_version 表
ALTER TABLE `dtalk_msg_version` 
  MODIFY COLUMN `uid` varchar(50) NOT NULL COMMENT '用户id';

-- 修改 dtalk_signal_content 表
ALTER TABLE `dtalk_signal_content` 
  MODIFY COLUMN `uid` varchar(50) NOT NULL COMMENT '接收者';

SET FOREIGN_KEY_CHECKS = 1;

-- 验证修改
SELECT 
  TABLE_NAME,
  COLUMN_NAME,
  DATA_TYPE,
  CHARACTER_MAXIMUM_LENGTH
FROM 
  INFORMATION_SCHEMA.COLUMNS
WHERE 
  TABLE_SCHEMA = 'dtalk_record'
  AND COLUMN_NAME IN ('sender_id', 'receiver_id', 'owner_uid', 'other_uid', 'uid')
ORDER BY 
  TABLE_NAME, COLUMN_NAME;

