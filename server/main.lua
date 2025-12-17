local QBCore = exports['qb-core']:GetCoreObject()

-- ======================================================================================
-- # 勤務状態変数 (メモリ内: 再起動でリセットされます)
-- ======================================================================================
local DutyStatus = {} 

--- 指定されたジョブが記録対象リストに含まれているかチェックするヘルパー関数
local function IsJobTracked(jobName)
    if not jobName then return false end
    for _, job in ipairs(Config.jobs) do
        if job == jobName then return true end
    end
    return false
end

-- 🛠️ サーバー関数: タイムスタンプを日付文字列に変換
local function FormatTimestampServer(timestamp)
    if not timestamp or timestamp == 0 then return 'なし' end
    if type(timestamp) == 'number' then
        return os.date('%Y-%m-%d %H:%M:%S', timestamp)
    end
    return 'なし'
end

-- ======================================================================================
-- # 内部関数: データベース操作
-- ======================================================================================

--- SQLのlast_clock_in_timeを現在時刻に設定
local function ClockInSQL(citizenid, job_name)
    local currentTimeStr = os.time()
    MySQL.execute([[
        INSERT INTO mc_player_duty_logs (citizenid, job, duty_duration_seconds, daily_duty_seconds, last_clock_in_time)
        VALUES (?, ?, 0, 0, ?)
        ON DUPLICATE KEY UPDATE 
            last_clock_in_time = ?
    ]], {citizenid, job_name, currentTimeStr, currentTimeStr})
end

-- 🚨 履歴スライドを実行する関数 (キューがある時だけコルーチンを起動)
local function ProcessHistoryUpdate(updateQueue)
    Citizen.CreateThread(function()
        local current_time = os.time()
        for _, task in ipairs(updateQueue) do
            local data = MySQL.prepare.await([[
                SELECT last_clock_in_time, daily_duty_seconds, duty_history 
                FROM mc_player_duty_logs WHERE citizenid = ? AND job = ?
            ]], {task.citizenid, task.job})

            if data then
                local last_date = os.date("%Y-%m-%d", data.last_clock_in_time)
                local history = data.duty_history and json.decode(data.duty_history) or {}

                -- 前日分を履歴の先頭に挿入
                table.insert(history, 1, { date = last_date, seconds = data.daily_duty_seconds })
                if #history > 14 then table.remove(history) end

                -- DB更新: 当日秒数をリセットし、履歴を保存
                MySQL.update.await([[
                    UPDATE mc_player_duty_logs 
                    SET duty_history = ?, daily_duty_seconds = 0, last_clock_in_time = ?
                    WHERE citizenid = ? AND job = ?
                ]], {json.encode(history), current_time, task.citizenid, task.job})
                
                print(string.format('HISTORY SHIFT COMPLETED: %s (%s)', task.citizenid, last_date))
            end
            Citizen.Wait(100)
        end
    end)
end

-- ======================================================================================
-- # 自動化・同期スレッド (全てのロジックを集約)
-- ======================================================================================

