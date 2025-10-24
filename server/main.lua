local QBCore = exports['qb-core']:GetCoreObject()

-- ======================================================================================
-- # 勤務状態変数 (メモリ内: 再起動でリセットされます)
-- citizenid -> {is_onduty = boolean, job = string}
-- ======================================================================================
local DutyStatus = {} 

--- 指定されたジョブが記録対象リストに含まれているかチェックするヘルパー関数
local function IsJobTracked(jobName)
    if not jobName then return false end
    for _, job in ipairs(Config.jobs) do
        if job == jobName then
            return true
        end
    end
    return false
end

-- 🛠️ サーバー関数: タイムスタンプを日付文字列に変換
local function FormatTimestampServer(timestamp)
    if not timestamp or timestamp == 0 then
        return 'なし'
    end

    -- データが数値（Unixタイムスタンプ）であることを前提とする
    if type(timestamp) == 'number' then
        -- サーバーで os.date を使ってフォーマット
        return os.date('%Y-%m-%d %H:%M:%S', timestamp)
    end

    -- データベースにNULLや意図しない文字列が保存されていた場合のフォールバック
    return 'なし'
end

-- ======================================================================================
-- # 内部関数: データベース操作
-- ======================================================================================

--- SQLのlast_clock_in_timeを現在時刻に設定し、レコードが存在しない場合は作成します。（出勤処理）
local function ClockInSQL(citizenid, job_name)
    -- 💡 修正: DATETIME形式の文字列を取得
    local currentTimeStr = os.time()

    -- レコードを作成またはlast_clock_in_timeを現在時刻に設定
    MySQL.execute([[
        INSERT INTO mc_player_duty_logs (citizenid, job, duty_duration_seconds, last_clock_in_time)
        VALUES (?, ?, 0, ?)
        ON DUPLICATE KEY UPDATE 
            last_clock_in_time = ?
    ]], {citizenid, job_name, currentTimeStr, currentTimeStr}) -- 💡 修正: DATETIME文字列を渡す
end

-- ======================================================================================
-- # 自動化・同期スレッド (全てのロジックを集約)
-- ======================================================================================

Citizen.CreateThread(function()
    local ADD_DURATION_SECONDS = 60 -- 加算する秒数 (60000ms/1000)

    while true do
        Citizen.Wait(Config.wait)

        local qbPlayers = QBCore.Functions.GetQBPlayers()

        -- 🚨 バッチ更新対象のプレイヤーを格納するテーブル
        local dutyPlayersToUpdate = {} 

        for _, Player in pairs(qbPlayers) do
            local current_onduty = Player.PlayerData.job.onduty
            local current_job = Player.PlayerData.job.name
            local citizenid = Player.PlayerData.citizenid

            -- 1. 勤務状態の確認と初期化
            if not DutyStatus[citizenid] then
                -- DutyStatusの初期化は常に最新のジョブ名を使用
                DutyStatus[citizenid] = {is_onduty = false, job = current_job}
            end

            local stored_onduty = DutyStatus[citizenid].is_onduty
            local stored_job = DutyStatus[citizenid].job

            -- =================================================================
            -- 🛑 2. ジョブ変更および記録対象外チェック (最優先) 🛑
            -- =================================================================

            local current_job_tracked = IsJobTracked(current_job)

            if stored_job ~= current_job or not current_job_tracked then
                -- 勤務中だった場合、強制的に退勤処理
                if stored_onduty then
                    -- DutyStatusを更新
                    DutyStatus[citizenid] = {is_onduty = false, job = current_job}
                    print(string.format('SYNC OUT (Job Change/Untracked): %s がジョブ変更または追跡対象外 (%s -> %s) のため退勤しました。', citizenid, stored_job, current_job))
                    goto continue_loop 
                end

                -- 非番だった場合、DutyStatusのjob名のみを現在のジョブに更新して同期させる
                DutyStatus[citizenid].job = current_job 
                goto continue_loop
            end

            -- =================================================================
            -- 3. 勤務状態の同期と処理 (ジョブが一致/追跡対象の場合のみ)
            -- =================================================================

            if current_onduty and not stored_onduty then
                -- 状態の不一致: 【ゲーム内: 出勤中】 & 【DutyStatus: 非番】 → 出勤処理 (クロックイン)

                ClockInSQL(citizenid, current_job)

                DutyStatus[citizenid].is_onduty = true
                print(string.format('SYNC IN: %s (%s) が出勤しました。', citizenid, current_job))

            elseif not current_onduty and stored_onduty then
                -- 状態の不一致: 【ゲーム内: 非番】 & 【DutyStatus: 出勤中】 → 退勤処理 (クロックアウト)

                -- SQLは触らず、last_clock_in_timeは保持されたまま

                DutyStatus[citizenid].is_onduty = false
                print(string.format('SYNC OUT: %s (%s) が退勤しました。', citizenid, stored_job))

            elseif current_onduty and stored_onduty then
                -- 状態の一致: 【出勤中】 → 勤務時間を加算

                -- 🚨 修正: SQLクエリの実行をスキップし、バッチ更新リストに追加
                table.insert(dutyPlayersToUpdate, {
                    citizenid = citizenid,
                    job = stored_job -- 勤務開始時のジョブ名（stored_job）を使用
                })
            end

            ::continue_loop::
        end

        -- =================================================================
        -- 🛑 4. バッチ更新の実行 (ループの外) 🛑
        -- =================================================================
        if #dutyPlayersToUpdate > 0 then
            local citizenid_cases = {}
            local citizenid_list = {}

            for _, player in ipairs(dutyPlayersToUpdate) do
                -- CASE WHEN 句用の条件文字列を構築
                table.insert(citizenid_cases, string.format("WHEN citizenid = '%s' AND job = '%s' THEN duty_duration_seconds + %d", player.citizenid, player.job, ADD_DURATION_SECONDS))

                -- WHERE IN 句用のリストを構築
                table.insert(citizenid_list, string.format("('%s', '%s')", player.citizenid, player.job))
            end

            -- バッチクエリを構築
            local query = [[
                UPDATE mc_player_duty_logs
                SET 
                    duty_duration_seconds = 
                        CASE
                            %s
                            ELSE duty_duration_seconds
                        END
                WHERE (citizenid, job) IN (%s);
            ]]

            -- SQLクエリ文字列を完成させる
            local final_query = string.format(query, table.concat(citizenid_cases, ' '), table.concat(citizenid_list, ', '))

            -- 単一のバッチクエリを実行
            MySQL.execute(final_query, {}) 
        end

        -- 接続が切れたプレイヤーのDutyStatusをクリーンアップ
        for citizenid, status in pairs(DutyStatus) do
            if QBCore.Functions.GetPlayerByCitizenId(citizenid) == nil then
                -- プレイヤーが接続リストにいない場合、メモリ上の状態をリセット
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
            SELECT citizenid, duty_duration_seconds, last_clock_in_time 
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
        end

    	-- クライアントへ結果を返す (is_bossフラグはここで true で送る)
        TriggerClientEvent('dutyLog:client:showDutyMenu', source, result, is_boss, Player.PlayerData.job.label)
    end)
end)