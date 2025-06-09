# windows-ai-sandbox
Setup notes and scripts for my WSL2 Ubuntu 'sandbox'.  Work in progress.


# misc items
Modified /home/[username]/.config/systemd/user/docker.service

Ensure environment paths are wrapped in quotes:

[Service]
Environment=PATH=<span style="color:red">"</span>/usr ... <span style="color:red">"</span>