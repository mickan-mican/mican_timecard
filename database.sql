CREATE TABLE IF NOT EXISTS `mc_player_duty_logs` (
    `citizenid` VARCHAR(50) NOT NULL,
    `job` VARCHAR(50) NOT NULL,
    `duty_duration_seconds` INT(11) DEFAULT 0,
    `daily_duty_second` INT(11) DEFAULT 0,
    `last_clock_in_time` BIGINT NULL,
    `duty_history` TEXT,
    PRIMARY KEY (`citizenid`, `job`) 
);