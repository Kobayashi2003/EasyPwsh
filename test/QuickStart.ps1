$commands = @(
    "D:\Temp\frpc-win10-win11\frpc.exe -c D:\Temp\frpc-win10-win11\frpc.toml"
    "sunshine"
    "alist server"
    "rclone mount ALIST:/ K: --vfs-cache-mode full --network-mode --dir-cache-time 10s --links"
    "D:\Program\Code\Visual_Novel_Database\start-prod.ps1"
    "D:\Program\Code\SimpleFileServer\start.ps1"
)

run-cmds-in-wt @commands -NoProfile