Citizen.CreateThread(function()
    local ADD_SECONDS = Config.wait / 1000

    while true do
        Citizen.Wait(Config.wait)
        local qbPlayers = QBCore.Functions.GetQBPlayers()
        local current_time = os.time()
        local current_date = os.date("%Y-%m-%d", current_time)

        local dutyPlayersToUpdate = {} -- バッチ更新用
        local historyQueue = {}        -- 履歴スライド用

        for _, Player in pairs(qbPlayers) do
            local current_onduty = Player.PlayerData.job.onduty
            local current_job = Player.PlayerData.job.name
            local citizenid = Player.PlayerData.citizenid

            if not DutyStatus[citizenid] then
                DutyStatus[citizenid] = {is_onduty = false, job = current_job, last_tick = current_time}
            end

            local stored_onduty = DutyStatus[citizenid].is_onduty
            local stored_job = DutyStatus[citizenid].job
            local current_job_tracked = IsJobTracked(current_job)

            -- ジョブ変更/追跡外チェック
            if stored_job ~= current_job or not current_job_tracked then
                if stored_onduty then
                    DutyStatus[citizenid] = {is_onduty = false, job = current_job, last_tick = current_time}
                    goto continue_loop 
                end
                DutyStatus[citizenid].job = current_job 
                goto continue_loop
            end

            -- 勤務状態の同期と判定
            if current_onduty and not stored_onduty then
                -- 【出勤開始時の判定】
                local data = MySQL.prepare.await([[
                    SELECT last_clock_in_time FROM mc_player_duty_logs WHERE citizenid = ? AND job = ?
                ]], {citizenid, current_job})

                if data and os.date("%Y-%m-%d", data) ~= current_date then
                    table.insert(historyQueue, {citizenid = citizenid, job = current_job})
                else
                    ClockInSQL(citizenid, current_job)
                end
                DutyStatus[citizenid].is_onduty = true

            elseif not current_onduty and stored_onduty then
                -- 退勤
                DutyStatus[citizenid].is_onduty = false

            elseif current_onduty and stored_onduty then
                -- 勤務中：日付変更チェック（0時を跨いだ瞬間）
                local last_processed_date = os.date("%Y-%m-%d", DutyStatus[citizenid].last_tick)
                if last_processed_date ~= current_date then
                    table.insert(historyQueue, {citizenid = citizenid, job = stored_job})
                end

                -- バッチ更新用リスト
                table.insert(dutyPlayersToUpdate, {citizenid = citizenid, job = stored_job})
            end
            
            DutyStatus[citizenid].last_tick = current_time
            ::continue_loop::
        end

        -- 🚨 履歴スライドが必要な場合のみ起動
        if #historyQueue > 0 then
            ProcessHistoryUpdate(historyQueue)
        end

        -- 🛑 バッチ更新の実行
        if #dutyPlayersToUpdate > 0 then
            local total_cases = {}
            local daily_cases = {}
            local where_list = {}

            for _, player in ipairs(dutyPlayersToUpdate) do
                table.insert(total_cases, string.format("WHEN citizenid = '%s' AND job = '%s' THEN duty_duration_seconds + %d", player.citizenid, player.job, ADD_SECONDS))
                table.insert(daily_cases, string.format("WHEN citizenid = '%s' AND job = '%s' THEN daily_duty_seconds + %d", player.citizenid, player.job, ADD_SECONDS))
                table.insert(where_list, string.format("('%s', '%s')", player.citizenid, player.job))
            end

            local final_query = string.format([[
                UPDATE mc_player_duty_logs
                SET 
                    duty_duration_seconds = CASE %s ELSE duty_duration_seconds END,
                    daily_duty_seconds = CASE %s ELSE daily_duty_seconds END,
                    last_clock_in_time = %d
                WHERE (citizenid, job) IN (%s);
            ]], table.concat(total_cases, ' '), table.concat(daily_cases, ' '), current_time, table.concat(where_list, ', '))

            MySQL.execute(final_query, {}) 
        end

        -- クリーンアップ
        for citizenid, status in pairs(DutyStatus) do
            if QBCore.Functions.GetPlayerByCitizenId(citizenid) == nil then
                DutyStatus[citizenid].is_onduty = false
            end
        end
    end
end)


-- ======================================================================================
-- # コマンド: 勤務時間確認 (/checkduty)
-- ======================================================================================

-- ======================================================================================
-- # 1. QBCoreコマンド: 勤務時間確認 (/checkduty)
-- ======================================================================================

QBCore.Commands.Add('checkduty', '勤務時間と最終出勤日時を確認', {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end

    -- 権限チェックは不要 (全員が実行可能)

    -- クライアントへ、データをリクエストするようイベントをトリガー
    TriggerClientEvent('dutyLog:client:requestDutyData', source)
end)

-- ======================================================================================
-- # 2. サーバーイベント: 勤務時間データ取得 (Context Menu用ロジック)
-- ======================================================================================

-- このイベントは QBCore コマンドの実行後にクライアントから呼ばれます。
RegisterServerEvent('dutyLog:server:getDutyDataForMenu', function()
    local source = source
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local job_name = Player.PlayerData.job.name
    local is_boss = Player.PlayerData.job.isboss

    -- 記録対象ジョブのチェック (IsJobTracked 関数は既存のスクリプトで定義されている前提)
    if not IsJobTracked(job_name) then
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'エラー',
            description = '現在のジョブ (' .. Player.PlayerData.job.label .. ') は勤務記録の対象外です。',
            type = 'error'
        })
        return
    end

    local query_sql = ""
    local query_params = {}

    -- 一般: 自身のログのみを取得 (フィルタリング不要)
    query_sql = "SELECT citizenid, duty_duration_seconds, last_clock_in_time FROM mc_player_duty_logs WHERE citizenid = ? AND job = ?"
    query_params = {citizenid, job_name}


    -- 3. ログの実行と名前のバッチ取得 (既存のロジックを継続)
    MySQL.query(query_sql, query_params, function(result)
        if not result or #result == 0 then
            TriggerClientEvent('ox_lib:notify', source, {
                title = '情報なし',
                description = '勤務データが見つかりませんでした。',
                type = 'inform'
            })
            return
        end

        -- 一般メンバー: 日付変換のみ実行
        for i, data in ipairs(result) do
            data.last_clock_in_time = FormatTimestampServer(data.last_clock_in_time)
		end

        TriggerClientEvent('dutyLog:client:showDutyMenu', source, result, is_boss, Player.PlayerData.job.label)
    end)
end)

