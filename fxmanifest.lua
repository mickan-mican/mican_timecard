fx_version 'cerulean'
game 'gta5'

author 'MICAN'
description '簡易的なタイムカードシステム'
version '1.0.1'

client_script 'client/*.lua'
server_scripts {
    'server/*.lua',
    '@oxmysql/lib/MySQL.lua'
}
shared_scripts {
    '@ox_lib/init.lua',
    'shared/*.lua',
}

dependencies {
    'ox_lib',
    'oxmysql'
}