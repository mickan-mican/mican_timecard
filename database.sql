CREATE TABLE IF NOT EXISTS `mc_player_duty_logs` (
    `citizenid` VARCHAR(50) NOT NULL,
    `job` VARCHAR(50) NOT NULL,
    `duty_duration_seconds` INT(11) DEFAULT 0,
    -- 最終出勤時刻を保持
    `last_clock_in_time` BIGINT NULL,
    PRIMARY KEY (`citizenid`, `job`) 
);