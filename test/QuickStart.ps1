$commands = @(
    "sunshine"
    "D:\Program\Code\SimpleFileServer\start.ps1"
    "D:\Program\Code\Visual_Novel_Database\start-prod.ps1"
    "D:\Temp\frpc-win10-win11\frpc.exe -c D:\Temp\frpc-win10-win11\frpc.toml"
)

run-cmds-in-wt @commands -NoProfile
