-- client.lua (最終修正版)

local QBCore = exports['qb-core']:GetCoreObject()

-- ======================================================================================
-- # 内部関数: 時間をフォーマットするヘルパー関数 (変更なし)
-- ======================================================================================

local function FormatDuration(total_seconds)
    if not total_seconds or total_seconds == 0 then
        return '0分'
    end
    
    local hours = math.floor(total_seconds / 3600)
    local minutes = math.floor((total_seconds % 3600) / 60)
    -- 🚨 秒数 (seconds) の計算と表示を削除
    
    if hours > 0 then
        return string.format('%d時間%d分', hours, minutes)
    elseif minutes > 0 then
        return string.format('%d分', minutes)
    else
        return '0分'
    end
end

-- ======================================================================================
-- # サーバーからのデータ受信とメニュー再登録/表示 (修正済み)
-- ======================================================================================

RegisterNetEvent('dutyLog:client:requestDutyData', function()
    -- サーバーへデータを要求
    TriggerServerEvent('dutyLog:server:getDutyDataForMenu')

    lib.notify({
        title = '勤務ログ',
        description = '勤務データをサーバーから取得中です...',
        type = 'info',
        duration = 3000
    })
end)

RegisterNetEvent('dutyLog:client:showDutyMenu', function(logData, isBoss, jobLabel)
    local options = {} 
    local myCitizenId = QBCore.PlayerData.citizenid
    
    -- 🚨 判定ロジック:
    -- 1. isBoss である
    -- 2. ログの件数が1件ではない (全員分である可能性が高い)
    -- 3. または、ログの最初のCitizen IDが自分自身ではない (全員分である可能性が高い)
    local isShowingAllLogs = isBoss and #logData > 1

    local is_single_log = #logData == 1 and logData[1].citizenid == myCitizenId

    if isBoss then
        if isShowingAllLogs then
            -- 🚨 修正: 全員ログ表示中に「戻る」ボタンを追加
            table.insert(options, {
                title = '🔙 自分の勤務状況に戻る',
                description = '最初のメニューに戻り、自分自身の累計勤務時間を確認します。',
                icon = 'arrow-left',
                arrow = true,
                -- 最初のメニューを開くサーバーイベントをトリガー
                serverEvent = 'dutyLog:server:getDutyDataForMenu' 
            })
        elseif is_single_log then
            -- 以前の修正: 自分自身のログ表示中に「全員表示」ボタンを追加
            table.insert(options, {
                title = '💼 全従業員の勤務状況を表示',
                description = '全ての従業員の累計勤務時間と最終出勤日時を確認します。',
                icon = 'users',
                arrow = true,
                serverEvent = 'dutyLog:server:getAllDutyDataForBoss' 
            })
        end
    end

    -- 1. ヘッダーエレメントの構築
    local menuTitle = isShowingAllLogs and '全従業員 勤務ログ' or (jobLabel .. ' 勤務ログ')
    
    table.insert(options, {
        title = menuTitle,
        header = true
    })

    -- 2. ログエレメントの構築
    for _, data in ipairs(logData) do
        -- ... (既存の FormatDuration, last_in_str のロジックは変更なし) ...
        local duration_str = FormatDuration(data.duty_duration_seconds)
        local last_in_str = data.last_clock_in_time or 'なし'
        
        local item_title
        local item_description

        -- ログに player_name があれば (全員分の場合)、その名前を使用
        if data.player_name then
            local playerName = data.player_name or ('CitizenID: ' .. data.citizenid) 
            item_title = playerName .. ' | 勤務時間: ' .. duration_str
            item_description = '最終出勤: ' .. last_in_str .. ' (Citizen ID: ' .. data.citizenid .. ')'
        else
            -- 自分自身の場合
            item_title = '累計勤務時間: ' .. duration_str
            item_description = '最終出勤日時: ' .. last_in_str
        end

        table.insert(options, {
            title = item_title,             
            description = item_description, 
            icon = 'clock',
            readonly = true 
        })
    end

    -- 3. メニューを上書き登録
    lib.registerContext({
        id = 'duty_log_menu',
        title = '出退勤記録システム',
        options = options
    })

    -- 4. IDのみを渡してメニューを表示
    lib.showContext('duty_log_menu')
end)