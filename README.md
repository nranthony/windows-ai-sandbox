# windows-ai-sandbox
Setup notes and scripts for my WSL2 Ubuntu 'sandbox'.  Work in progress.


# misc items
Modified /home/[username]/.config/systemd/user/docker.service

Ensure environment paths are wrapped in quotes:

[Service]
Environment=PATH=<span style="color:red">"</span>/usr ... <span style="color:red">"</span>

*NOTE* - now modified in script; if issue come up, refer to uninstall lines below

### uninstall - dockerd-rootless-setuptool.sh
```bash
/usr/bin/dockerd-rootless-setuptool.sh uninstall -f ; /usr/bin/rootlesskit rm -rf /home/"$(id -un)"/.local/share/docker
/usr/bin/rootlesskit rm -rf /home/"$(id -un)"/.local/share/docker
```


