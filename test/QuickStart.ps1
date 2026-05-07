$commands = @(
    "D:\Temp\frpc-win10-win11\frpc.exe -c D:\Temp\frpc-win10-win11\frpc.toml"
    "sunshine"
    "alist server"
    "rclone mount ALIST:/ K: --vfs-cache-mode full --network-mode"
    "postgres"
    "sleep 5; cd D:\Program\Code\Visual_Novel_Database\backend ; conda run -n flask --live-stream python run.py"
    "cd D:\Program\Code\Visual_Novel_Database\frontend ; npm start"
    "cd D:\Program\Code\SimpleFileServer\frontend ; npm start"
    "cd D:\Program\Code\SimpleFileServer\backend ; npm start"
)

run-cmds-in-wt @commands -NoProfile