RegisterServerEvent('dutyLog:server:getAllDutyDataForBoss', function()
    local source = source
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end

    local job_name = Player.PlayerData.job.name
    local is_boss = Player.PlayerData.job.isboss -- 一応チェック
    
    if not is_boss then
        -- 権限がない場合は拒否
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'エラー',
            description = '全員の勤務状況を表示する権限がありません。',
            type = 'error'
        })
        return
    end

    -- 🚨 既存の dutyLog:server:getDutyDataForMenu のボス権限ロジックをそのままコピー＆ペーストします。
    -- (このブロック全体をコピーします: "if is_boss then ... else ... end" のうち、
    -- BOSSのロジックのみをコピーしてください)
    
    local target_job = job_name
    local targetCitizenIds = {}

    -- 1. 現在ジョブに就いている Citizen ID を取得 (Primary Job: job JSONから抽出)
    local primary_job_result = MySQL.query.await([[
        SELECT citizenid 
        FROM players 
        WHERE JSON_EXTRACT(job, '$.name') = ?
    ]], {target_job})
    
    for _, row in ipairs(primary_job_result) do
        table.insert(targetCitizenIds, row.citizenid)
    end
    
    -- PS-MultiJobの場合、multijobsテーブルの jobdata カラムのJSONキーを検索
    if Config.multijob == 'ps' then
        
        local secondary_job_result = MySQL.query.await([[
            SELECT citizenid 
            FROM multijobs 
            WHERE JSON_CONTAINS(JSON_KEYS(jobdata), JSON_QUOTE(?))
        ]], {target_job})
        
        local uniqueIds = {}
        for _, id in ipairs(targetCitizenIds) do uniqueIds[id] = true end
        
        for _, row in ipairs(secondary_job_result) do
            if not uniqueIds[row.citizenid] then
                table.insert(targetCitizenIds, row.citizenid)
                uniqueIds[row.citizenid] = true
            end
        end
    end

    -- 2. ログデータを現在の従業員リストでフィルタリング
    local query_sql = ""
    local query_params = {}
    
    if #targetCitizenIds > 0 then
        local placeholders = string.rep('?,', #targetCitizenIds - 1) .. '?'

        query_sql = [[
            SELECT citizenid, 
                duty_duration_seconds, 
                daily_duty_seconds, 
                duty_history, 
                last_clock_in_time
            FROM mc_player_duty_logs 
            WHERE job = ? 
            AND citizenid IN (]] .. placeholders .. [[)
        ]]
        
        query_params = {target_job}
        for _, id in ipairs(targetCitizenIds) do
            table.insert(query_params, id)
        end
    else
        query_sql = "SELECT citizenid, duty_duration_seconds, last_clock_in_time FROM mc_player_duty_logs WHERE 1=0"
        query_params = {}
    end
    
    -- 3. ログの実行と名前のバッチ取得 (既存のロジックの続き)
    MySQL.query(query_sql, query_params, function(result)
        if not result or #result == 0 then
            TriggerClientEvent('ox_lib:notify', source, {
                title = '情報なし',
                description = '勤務データが見つかりませんでした。',
                type = 'inform'
            })
            return
        end
        
        -- 4. 名前取得とデータ整形
        -- (この部分は非常に長いため、以前の修正で定義されたロジック全体をここにコピーしてください)
        
        local citizenIds = {}
        local onlinePlayers = {}
        for _, data in ipairs(result) do
            local log_citizenid = data.citizenid
            local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(log_citizenid) 

            if targetPlayer then
                local charinfo = targetPlayer.PlayerData.charinfo 
                onlinePlayers[log_citizenid] = charinfo.firstname .. ' ' .. charinfo.lastname
			else
                table.insert(citizenIds, log_citizenid)
            end
        end

        local offlineNames = {}
        if #citizenIds > 0 then
            local placeholders = string.rep('?,', #citizenIds - 1) .. '?'

            -- JSON_EXTRACTを使って charinfo から firstname と lastname を一括で取得
            local namesResult = MySQL.query.await([[
                SELECT
                    citizenid,
                    JSON_EXTRACT(charinfo, '$.firstname') AS firstname,
                    JSON_EXTRACT(charinfo, '$.lastname') AS lastname
				FROM players
                WHERE citizenid IN (]] .. placeholders .. ')'
            , citizenIds)

            for _, row in ipairs(namesResult) do
                -- 💡 引用符の削除 (以前の修正)
                local firstname = string.gsub(row.firstname or '', '"', '')
                local lastname = string.gsub(row.lastname or '', '"', '')

                offlineNames[row.citizenid] = firstname .. ' ' .. lastname
            end
        end

        -- 最終結果への結合
        for i, data in ipairs(result) do
            local log_citizenid = data.citizenid

            local playerName = onlinePlayers[log_citizenid] or
				offlineNames[log_citizenid] or
				('不明なプレイヤー (' .. log_citizenid .. ')')

            data.player_name = playerName
            data.last_clock_in_time = FormatTimestampServer(data.last_clock_in_time)

            -- DBから取得した段階ではJSON文字列なので、テーブルにデコードする
            if data.duty_history and data.duty_history ~= "" then
                data.duty_history = json.decode(data.duty_history)
            else
               data.duty_history = {} -- 履歴がない場合は空のテーブル
            end
        end

    	-- クライアントへ結果を返す (is_bossフラグはここで true で送る)
        TriggerClientEvent('dutyLog:client:showDutyMenu', source, result, is_boss, Player.PlayerData.job.label)
    end)
end)