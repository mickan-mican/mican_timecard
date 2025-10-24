Config = {}

-- 記録するJOB
Config.jobs = {
	'police',
	'ambulance'
}

-- 出勤状況のチェック頻度
Config.wait = 60 * 1000

Config.multijob = "ps" -- "" (標準) または "ps" を想定